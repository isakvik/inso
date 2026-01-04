#version 460 core
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

struct Vertex {
    vec3 pos;
};

layout(binding = 1, std430) readonly buffer sliderVertexData {
    Vertex vertices[];
};
layout(binding = 5, std430) readonly buffer sliderInstanceData {
    vec2 points[];
};
layout (binding = 3, std140) uniform transform {
    mat3 t;
};

out float color;

void main() {
    Vertex v = vertices[gl_VertexID];
    vec2 ppos = vec2(v.pos.x, v.pos.y) + points[gl_BaseInstance + gl_InstanceID];
    vec3 pos = t * vec3(ppos, 1.0);

    color = v.pos.z;
    gl_Position = vec4(pos.x, pos.y, 1.0 - v.pos.z, 1.0);
}
