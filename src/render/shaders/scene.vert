#version 450
// Every scene mesh, skinned or not: a mesh with no skin uses one joint, its model matrix, at weight 1.
// SDL_GPU SPIR-V sets: vertex storage buffers in set 0, vertex uniforms in set 1.

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec2 uv;
layout(location = 3) in uvec4 joints;
layout(location = 4) in vec4 weights;
layout(location = 5) in vec4 vertex_color;

layout(std430, set = 0, binding = 0) readonly buffer Joints { mat4 joint[]; };
layout(std140, set = 1, binding = 0) uniform Frame { mat4 view_projection; };
layout(std140, set = 1, binding = 1) uniform Draw { uint joint_base; };

layout(location = 0) out vec3 world_position;
layout(location = 1) out vec3 world_normal;
layout(location = 2) out vec2 texture_uv;
layout(location = 3) out vec4 color;

void main() {
    mat4 skin = weights.x * joint[joint_base + joints.x] + weights.y * joint[joint_base + joints.y]
              + weights.z * joint[joint_base + joints.z] + weights.w * joint[joint_base + joints.w];
    vec4 world = skin * vec4(position, 1.0);
    world_position = world.xyz;
    world_normal = mat3(skin) * normal;
    texture_uv = uv;
    color = vertex_color;
    gl_Position = view_projection * world;
}
