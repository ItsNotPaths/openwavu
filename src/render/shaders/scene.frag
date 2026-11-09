#version 450
// Base color texture times vertex color and tint, lit by the scene's ambient and lights, plus a reflection, then its fog. A cut-out
// draw drops pixels with alpha below its cutoff. Scenery above the fighters' feet, between the camera and them, fades.
// SDL_GPU SPIR-V sets: fragment textures in set 2, fragment uniforms in set 3.

const int LIGHTS = 4;

layout(location = 0) in vec3 world_position;
layout(location = 1) in vec3 world_normal;
layout(location = 2) in vec2 texture_uv;
layout(location = 3) in vec4 vertex_color;
layout(location = 4) in vec2 reflection_uv;

layout(set = 2, binding = 0) uniform sampler2D base_color;
layout(set = 2, binding = 1) uniform sampler2D reflection_map;
layout(std140, set = 3, binding = 0) uniform Lighting {
    vec4 ambient;
    vec4 light_position[LIGHTS];   // w: 0 directional, 1 point
    vec4 light_direction[LIGHTS];  // w: a point light's range
    vec4 light_color[LIGHTS];      // a: intensity; all 0 for an unused light
    vec4 fog_color;
    vec4 fog_range;                // x start, y end; end 0 is no fog
    vec4 camera_position;
    vec4 fighter_plane;            // xyz: normal toward the camera, w: offset; in front of the fighters, flat to the camera
    vec4 fighter_fade;             // x: no fade at or below this height, y: gone this far in front of the plane; y 0 = none
};
layout(std140, set = 3, binding = 1) uniform Material {
    vec4 tint;
    float cutoff;  // drop pixels with alpha below it; 0 keeps all
    float scenery;  // 1: fades where it hides a fighter
    float unlit;    // 1: base color only (baked lighting), no scene lights
    float blend;    // 1: drawn by the blend pipeline, which reads the alpha
    float reflection;  // 0: none, 1: reflection_map added, 2: added times the base alpha
    float keep_below;  // drop pixels with alpha at or above it; 0 keeps all
};

layout(location = 0) out vec4 color;

// A 4x4 ordered dither threshold per screen pixel, so a fade needs no sorting or blending.
float dither(vec2 pixel) {
    const float order[16] = float[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
    ivec2 cell = ivec2(pixel) % 4;
    return (order[cell.y * 4 + cell.x] + 0.5) / 16.0;
}

void main() {
    vec4 base = texture(base_color, texture_uv) * vertex_color * tint;
    if (base.a < cutoff || keep_below > 0.0 && base.a >= keep_below) discard;
    vec3 n = normalize(world_normal);
    if (dot(n, camera_position.xyz - world_position) < 0.0) n = -n;  // a double-sided back face lights like its front
    if (scenery > 0.5 && fighter_fade.y > 0.0 && world_position.y > fighter_fade.x) {
        float in_front = dot(world_position, fighter_plane.xyz) - fighter_plane.w;
        if (1.0 - smoothstep(0.0, fighter_fade.y, in_front) < dither(gl_FragCoord.xy)) discard;
    }
    vec3 light = ambient.rgb;
    for (int i = 0; i < LIGHTS; i++) {
        vec3 to_light = -light_direction[i].xyz;
        float falloff = 1.0;
        if (light_position[i].w > 0.5) {
            to_light = light_position[i].xyz - world_position;
            falloff = clamp(1.0 - length(to_light) / light_direction[i].w, 0.0, 1.0);
        }
        light += light_color[i].rgb * light_color[i].a * falloff * max(dot(n, normalize(to_light)), 0.0);
    }
    color = vec4(unlit > 0.5 ? base.rgb : base.rgb * light, blend > 0.5 ? base.a : 1.0);
    if (reflection > 0.5) color.rgb += texture(reflection_map, reflection_uv).rgb * (reflection > 1.5 ? base.a : 1.0);
    if (fog_range.y > 0.0) {
        float fog = clamp((distance(world_position, camera_position.xyz) - fog_range.x) / (fog_range.y - fog_range.x), 0.0, 1.0);
        color.rgb = mix(color.rgb, fog_color.rgb, fog * fog_color.a);
    }
}
