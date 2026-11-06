#version 450
// Effect quads: world space corners, already facing the camera. SDL_GPU SPIR-V sets: vertex uniforms in set 1.

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 vertex_color;

layout(std140, set = 1, binding = 0) uniform Frame { mat4 view_projection; };

layout(location = 0) out vec2 texture_uv;
layout(location = 1) out vec4 color;

void main() {
    texture_uv = uv;
    color = vertex_color;
    gl_Position = view_projection * vec4(position, 1.0);
}
