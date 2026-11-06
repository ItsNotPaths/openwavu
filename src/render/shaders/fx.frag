#version 450
// An effect quad: its flipbook frame times its colour and opacity, unlit. SDL_GPU SPIR-V sets: fragment textures in set 2.

layout(location = 0) in vec2 texture_uv;
layout(location = 1) in vec4 vertex_color;

layout(set = 2, binding = 0) uniform sampler2D frame;

layout(location = 0) out vec4 color;

void main() {
    color = texture(frame, texture_uv) * vertex_color;
}
