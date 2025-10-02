#version 430

#define max_layers 100

// todo(isak) put in buffer
uniform vec4 vs_params[4];
uniform float layer;

struct Vertex {
    vec2 pos;
    vec2 uv;
    vec4 color;
};

layout(binding = 0, std430) buffer vertexData {
    Vertex vertices[];
};
layout(binding = 1, std430) buffer indexData {
    unsigned int indices[];
};

out vec4 color;
out vec2 uv;

void main() {
    uint i = indices[gl_VertexID];
    Vertex v = vertices[i];
    uv = v.uv; 
    color = v.color;
    vec2 mappedPos = v.pos * 2 - 1.0;
    gl_Position = vec4(mappedPos.x, mappedPos.y * -1, layer / max_layers, 1.0);
}
