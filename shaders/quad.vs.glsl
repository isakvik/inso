#version 460
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

struct Quad {
    vec2 pos_min;
    vec2 pos_max;
    vec2 uv_min;
    vec2 uv_max;
    uint color;
    uint texIndex;
};

layout(binding = 1, std430) readonly buffer vertexData {
    Quad vertices[];
};
layout(binding = 2, std430) readonly buffer indexData {
    uint indices[];
};
layout (binding = 3, std140) uniform transform {
    mat3 t;
};

out vec4 color;
out vec2 uv;
flat out uint texIndex;

const uint instanceToIndex[] = {0, 2, 1, 1, 2, 3};

void main() {
    Quad q = vertices[gl_VertexID / 6];

    uint i = instanceToIndex[gl_VertexID % 6];
    uint right =  (i & 1);
    uint bottom = ((i >> 1) & 1);
    
    vec2 q_pos[2] = {q.pos_min, q.pos_max};
    vec2 q_uvs[2] = {q.uv_min, q.uv_max};

    uv = vec2(q_uvs[right].x, q_uvs[bottom].y); 
    color = unpackUnorm4x8(q.color);
    texIndex = q.texIndex;

    vec3 pos = t * vec3(q_pos[right].x, q_pos[bottom].y, 1.0); 
    gl_Position.xy = pos.xy;
}
