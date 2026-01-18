#version 460 
#extension GL_ARB_bindless_texture : require

layout (binding = 3, std140) uniform globalData {
    mat3 t;
    float circleSizeOsupx;
    float time;
};
layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2D textures[];
};

in vec2 uv;
in vec4 color;
flat in uint texIndex;

out vec4 frag_color;

void main() {
    frag_color = texture(textures[texIndex], uv) * color;
    //frag_color = vec4(uv, 0, 1) * color;
}
