#include "sim/stage.h"

static bool in_layer(const T5World *w, const T5FloorPolygon *polygon, uint32_t layer) {
    return (w->stage->surfaces[polygon->surface].layers & layer) != 0;
}

static bool known_list(int32_t list) { return list >= 1 && list <= T5_LAYER_LISTS; }

#define EACH_FLOOR(w, polygon) \
    for (const T5FloorPolygon *polygon = (w)->stage->floors; polygon < (w)->stage->floors + (w)->stage->floor_count; polygon++)

float t5_stage_floor(const T5World *w, T5Vec3 point) {
    float depth = w->stage_depth, height = -depth;  // start at the very bottom of the stage
    if (t5_floor_disabled(w)) return 0.0f;  // floor is switched off, so the ground is flat at zero
    T5Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) if (in_layer(w, polygon, T5_LAYER_FLOOR)) height = t5_floor_polygon(height, &position, polygon);
    return height == -depth ? 0.0f : height;  // no floor found under the point, use zero
}

T5StageHeight t5_stage_height(const T5World *w, T5Vec3 point) {
    if (t5_floor_disabled(w))  // floor is off: flat zero, and only an object floor sets the material
        return (T5StageHeight){0.0f, w->stage_state.object_floor ? T5_MATERIAL_OBJECT_FLOOR : 0};
    T5StageHeight high = {-w->stage_depth, 0};
    T5Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) {
        if (!in_layer(w, polygon, T5_LAYER_FLOOR)) continue;
        T5FloorHeight under = t5_floor_polygon_y(&position, polygon);
        if (under.inside && high.y < under.y)  // new highest, the first one wins a tie
            high = (T5StageHeight){under.y, w->stage->surfaces[polygon->surface].material};
    }
    return high;
}

float t5_stage_special(const T5World *w, T5Vec3 point, int32_t list) {
    float height = -w->stage_depth;
    if (list == 1 && w->stage_state.object_floor) return w->stage_state.object_floor_y;  // a stage object floor overrides list 1
    if (t5_floor_disabled(w)) return 0.0f;  // floor is switched off, so the ground is flat at zero
    if (!known_list(list)) return height;  // unknown list: report the bottom of the stage
    T5Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) if (in_layer(w, polygon, 1u << list)) height = t5_floor_polygon(height, &position, polygon);
    return height;
}

float t5_stage_lowest(const T5World *w, T5Vec3 point, int32_t list) {
    float height = w->stage_depth;
    if (t5_floor_disabled(w)) return w->stage_state.disabled_ceiling;  // floor is off, so use the stored ceiling
    if (!known_list(list)) return height;  // unknown list: report the bottom of the stage
    T5Vec4 position = vec4_of(point, 0.0f);
    EACH_FLOOR(w, polygon) {
        if (!in_layer(w, polygon, 1u << list)) continue;
        T5FloorHeight under = t5_floor_polygon_y(&position, polygon);
        if (under.inside && under.y < height) height = under.y;
    }
    return height;
}
