#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require

layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2DArray textures[];
};
#else
uniform sampler2DArray textures[16];
#endif

in vec2 uv;
in vec4 color;
flat in uint texIndex;

out vec4 frag_color;

void main() {
    frag_color = color;
    frag_color.a *= texture(textures[texIndex], vec3(uv, 0.0)).r;
    //frag_color = vec4(uv, 0.0, 1.0) * color;
}
