#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable
#endif

struct Vertex {
    vec3 pos;
    vec3 norm;
    vec2 uv;
};

layout(binding = 1, std430) readonly buffer vertexData {
    Vertex vertices[];
};
layout(binding = 2, std430) readonly buffer indexData {
    uint indices[];
};
layout (binding = 3, std140) uniform globalData {
    mat3 t;
    mat3 playfieldTransform;
    float time;
    float circleSizeOsupx;
    vec2 cursorPos;
    vec2 resolution;
    mat4 mvp;
};

out vec3 norm;
out vec2 uv;
out vec4 color;
flat out uint texIndex;

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

    uv = vec2(q_uvs[right].x, q_uvs[bottom].y);
    color = unpackUnorm4x8(q.color);
    texIndex = q.texIndex;

    vec3 pos = t * vec3(rotatedPos, 1.0);
    gl_Position = vec4(pos.xy, 0.0, 1.0);
}
