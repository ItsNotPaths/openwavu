#version 450
// Base color texture times vertex color and tint, lit by the scene's ambient and lights, then its fog. A cut-out
// draw drops pixels below half alpha.
// SDL_GPU SPIR-V sets: fragment textures in set 2, fragment uniforms in set 3.

const int LIGHTS = 4;

layout(location = 0) in vec3 world_position;
layout(location = 1) in vec3 world_normal;
layout(location = 2) in vec2 texture_uv;
layout(location = 3) in vec4 vertex_color;

layout(set = 2, binding = 0) uniform sampler2D base_color;
layout(std140, set = 3, binding = 0) uniform Lighting {
    vec4 ambient;
    vec4 light_position[LIGHTS];   // w: 0 directional, 1 point
    vec4 light_direction[LIGHTS];  // w: a point light's range
    vec4 light_color[LIGHTS];      // a: intensity; all 0 for an unused light
    vec4 fog_color;
    vec4 fog_range;                // x start, y end; end 0 is no fog
    vec4 camera_position;
};
layout(std140, set = 3, binding = 1) uniform Material {
    vec4 tint;
    float cutout;  // 1: drop pixels below half alpha
};

layout(location = 0) out vec4 color;

void main() {
    vec4 base = texture(base_color, texture_uv) * vertex_color * tint;
    if (cutout > 0.5 && base.a < 0.5) discard;
    vec3 n = normalize(world_normal);
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
    color = vec4(base.rgb * light, 1.0);
    if (fog_range.y > 0.0) {
        float fog = clamp((distance(world_position, camera_position.xyz) - fog_range.x) / (fog_range.y - fog_range.x), 0.0, 1.0);
        color.rgb = mix(color.rgb, fog_color.rgb, fog * fog_color.a);
    }
}
