#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require
#endif

/*
With a shader, you can do anything. So how do you figure out what to do?
*/

struct Quad {
    vec2 pos_min;
    vec2 pos_max;
    vec2 uv_min;
    vec2 uv_max;
    float tex_layer;
    uint color;
    uint texIndex;
    float angle;
    uint transformIndex;
    uint bodyColor;
    float uvAngle;
    float _padding;
};

layout(binding = 1, std430) readonly buffer vertexData {
    Quad vertices[];
};
layout(binding = 2, std430) readonly buffer transformData {
    mat3 transforms[];
};

out vec4 color;
out vec3 uv;
flat out uint texIndex;
out vec4 bodyColor;

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
    float c = cos(q.angle);
    float s = sin(q.angle);
    mat2 rot = mat2(c, s, -s, c);
    vec2 rotatedPos = center + rot * (localPos - center);

    vec2 texUV = vec2(q_uvs[right].x, q_uvs[bottom].y);
    if (q.uvAngle != 0.0) {
        vec2 uvCenter = (q.uv_min + q.uv_max) * 0.5;
        vec2 quadSize = q.pos_max - q.pos_min;
        vec2 uvSize = q.uv_max - q.uv_min;
        float k = (uvSize.y * quadSize.x) / (uvSize.x * quadSize.y);
        float uc = cos(q.uvAngle);
        float us = sin(q.uvAngle);
        vec2 duv = texUV - uvCenter;
        texUV = uvCenter + vec2(uc * duv.x - us * duv.y / k, us * duv.x * k + uc * duv.y);
    }
    uv = vec3(texUV.x, 1.0 - texUV.y, q.tex_layer);
    color = unpackUnorm4x8(q.color);
    bodyColor = unpackUnorm4x8(q.bodyColor);
    texIndex = q.texIndex;

    vec3 pos = transforms[q.transformIndex] * vec3(rotatedPos, 1.0);
    gl_Position = vec4(pos.xy, 0.0, 1.0);
}
