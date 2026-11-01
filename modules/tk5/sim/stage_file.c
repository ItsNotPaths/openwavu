// A stage from its collision glb and .surfaces JSON. The glb: mesh "floors" (one triangle fan per polygon; _POLYGON
// numbers the polygons, _NORMAL is the stored plane normal), mesh "walls" (4 vertices a quad), _SURFACE on each
// vertex, and nodes "start.<list>.<index>" (translation, extras.turn). Mesh data is in file units; a scale on the root
// node maps them to metres.
#include <stdlib.h>
#include <string.h>

#include "sim/stage.h"

// --- JSON, read in place

typedef struct { const char *at, *end; } Json;  // at: the first character of a value, NULL when missing

static bool is_space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
static const char *skip_space(const char *at, const char *end) {
    while (at < end && is_space(*at)) at++;
    return at;
}

static const char *past_value(const char *at, const char *end) {
    if (at >= end) return end;
    if (*at == '"') {
        for (at++; at < end && *at != '"'; at++)
            if (*at == '\\') at++;
        return at + 1;
    }
    if (*at == '{' || *at == '[') {
        int depth = 0;
        for (; at < end; at++) {
            if (*at == '"') at = past_value(at, end) - 1;
            else if (*at == '{' || *at == '[') depth++;
            else if ((*at == '}' || *at == ']') && --depth == 0) return at + 1;
        }
        return end;
    }
    while (at < end && *at != ',' && *at != '}' && *at != ']' && !is_space(*at)) at++;
    return at;
}

// The members of an object or the items of an array, one per call.
typedef struct { const char *at, *end; bool object; } JsonWalk;
static JsonWalk json_walk(Json container) {
    bool open = container.at && (*container.at == '{' || *container.at == '[');
    return (JsonWalk){open ? container.at + 1 : NULL, container.end, open && *container.at == '{'};
}

static bool json_next(JsonWalk *walk, Json *key, Json *value) {
    if (!walk->at) return false;
    const char *at = skip_space(walk->at, walk->end);
    if (at >= walk->end || *at == '}' || *at == ']') return false;
    if (walk->object) {
        *key = (Json){at, walk->end};
        at = skip_space(past_value(at, walk->end), walk->end) + 1;  // past ':'
        at = skip_space(at, walk->end);
    }
    *value = (Json){at, walk->end};
    at = skip_space(past_value(at, walk->end), walk->end);
    walk->at = at < walk->end && *at == ',' ? at + 1 : at;
    return true;
}

static bool json_is(Json string, const char *text) {
    size_t length = strlen(text);
    return string.at && *string.at == '"' && string.end - string.at > (ptrdiff_t)length + 1 &&
           !memcmp(string.at + 1, text, length) && string.at[length + 1] == '"';
}

static Json json_get(Json object, const char *name) {
    JsonWalk walk = json_walk(object);
    Json key, value;
    while (json_next(&walk, &key, &value))
        if (json_is(key, name)) return value;
    return (Json){};
}

static Json json_item(Json array, int32_t index) {
    JsonWalk walk = json_walk(array);
    Json value;
    for (int32_t at = 0; json_next(&walk, NULL, &value); at++)
        if (at == index) return value;
    return (Json){};
}

static int32_t json_count(Json array) {
    JsonWalk walk = json_walk(array);
    Json value;
    int32_t count = 0;
    while (json_next(&walk, NULL, &value)) count++;
    return count;
}

static bool json_number(Json value) { return value.at && (*value.at == '-' || (*value.at >= '0' && *value.at <= '9')); }
static int32_t json_int(Json value, int32_t missing) { return json_number(value) ? (int32_t)strtol(value.at, NULL, 10) : missing; }
static float json_float(Json value) { return json_number(value) ? strtof(value.at, NULL) : 0.0f; }  // strtof: exact for f32 text

// --- glb

enum { GLB_HEADER = 12, CHUNK_HEADER = 8, COMPONENT_FLOAT = 5126, COMPONENT_SHORT = 5123 };

typedef struct { Json json; const uint8_t *bin; size_t bin_size; } Glb;

static uint32_t word_at(const uint8_t *at) {
    uint32_t word;
    memcpy(&word, at, sizeof word);
    return word;
}

static bool glb_open(Glb *glb, T5Bytes file) {
    if (file.size < GLB_HEADER + CHUNK_HEADER || memcmp(file.data, "glTF", 4) || word_at(file.data + 4) != 2) return false;
    size_t json_size = word_at(file.data + GLB_HEADER);
    const uint8_t *json = file.data + GLB_HEADER + CHUNK_HEADER;
    if (memcmp(file.data + GLB_HEADER + 4, "JSON", 4) || json_size > file.size - GLB_HEADER - CHUNK_HEADER) return false;
    glb->json = (Json){(const char *)json, (const char *)json + json_size};
    glb->json.at = skip_space(glb->json.at, glb->json.end);
    size_t bin_at = GLB_HEADER + CHUNK_HEADER + json_size;
    if (bin_at + CHUNK_HEADER <= file.size) {
        glb->bin = file.data + bin_at + CHUNK_HEADER;
        glb->bin_size = word_at(file.data + bin_at);
        if (glb->bin_size > file.size - bin_at - CHUNK_HEADER) return false;
    }
    return true;
}

typedef struct { const uint8_t *data; int32_t count, stride; } Accessor;  // count 0: none

static Json mesh_attributes(const Glb *glb, const char *name) {
    JsonWalk walk = json_walk(json_get(glb->json, "meshes"));
    Json mesh;
    while (json_next(&walk, NULL, &mesh))
        if (json_is(json_get(mesh, "name"), name)) return json_get(json_item(json_get(mesh, "primitives"), 0), "attributes");
    return (Json){};
}

static bool accessor(const Glb *glb, Json attributes, const char *name, int32_t component, int32_t width, Accessor *out) {
    *out = (Accessor){};
    int32_t index = json_int(json_get(attributes, name), -1);
    if (index < 0) return false;
    Json found = json_item(json_get(glb->json, "accessors"), index);
    Json view = json_item(json_get(glb->json, "bufferViews"), json_int(json_get(found, "bufferView"), -1));
    int32_t element = width * (component == COMPONENT_FLOAT ? 4 : 2);
    int32_t count = json_int(json_get(found, "count"), -1), stride = json_int(json_get(view, "byteStride"), 0);
    if (stride == 0) stride = element;  // tightly packed
    int32_t offset = json_int(json_get(view, "byteOffset"), 0) + json_int(json_get(found, "byteOffset"), 0);
    if (json_int(json_get(found, "componentType"), 0) != component || count < 0 || stride < element || offset < 0) return false;
    if (count && (size_t)offset + (size_t)(count - 1) * (size_t)stride + (size_t)element > glb->bin_size) return false;
    *out = (Accessor){glb->bin + offset, count, stride};
    return true;
}

static float float_at(const Accessor *a, int32_t index, int32_t component) {
    float value;
    memcpy(&value, a->data + (size_t)index * (size_t)a->stride + 4 * (size_t)component, sizeof value);
    return value;
}

static uint16_t short_at(const Accessor *a, int32_t index) {
    uint16_t value;
    memcpy(&value, a->data + (size_t)index * (size_t)a->stride, sizeof value);
    return value;
}

static T5Vec4 point_at(const Accessor *a, int32_t index, float w) {
    return (T5Vec4){{float_at(a, index, 0), float_at(a, index, 1), float_at(a, index, 2), w}};
}

// --- the stage

typedef struct { Accessor position, normal, surface, polygon; } Mesh;

static bool read_mesh(const Glb *glb, const char *name, bool polygons, Mesh *mesh) {
    Json attributes = mesh_attributes(glb, name);
    *mesh = (Mesh){};
    if (!attributes.at) return true;  // no mesh: none of these
    return accessor(glb, attributes, "POSITION", COMPONENT_FLOAT, 3, &mesh->position) &&
           accessor(glb, attributes, "_NORMAL", COMPONENT_FLOAT, 3, &mesh->normal) &&
           accessor(glb, attributes, "_SURFACE", COMPONENT_SHORT, 1, &mesh->surface) &&
           (!polygons || accessor(glb, attributes, "_POLYGON", COMPONENT_SHORT, 1, &mesh->polygon)) &&
           mesh->normal.count == mesh->position.count && mesh->surface.count == mesh->position.count &&
           (!polygons || mesh->polygon.count == mesh->position.count);
}

static int32_t polygon_count(const Mesh *floors) {
    int32_t count = 0;
    for (int32_t vertex = 0; vertex < floors->position.count; vertex++)
        count += vertex == 0 || short_at(&floors->polygon, vertex) != short_at(&floors->polygon, vertex - 1);
    return count;
}

static const char *const START_LISTS[T5_START_LISTS] = {"side_1", "side_2", "entrance"};

// A start node: its list and index, from "start.<list>.<index>". False for any other node.
static bool start_node(Json node, int32_t *list, int32_t *index) {
    Json name = json_get(node, "name");
    if (!name.at || strncmp(name.at, "\"start.", 7)) return false;
    for (*list = 0; *list < T5_START_LISTS; (*list)++) {
        size_t length = strlen(START_LISTS[*list]);
        if (!strncmp(name.at + 7, START_LISTS[*list], length) && name.at[7 + length] == '.') {
            *index = (int32_t)strtol(name.at + 8 + length, NULL, 10);
            return true;
        }
    }
    return false;
}

static uint32_t layer_bits(Json layers) {
    JsonWalk walk = json_walk(layers);
    Json layer;
    uint32_t bits = 0;
    while (json_next(&walk, NULL, &layer)) {
        if (json_is(layer, "floor")) bits |= T5_LAYER_FLOOR;
        for (int32_t list = 1; list <= T5_LAYER_LISTS; list++) {
            char name[8] = "list_0";
            name[5] = (char)('0' + list);
            if (json_is(layer, name)) bits |= 1u << list;
        }
    }
    return bits;
}

typedef struct {
    Glb glb;
    Json surfaces;
    Mesh floors, walls;
    int32_t surface_count, polygon_count, wall_count, start_count[T5_START_LISTS];
} Source;

static const char *open_source(Source *source, T5Bytes collision, T5Bytes surfaces) {
    *source = (Source){};
    if (!glb_open(&source->glb, collision)) return "collision: not a glb";
    if (!read_mesh(&source->glb, "floors", true, &source->floors) || !read_mesh(&source->glb, "walls", false, &source->walls))
        return "collision: bad floors or walls mesh";
    if (source->walls.position.count % 4) return "collision: walls are not quads";
    source->surfaces = (Json){skip_space((const char *)surfaces.data, (const char *)surfaces.data + surfaces.size),
                              (const char *)surfaces.data + surfaces.size};
    if (!surfaces.size || *source->surfaces.at != '[') return "surfaces: not a list";
    source->surface_count = json_count(source->surfaces);
    source->polygon_count = polygon_count(&source->floors);
    source->wall_count = source->walls.position.count / 4;
    JsonWalk walk = json_walk(json_get(source->glb.json, "nodes"));
    Json node;
    int32_t list, index, nodes[T5_START_LISTS] = {};
    while (json_next(&walk, NULL, &node)) {
        if (!start_node(node, &list, &index)) continue;
        nodes[list]++;
        if (index >= source->start_count[list]) source->start_count[list] = index + 1;
    }
    for (list = 0; list < T5_START_LISTS; list++)
        if (nodes[list] != source->start_count[list]) return "collision: start indexes have gaps";
    if (source->start_count[T5_START_SIDE_1] != source->start_count[T5_START_SIDE_2]) return "collision: side 1 and 2 differ";
    return NULL;
}

typedef struct {
    size_t surfaces, floors, vertices, walls, start[T5_START_LISTS];
} Sizes;

static Sizes sizes_of(const Source *source) {
    Sizes sizes = {
        .surfaces = t5_arena_round((size_t)source->surface_count * sizeof(T5Surface)),
        .floors = t5_arena_round((size_t)source->polygon_count * sizeof(T5FloorPolygon)),
        .vertices = t5_arena_round((size_t)source->floors.position.count * sizeof(T5Vec4)),
        .walls = t5_arena_round((size_t)source->wall_count * sizeof(T5WallQuad)),
    };
    for (int32_t list = 0; list < T5_START_LISTS; list++)
        sizes.start[list] = t5_arena_round((size_t)source->start_count[list] * sizeof(T5StartPoint));
    return sizes;
}

static size_t total_of(Sizes sizes) {
    size_t total = sizes.surfaces + sizes.floors + sizes.vertices + sizes.walls;
    for (int32_t list = 0; list < T5_START_LISTS; list++) total += sizes.start[list];
    return total;
}

static const char *fill_surfaces(const Source *source, T5Surface *surfaces) {
    JsonWalk walk = json_walk(source->surfaces);
    Json surface;
    for (int32_t index = 0; json_next(&walk, NULL, &surface); index++) {
        if (*surface.at != '{') return "surfaces: an entry is not an object";
        surfaces[index] = (T5Surface){layer_bits(json_get(surface, "layers")), json_int(json_get(surface, "material"), 0),
                                      json_int(json_get(surface, "hit_event"), 0), json_int(json_get(surface, "break_power"), 0)};
    }
    return NULL;
}

static const char *fill_floors(const Source *source, T5FloorPolygon *floors, T5Vec4 *vertices) {
    const Mesh *mesh = &source->floors;
    int32_t polygon = -1;
    for (int32_t vertex = 0; vertex < mesh->position.count; vertex++) {
        vertices[vertex] = point_at(&mesh->position, vertex, 1.0f);
        if (vertex == 0 || short_at(&mesh->polygon, vertex) != short_at(&mesh->polygon, vertex - 1)) {
            T5Vec4 normal = point_at(&mesh->normal, vertex, 0.0f);
            floors[++polygon] = (T5FloorPolygon){{normal.x, normal.y, normal.z}, short_at(&mesh->surface, vertex), 0, &vertices[vertex]};
        }
        floors[polygon].count++;
        if (floors[polygon].surface >= source->surface_count) return "collision: a floor names a missing surface";
    }
    for (polygon = 0; polygon < source->polygon_count; polygon++)
        if (floors[polygon].count < 3) return "collision: a floor polygon has under 3 corners";
    return NULL;
}

static const char *fill_walls(const Source *source, T5WallQuad *walls) {
    const Mesh *mesh = &source->walls;
    for (int32_t wall = 0; wall < source->wall_count; wall++) {
        T5WallQuad *quad = &walls[wall];
        for (int32_t corner = 0; corner < 4; corner++) {
            T5Vec4 point = point_at(&mesh->position, 4 * wall + corner, 1.0f);
            memcpy(quad->corners.m[corner], point.v, sizeof point.v);
        }
        quad->normal = point_at(&mesh->normal, 4 * wall, 0.0f);
        quad->surface = short_at(&mesh->surface, 4 * wall);
        if (quad->surface >= source->surface_count) return "collision: a wall names a missing surface";
    }
    return NULL;
}

static void fill_start(const Source *source, T5StartPoint *points[T5_START_LISTS]) {
    JsonWalk walk = json_walk(json_get(source->glb.json, "nodes"));
    Json node;
    int32_t list, index;
    while (json_next(&walk, NULL, &node)) {
        if (!start_node(node, &list, &index)) continue;
        Json translation = json_get(node, "translation"), extras = json_get(node, "extras");
        points[list][index] = (T5StartPoint){{json_float(json_item(translation, 0)), json_float(json_item(translation, 1)),
                                              json_float(json_item(translation, 2))}, json_float(json_get(extras, "turn"))};
    }
}

const char *t5_stage_parse(T5Stage *stage, T5Bytes collision, T5Bytes surfaces, T5Arena *arena, size_t *bytes) {
    Source source;
    const char *failed = open_source(&source, collision, surfaces);
    if (failed) return failed;
    Sizes sizes = sizes_of(&source);
    *bytes = total_of(sizes);
    if (!arena) return NULL;
    T5Surface *surface_list = t5_arena_take(arena, sizes.surfaces);
    T5FloorPolygon *floors = t5_arena_take(arena, sizes.floors);
    T5Vec4 *vertices = t5_arena_take(arena, sizes.vertices);
    T5WallQuad *walls = t5_arena_take(arena, sizes.walls);
    T5StartPoint *points[T5_START_LISTS];
    bool full = !surface_list || !floors || !vertices || !walls;
    for (int32_t list = 0; list < T5_START_LISTS; list++) full |= !(points[list] = t5_arena_take(arena, sizes.start[list]));
    if (full) return "stage: arena full";
    *stage = (T5Stage){.surfaces = surface_list, .surface_count = source.surface_count, .floors = floors,
                       .floor_count = source.polygon_count, .walls = walls, .wall_count = source.wall_count};
    for (int32_t list = 0; list < T5_START_LISTS; list++) stage->start[list] = (T5StartList){source.start_count[list], points[list]};
    fill_start(&source, points);
    if ((failed = fill_surfaces(&source, surface_list))) return failed;
    if ((failed = fill_floors(&source, floors, vertices))) return failed;
    return fill_walls(&source, walls);
}
