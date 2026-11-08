// Stage glb reading: the JSON with jsmn, positions and indices from the BIN chunk, every mesh node's triangles placed
// in world space.
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "model.h"
#include "openwavu.h"

#define JSMN_STATIC
#define JSMN_STRICT
#define JSMN_PARENT_LINKS
#include "jsmn.h"

enum { GLB_HEADER = 12, CHUNK_HEADER = 8, COMPONENT_SHORT = 5123, COMPONENT_INT = 5125, COMPONENT_FLOAT = 5126 };
enum { MODE_TRIANGLES = 4 };

typedef struct { const char *text; jsmntok_t *tokens; int32_t count; } Json;

// The token after this one and everything inside it.
static int32_t after(const Json *json, int32_t token) {
    int32_t next = token + 1;
    while (next < json->count && json->tokens[next].start < json->tokens[token].end) next++;
    return next;
}

static bool is_text(const Json *json, int32_t token, const char *text) {
    const jsmntok_t *found = &json->tokens[token];
    size_t length = strlen(text);
    return found->type == JSMN_STRING && (size_t)(found->end - found->start) == length && !memcmp(json->text + found->start, text, length);
}

// An object's member, -1 when missing.
static int32_t member(const Json *json, int32_t object, const char *name) {
    if (object < 0 || json->tokens[object].type != JSMN_OBJECT) return -1;
    int32_t key = object + 1;
    for (int32_t at = 0; at < json->tokens[object].size; at++) {
        if (is_text(json, key, name)) return key + 1;
        key = after(json, key + 1);
    }
    return -1;
}

static int32_t item_count(const Json *json, int32_t array) {
    return array >= 0 && json->tokens[array].type == JSMN_ARRAY ? json->tokens[array].size : 0;
}

// An array's items as tokens, malloc'd; count gets how many.
static int32_t *items(const Json *json, int32_t array, int32_t *count_out) {
    int32_t count = *count_out = item_count(json, array);
    int32_t *found = malloc((size_t)(count + 1) * sizeof *found);
    for (int32_t at = 0, token = array + 1; at < count; at++, token = after(json, token)) found[at] = token;
    return found;
}

static double number(const Json *json, int32_t token, double missing) {
    if (token < 0 || json->tokens[token].type != JSMN_PRIMITIVE) return missing;
    const char *at = json->text + json->tokens[token].start;
    return *at == '-' || (*at >= '0' && *at <= '9') ? strtod(at, NULL) : missing;
}

static void copy_text(const Json *json, int32_t token, char *out, size_t size) {
    out[0] = 0;
    if (token < 0 || json->tokens[token].type != JSMN_STRING) return;
    snprintf(out, size, "%.*s", json->tokens[token].end - json->tokens[token].start, json->text + json->tokens[token].start);
}

static uint32_t word_at(const uint8_t *at) {
    uint32_t word;
    memcpy(&word, at, sizeof word);
    return word;
}

// --- matrices: column major, as glTF

typedef struct { float m[16]; } Matrix;

static const Matrix IDENTITY = {{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}};

static Matrix multiplied(Matrix left, Matrix right) {
    Matrix out;
    for (int column = 0; column < 4; column++)
        for (int row = 0; row < 4; row++) {
            float sum = 0;
            for (int at = 0; at < 4; at++) sum += left.m[at * 4 + row] * right.m[column * 4 + at];
            out.m[column * 4 + row] = sum;
        }
    return out;
}

static Point placed(Matrix matrix, Point point) {
    const float *m = matrix.m;
    return (Point){
        m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
        m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
        m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14],
    };
}

static void read_floats(const Json *json, int32_t array, float *out, int32_t count) {
    for (int32_t at = 0, token = array + 1; at < count && at < item_count(json, array); at++, token = after(json, token))
        out[at] = (float)number(json, token, out[at]);
}

static Matrix local_matrix(const Json *json, int32_t node) {
    Matrix matrix = IDENTITY;
    if (member(json, node, "matrix") >= 0) {
        read_floats(json, member(json, node, "matrix"), matrix.m, 16);
        return matrix;
    }
    float position[3] = {0, 0, 0}, turn[4] = {0, 0, 0, 1}, scale[3] = {1, 1, 1};
    read_floats(json, member(json, node, "translation"), position, 3);
    read_floats(json, member(json, node, "rotation"), turn, 4);
    read_floats(json, member(json, node, "scale"), scale, 3);
    float x = turn[0], y = turn[1], z = turn[2], w = turn[3];
    float columns[3][3] = {
        {1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w)},
        {2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w)},
        {2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)},
    };
    for (int column = 0; column < 3; column++)
        for (int row = 0; row < 3; row++) matrix.m[column * 4 + row] = columns[column][row] * scale[column];
    for (int row = 0; row < 3; row++) matrix.m[12 + row] = position[row];
    return matrix;
}

// --- loading

typedef struct {
    Json json;
    const uint8_t *bin;
    size_t bin_size;
    int32_t *nodes, *meshes, *accessors, *views, *materials, *textures, *images;
    int32_t node_count, mesh_count, accessor_count, view_count, material_count, texture_count, image_count;
} Glb;

typedef struct { const uint8_t *data; int32_t count, stride, component; } Accessor;  // count 0: none

static Accessor accessor(const Glb *glb, int32_t index) {
    const Json *json = &glb->json;
    if (index < 0 || index >= glb->accessor_count) return (Accessor){0};
    int32_t found = glb->accessors[index];
    int32_t view_index = (int32_t)number(json, member(json, found, "bufferView"), -1);
    if (view_index < 0 || view_index >= glb->view_count) return (Accessor){0};
    int32_t view = glb->views[view_index];
    int32_t component = (int32_t)number(json, member(json, found, "componentType"), 0);
    int32_t element = component == COMPONENT_FLOAT ? 12 : component == COMPONENT_INT ? 4 : 2;
    int32_t count = (int32_t)number(json, member(json, found, "count"), 0);
    int32_t stride = (int32_t)number(json, member(json, view, "byteStride"), element);
    size_t offset = (size_t)number(json, member(json, view, "byteOffset"), 0) + (size_t)number(json, member(json, found, "byteOffset"), 0);
    if (count <= 0 || offset + (size_t)(count - 1) * (size_t)stride + (size_t)element > glb->bin_size) return (Accessor){0};
    return (Accessor){glb->bin + offset, count, stride, component};
}

static uint32_t index_at(Accessor indices, int32_t at) {
    const uint8_t *data = indices.data + (size_t)at * (size_t)indices.stride;
    if (indices.component == COMPONENT_INT) return word_at(data);
    uint16_t half;
    memcpy(&half, data, sizeof half);
    return half;
}

static Point position_at(Accessor positions, uint32_t at) {
    Point point;
    memcpy(&point, positions.data + (size_t)at * (size_t)positions.stride, sizeof point);
    return point;
}

static void append_text(char *out, size_t size, const char *text) {
    size_t used = strlen(out);
    if (strstr(out, text)) return;
    snprintf(out + used, size - used, "%s%s", used ? "," : "", text);
}

// The base color texture's file name.
static void texture_name(const Glb *glb, int32_t material, char *out, size_t size) {
    const Json *json = &glb->json;
    out[0] = 0;
    int32_t color = member(json, member(json, glb->materials[material], "pbrMetallicRoughness"), "baseColorTexture");
    int32_t texture = (int32_t)number(json, member(json, color, "index"), -1);
    if (texture < 0 || texture >= glb->texture_count) return;
    int32_t source = member(json, glb->textures[texture], "source");
    if (source < 0) source = member(json, member(json, member(json, glb->textures[texture], "extensions"), "MSFT_texture_dds"), "source");
    int32_t image = (int32_t)number(json, source, -1);
    if (image < 0 || image >= glb->image_count) return;
    char uri[256];
    copy_text(json, member(json, glb->images[image], "uri"), uri, sizeof uri);
    const char *slash = strrchr(uri, '/');
    snprintf(out, size, "%s", slash ? slash + 1 : uri);
}

typedef struct { Point *corners; int32_t count, room; } Triangles;

static void add_mesh(const Glb *glb, ModelNode *node, Matrix world, Triangles *triangles) {
    const Json *json = &glb->json;
    node->first_triangle = triangles->count;
    node->low = (Point){FLT_MAX, FLT_MAX, FLT_MAX};
    node->high = (Point){-FLT_MAX, -FLT_MAX, -FLT_MAX};
    int32_t primitives = member(json, glb->meshes[node->mesh], "primitives");
    for (int32_t at = 0, primitive = primitives + 1; at < item_count(json, primitives); at++, primitive = after(json, primitive)) {
        int32_t material = (int32_t)number(json, member(json, primitive, "material"), -1);
        if (material >= 0 && material < glb->material_count) {
            char text[128];
            snprintf(text, sizeof text, "%d", material);
            append_text(node->materials, sizeof node->materials, text);
            texture_name(glb, material, text, sizeof text);
            if (text[0]) append_text(node->textures, sizeof node->textures, text);
        }
        if (number(json, member(json, primitive, "mode"), MODE_TRIANGLES) != MODE_TRIANGLES) continue;
        Accessor positions = accessor(glb, (int32_t)number(json, member(json, member(json, primitive, "attributes"), "POSITION"), -1));
        Accessor indices = accessor(glb, (int32_t)number(json, member(json, primitive, "indices"), -1));
        if (positions.count == 0 || positions.component != COMPONENT_FLOAT) continue;
        int32_t corner_count = indices.count ? indices.count : positions.count;
        for (int32_t corner = 0; corner + 2 < corner_count; corner += 3) {
            if (triangles->count + 1 > triangles->room) {
                triangles->room = triangles->room * 2 + 1024;
                triangles->corners = realloc(triangles->corners, (size_t)triangles->room * 3 * sizeof(Point));
            }
            for (int32_t side = 0; side < 3; side++) {
                uint32_t vertex = indices.count ? index_at(indices, corner + side) : (uint32_t)(corner + side);
                if (vertex >= (uint32_t)positions.count) vertex = 0;
                Point point = placed(world, position_at(positions, vertex));
                triangles->corners[triangles->count * 3 + side] = point;
                node->low = (Point){fminf(node->low.x, point.x), fminf(node->low.y, point.y), fminf(node->low.z, point.z)};
                node->high = (Point){fmaxf(node->high.x, point.x), fmaxf(node->high.y, point.y), fmaxf(node->high.z, point.z)};
            }
            triangles->count++;
        }
    }
    node->triangle_count = triangles->count - node->first_triangle;
}

static void add_tree(const Glb *glb, Model *model, int32_t index, int32_t parent, int32_t layer, Matrix parent_world, Triangles *triangles) {
    const Json *json = &glb->json;
    ModelNode *node = &model->nodes[index];
    int32_t token = glb->nodes[index];
    copy_text(json, member(json, token, "name"), node->name, sizeof node->name);
    node->parent = parent;
    node->layer = layer;
    node->drawn = !strstr(node->name, "_DRWOFF_") && (parent < 0 || model->nodes[parent].drawn);
    node->mesh = (int32_t)number(json, member(json, token, "mesh"), -1);
    if (node->mesh >= glb->mesh_count) node->mesh = -1;
    Matrix world = multiplied(parent_world, local_matrix(json, token));
    if (node->mesh >= 0) add_mesh(glb, node, world, triangles);
    int32_t children = member(json, token, "children");
    for (int32_t at = 0, child = children + 1; at < item_count(json, children); at++, child = after(json, child)) {
        int32_t child_index = (int32_t)number(json, child, -1);
        if (child_index >= 0 && child_index < model->node_count) add_tree(glb, model, child_index, index, layer, world, triangles);
    }
}

const char *model_load(Model *model, const char *path) {
    *model = (Model){0};
    OwStr name = {(uint32_t)strlen(path), path};
    int32_t size = ow_content_size(name);
    if (size < GLB_HEADER + CHUNK_HEADER) return "no such glb";
    uint8_t *file = malloc((size_t)size);
    ow_content_read(name, 0, file, (uint32_t)size);
    uint32_t json_size = word_at(file + GLB_HEADER);
    if (memcmp(file, "glTF", 4) || json_size > (uint32_t)size - GLB_HEADER - CHUNK_HEADER) {
        free(file);
        return "not a glb";
    }
    Glb glb = {.json.text = (const char *)file + GLB_HEADER + CHUNK_HEADER};
    size_t bin_at = GLB_HEADER + CHUNK_HEADER + json_size;
    if (bin_at + CHUNK_HEADER <= (size_t)size) {
        glb.bin = file + bin_at + CHUNK_HEADER;
        glb.bin_size = word_at(file + bin_at);
        if (glb.bin_size > (size_t)size - bin_at - CHUNK_HEADER) glb.bin_size = 0;
    }
    jsmn_parser parser;
    jsmn_init(&parser);
    int count = jsmn_parse(&parser, glb.json.text, json_size, NULL, 0);
    glb.json.tokens = malloc((size_t)(count > 0 ? count : 1) * sizeof(jsmntok_t));
    jsmn_init(&parser);
    glb.json.count = count > 0 ? jsmn_parse(&parser, glb.json.text, json_size, glb.json.tokens, (unsigned)count) : 0;
    const Json *json = &glb.json;
    const char *failed = glb.json.count > 0 ? NULL : "bad glb JSON";
    if (!failed) {
        glb.nodes = items(json, member(json, 0, "nodes"), &glb.node_count);
        glb.meshes = items(json, member(json, 0, "meshes"), &glb.mesh_count);
        glb.accessors = items(json, member(json, 0, "accessors"), &glb.accessor_count);
        glb.views = items(json, member(json, 0, "bufferViews"), &glb.view_count);
        glb.materials = items(json, member(json, 0, "materials"), &glb.material_count);
        glb.textures = items(json, member(json, 0, "textures"), &glb.texture_count);
        glb.images = items(json, member(json, 0, "images"), &glb.image_count);
        model->node_count = glb.node_count;
        model->nodes = calloc((size_t)model->node_count + 1, sizeof *model->nodes);
        bool *child = calloc((size_t)model->node_count + 1, sizeof *child);
        for (int32_t index = 0; index < model->node_count; index++) {
            int32_t children = member(json, glb.nodes[index], "children");
            for (int32_t at = 0, token = children + 1; at < item_count(json, children); at++, token = after(json, token)) {
                int32_t child_index = (int32_t)number(json, token, -1);
                if (child_index >= 0 && child_index < model->node_count) child[child_index] = true;
            }
        }
        Triangles triangles = {0};
        for (int32_t index = 0; index < model->node_count; index++)
            if (!child[index]) add_tree(&glb, model, index, -1, index, IDENTITY, &triangles);
        model->corners = triangles.corners;
        free(child);
        free(glb.nodes), free(glb.meshes), free(glb.accessors), free(glb.views);
        free(glb.materials), free(glb.textures), free(glb.images);
    }
    free(glb.json.tokens);
    free(file);
    return failed;
}

void model_free(Model *model) {
    free(model->nodes);
    free(model->corners);
    *model = (Model){0};
}

// --- picking

static Point minus(Point left, Point right) { return (Point){left.x - right.x, left.y - right.y, left.z - right.z}; }
static Point cross(Point left, Point right) {
    return (Point){left.y * right.z - left.z * right.y, left.z * right.x - left.x * right.z, left.x * right.y - left.y * right.x};
}
static float dot(Point left, Point right) { return left.x * right.x + left.y * right.y + left.z * right.z; }

// Whether the ray meets the box at a distance below nearest.
static bool meets_box(Point origin, Point direction, Point low, Point high, float nearest) {
    float origins[3] = {origin.x, origin.y, origin.z}, directions[3] = {direction.x, direction.y, direction.z};
    float lows[3] = {low.x, low.y, low.z}, highs[3] = {high.x, high.y, high.z};
    float enter = 0, leave = nearest;
    for (int axis = 0; axis < 3; axis++) {
        float one = (lows[axis] - origins[axis]) / directions[axis], other = (highs[axis] - origins[axis]) / directions[axis];
        enter = fmaxf(enter, fminf(one, other));
        leave = fminf(leave, fmaxf(one, other));
    }
    return enter <= leave;
}

// The distance along the ray to the triangle, either face; FLT_MAX for a miss.
static float triangle_distance(Point origin, Point direction, const Point corner[3]) {
    Point edge_one = minus(corner[1], corner[0]), edge_two = minus(corner[2], corner[0]);
    Point across = cross(direction, edge_two);
    float determinant = dot(edge_one, across);
    if (fabsf(determinant) < 1e-12f) return FLT_MAX;
    Point from = minus(origin, corner[0]);
    float u = dot(from, across) / determinant;
    if (u < 0 || u > 1) return FLT_MAX;
    Point upward = cross(from, edge_one);
    float v = dot(direction, upward) / determinant;
    if (v < 0 || u + v > 1) return FLT_MAX;
    float distance = dot(edge_two, upward) / determinant;
    return distance > 0 ? distance : FLT_MAX;
}

int32_t model_pick(const Model *model, Point origin, Point direction, const bool *skip) {
    int32_t nearest_node = -1;
    float nearest = FLT_MAX;
    for (int32_t index = 0; index < model->node_count; index++) {
        const ModelNode *node = &model->nodes[index];
        if (skip[index] || !node->drawn || node->triangle_count == 0) continue;
        if (!meets_box(origin, direction, node->low, node->high, nearest)) continue;
        for (int32_t triangle = 0; triangle < node->triangle_count; triangle++) {
            float distance = triangle_distance(origin, direction, &model->corners[(node->first_triangle + triangle) * 3]);
            if (distance < nearest) {
                nearest = distance;
                nearest_node = index;
            }
        }
    }
    return nearest_node;
}
