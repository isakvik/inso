#version 460 core
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require
#endif

struct Vertex {
    vec3 pos;
};

layout(binding = 1, std430) readonly buffer sliderVertexData {
    Vertex vertices[];
};
layout(binding = 5, std430) readonly buffer sliderInstanceData {
    vec2 points[];
};
layout (binding = 6, std140) uniform sliderParams {
    mat3 transform;
    vec2 script_translation_osupx;
    uint baseInstance;
    float radiusOsupx;
};

out float color;

void main() {
    Vertex v = vertices[gl_VertexID];
    vec2 ppos = vec2(v.pos.x, v.pos.y) + (points[baseInstance + gl_InstanceID] + script_translation_osupx) / radiusOsupx;
    vec3 pos = transform * vec3(ppos, 1.0);

    color = 1.0 - length(v.pos.xy); // true radial distance: 0 at edge, 1 at center
    gl_Position = vec4(pos.x, pos.y, 0.0, 1.0);
}
