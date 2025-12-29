#version 460
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

struct GlyphQuad {
    vec2 pos_min;
    vec2 pos_max;
    vec2 uv_min;
    vec2 uv_max;
    uint color;
};

struct Vertex {
    vec2 pos;
    vec2 uv;
};

layout(binding = 0, std140) readonly buffer vertexData {
    GlyphQuad vertices[];
};

layout (binding = 5, std140) uniform transform {
    mat3 t;
};

out vec4 color;
out vec2 uv;
flat out uint texIndex;

const int instanceToIndex[] = {0, 2, 1, 1, 2, 3};

void main() {
    GlyphQuad q = vertices[gl_VertexID / 6];

    int index = instanceToIndex[gl_VertexID % 6];
    int right =  (index & 1);
    int bottom = ((index >> 1) & 1);

    vec2 pos[2] = {q.pos_min, q.pos_max};
    vec2 uvs[2] = {q.uv_min, q.uv_max};
    Vertex v = {
        vec2(pos[right].x, pos[bottom].y),
        vec2(uvs[right].x, uvs[bottom].y)
    };
    
    uv = v.uv;
    color = unpackUnorm4x8(q.color);
    texIndex = 2;

    gl_Position = vec4(t * vec3(v.pos, 1.0), 1.0);
}
