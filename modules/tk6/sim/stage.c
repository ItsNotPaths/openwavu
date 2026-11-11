#include "sim/stage.h"

static bool in_layer(const T6World *w, const T6FloorPolygon *polygon, uint32_t layer) {
    return (w->stage->surfaces[polygon->surface].layers & layer) != 0;
}

static bool known_list(int32_t list) { return list >= 1 && list <= T6_LAYER_LISTS; }

#define EACH_FLOOR(w, polygon) \
    for (const T6FloorPolygon *polygon = (w)->stage->floors; polygon < (w)->stage->floors + (w)->stage->floor_count; polygon++)

float t6_stage_floor(const T6World *w, T6Vec3 point) {
    float depth = w->stage_depth, height = -depth;  // start at the very bottom of the stage
    if (t6_floor_disabled(w)) return 0.0f;  // floor is switched off, so the ground is flat at zero
    T6Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) if (in_layer(w, polygon, T6_LAYER_FLOOR)) height = t6_floor_polygon(height, &position, polygon);
    return height == -depth ? 0.0f : height;  // no floor found under the point, use zero
}

T6StageHeight t6_stage_height(const T6World *w, T6Vec3 point) {
    if (t6_floor_disabled(w))  // floor is off: flat zero, and only an object floor sets the material
        return (T6StageHeight){0.0f, w->stage_state.object_floor ? T6_MATERIAL_OBJECT_FLOOR : 0};
    T6StageHeight high = {-w->stage_depth, 0};
    T6Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) {
        if (!in_layer(w, polygon, T6_LAYER_FLOOR)) continue;
        T6FloorHeight under = t6_floor_polygon_y(&position, polygon);
        if (under.inside && high.y < under.y)  // new highest, the first one wins a tie
            high = (T6StageHeight){under.y, w->stage->surfaces[polygon->surface].material};
    }
    return high;
}

float t6_stage_special(const T6World *w, T6Vec3 point, int32_t list) {
    float height = -w->stage_depth;
    if (list == 1 && w->stage_state.object_floor) return w->stage_state.object_floor_y;  // a stage object floor overrides list 1
    if (t6_floor_disabled(w)) return 0.0f;  // floor is switched off, so the ground is flat at zero
    if (!known_list(list)) return height;  // unknown list: report the bottom of the stage
    T6Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) if (in_layer(w, polygon, 1u << list)) height = t6_floor_polygon(height, &position, polygon);
    return height;
}

float t6_stage_lowest(const T6World *w, T6Vec3 point, int32_t list) {
    float height = w->stage_depth;
    if (t6_floor_disabled(w)) return w->stage_state.disabled_ceiling;  // floor is off, so use the stored ceiling
    if (!known_list(list)) return height;  // unknown list: report the bottom of the stage
    T6Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) {
        if (!in_layer(w, polygon, 1u << list)) continue;
        T6FloorHeight under = t6_floor_polygon_y(&position, polygon);
        if (under.inside && under.y < height) height = under.y;
    }
    return height;
}
