#version 460 
#extension GL_ARB_bindless_texture : require

layout (binding = 3, std140) uniform globalData {
    mat3 t;
    float circleSizeOsupx;
    float time;
    mat4 mvp;
};
layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2D textures[];
};

in vec3 norm;
in vec2 uv;
in vec4 color;
flat in uint texIndex;

out vec4 frag_color;

void main() {
    frag_color = vec4(norm, 1.0) * color;
    //frag_color = vec4(uv, 0, 1) * color;
}
