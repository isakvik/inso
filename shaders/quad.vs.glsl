#version 460
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

/*
With a shader, you can do anything. So how do you figure out what to do?
*/

struct Quad {
    vec2 pos_min;
    vec2 pos_max;
    vec2 uv_min;
    vec2 uv_max;
    uint color;
    uint texIndex;
    float angle;
    uint padding;
};

layout(binding = 1, std430) readonly buffer vertexData {
    Quad vertices[];
};
layout(binding = 2, std430) readonly buffer indexData {
    uint indices[];
};
layout (binding = 3, std140) uniform globalData {
    mat3 t;
    float circleSizeOsupx;
    float time;
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

    vec2 localPos = vec2(q_pos[right].x, q_pos[bottom].y);
    vec2 center = (q.pos_min + q.pos_max) * 0.5;
    float c = cos(radians(q.angle));
    float s = sin(radians(q.angle));
    mat2 rot = mat2(c, s, -s, c);
    vec2 rotatedPos = center + rot * (localPos - center);

    uv = vec2(q_uvs[right].x, 1.0 - q_uvs[bottom].y); 
    color = unpackUnorm4x8(q.color);
    texIndex = q.texIndex;

    vec3 pos = t * vec3(rotatedPos, 1.0); 
    gl_Position.xy = pos.xy;
    //gl_Position.z = gl_VertexID / 65536.0;
}
