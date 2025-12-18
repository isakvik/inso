#version 460
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

#define max_layers 100

// todo(isak) put in buffer
uniform float layer;

struct Vertex {
    vec2 pos;
    vec2 uv;
    vec4 color;
    uint texIndex;
};

layout(binding = 0, std430) readonly buffer vertexData {
    Vertex vertices[];
};
layout(binding = 1, std430) readonly buffer indexData {
    uint indices[];
};
layout (binding = 5, std140) uniform transform {
    vec2 boundsPos;
    vec2 boundsSize;
    float aspectRatio; // note(isak): height over width
};

mat3 getTransform() {
    vec2 center = boundsPos + boundsSize * 0.5;
    float sx = 2.0 * aspectRatio / boundsSize.x;
    float sy = 2.0 / boundsSize.y;
    return mat3(
        vec3(sx, 0.0, 0.0),
        vec3(0.0, sy, 0.0),
        vec3(-sx * center.x, sy * center.y, 1.0)
    );
}

out vec4 color;
out vec2 uv;
flat out uint texIndex;

void main() {
    uint i = indices[gl_VertexID];
    Vertex v = vertices[i];
    uv = v.uv; 
    color = v.color;
    texIndex = v.texIndex;

    vec3 pos = getTransform() * vec3(v.pos.x, -v.pos.y, 1.0); 
    gl_Position = vec4(pos.xy, layer / max_layers, 1.0);
}
