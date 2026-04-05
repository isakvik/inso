#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable
#endif

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

layout(binding = 1, std140) readonly buffer vertexData {
    GlyphQuad vertices[];
};

layout (binding = 3, std140) uniform transform {
    mat3 t;
    float circleSizeOsupx;
    float time;
};

out vec4 color;
out vec2 uv;
flat out uint texIndex;

const int instanceToIndex[] = {0, 2, 1, 1, 2, 3};

void main() {
    GlyphQuad q = vertices[gl_VertexID / 6];

    int i = instanceToIndex[gl_VertexID % 6];
    int right =  (i & 1);
    int bottom = ((i >> 1) & 1);

    vec2 pos[2] = {q.pos_min, q.pos_max};
    vec2 uvs[2] = {q.uv_min, q.uv_max};
    Vertex v = {
        vec2(pos[right].x, pos[bottom].y),
        vec2(uvs[right].x, uvs[bottom].y)
    };

    uv = v.uv;
    color = unpackUnorm4x8(q.color);
#ifdef BINDLESS
    texIndex = 2; // global slot for font atlas
#else
    texIndex = 0; // local unit — font atlas bound to unit 0 for text draws
#endif

    gl_Position = vec4(t * vec3(v.pos, 1.0), 1.0);
}
