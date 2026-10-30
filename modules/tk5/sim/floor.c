// The floor polygon of the stage: the height of its plane under a point, if the point is inside in the ground plane.
#include <math.h>

#include "sim/collision.h"
#include "sim/math.h"

static constexpr float AREA_TOLERANCE = 0.001f;  // the areas of the corner triangles may differ from the polygon by this share

static float triangle_area(T5Vec4 first, T5Vec4 second, T5Vec4 third) {
    float edge_x = t5_vmx_subtract(second.x, first.x);
    float edge_z = t5_vmx_subtract(second.z, first.z);
    float third_x = t5_vmx_subtract(third.x, first.x);
    float third_z = t5_vmx_subtract(third.z, first.z);
    return fabsf(fmaf(edge_x, third_z, -(edge_z * third_x)));  // cross product size: twice the triangle area
}

// The inside test: the triangles from the point to each side add up to the polygon.
T5FloorHeight t5_floor_polygon_y(const T5Vec4 *position, const T5FloorPolygon *polygon) {
    const T5Vec4 *vertices = polygon->vertices;
    int32_t count = polygon->count;
    float area = 0.0f, point_area = 0.0f;
    for (int32_t vertex = 0; vertex < count - 2; vertex++)  // fan of triangles from the last corner: their sum is the polygon
        area += triangle_area(vertices[vertex], vertices[vertex + 1], vertices[count - 1]);
    int32_t last = 0;
    for (int32_t vertex = 0; vertex < count - 1; vertex++) {  // sum the triangles from the point to each side
        point_area += triangle_area(vertices[vertex], vertices[vertex + 1], *position);
        last = vertex + 1;
    }
    float closing = triangle_area(vertices[last], vertices[0], *position);  // the side from the last vertex back to the first
    if (!(fabsf(area - (closing + point_area)) <= fabsf(area * AREA_TOLERANCE))) return (T5FloorHeight){false, 0.0f};  // outside
    T5Vec3 normal = {polygon->normal.x, polygon->normal.y, polygon->normal.z};
    float dot = vec3_dot(normal, vec3_of(vertices[0]));  // plane offset from the first vertex
    float y = (1.0f / normal.y) * ((dot - normal.x * position->x) - normal.z * position->z);  // solve the plane for y
    return (T5FloorHeight){true, y};
}

float t5_floor_polygon(float height, const T5Vec4 *position, const T5FloorPolygon *polygon) {
    T5FloorHeight under = t5_floor_polygon_y(position, polygon);
    if (under.inside && height < under.y) height = under.y;  // raise height to the floor if it is higher
    return height;
}
