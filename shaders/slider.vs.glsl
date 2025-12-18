#version 460 core
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable

struct Vertex {
    vec3 pos;
};

layout(binding = 3, std430) readonly buffer sliderVertexData {
    Vertex vertices[];
};
layout(binding = 4, std430) readonly buffer sliderInstanceData {
    vec2 points[];
};
layout (binding = 5, std140) uniform transform {
    vec2 boundPos;
    vec2 boundSize;
    float aspectRatio; // note(isak): height over width
};

out float color;

void main() {
    Vertex v = vertices[gl_VertexID];
    vec2 pos = vec2(v.pos.x, v.pos.y) * 1
            + points[gl_BaseInstance + gl_InstanceID];
    pos += vec2(boundPos.x, boundPos.y);
    pos *= boundSize / 4;

    color = v.pos.z;
    gl_Position = vec4(pos.x, -pos.y, -v.pos.z, 1.0);
}
