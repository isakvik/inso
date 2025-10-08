#version 460
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

#define max_layers 100

// todo(isak) put in buffer
uniform vec4 vs_params[4];
uniform float layer;

struct Vertex {
    vec2 pos;
    vec2 uv;
    vec4 color;
    uint texIndex;
};

layout(binding = 0, std430) buffer vertexData {
    Vertex vertices[];
};
layout(binding = 1, std430) buffer indexData {
    uint indices[];
};

out vec4 color;
out vec2 uv;
flat out uint texIndex;

void main() {
    uint i = indices[gl_VertexID];
    Vertex v = vertices[i];
    uv = v.uv; 
    color = v.color;
    texIndex = v.texIndex;

    vec2 mappedPos = v.pos * 2 - 1.0;
    gl_Position = vec4(mappedPos.x, mappedPos.y * -1, layer / max_layers, 1.0);
}
