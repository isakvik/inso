#version 460 
#extension GL_ARB_bindless_texture : require

layout(binding = 2, std430) buffer textureHandles {
    sampler2D textures[];
};

in vec2 uv;
in vec4 color;
flat in uint texIndex;

out vec4 frag_color;

void main() {
    frag_color = color;
    frag_color.a *= texture(textures[texIndex], uv).r;
    //frag_color = vec4(uv, 0, 1) * color;
}
