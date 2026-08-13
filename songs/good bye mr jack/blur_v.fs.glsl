#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require

layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2DArray textures[];
};
#else
uniform sampler2DArray textures[16];
#endif

in vec3 uv;
in vec4 color;
flat in uint texIndex;

out vec4 fragColor;

const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);

layout(std140, binding = 7) uniform UserParams {
    vec4 params[16];
};
#define TEXEL params[3].yz

void main() {
    vec2 off = vec2(0.0, TEXEL.y);
    vec3 result = texture(textures[texIndex], vec3(uv.xy, 0.0)).rgb * weights[0];
    result += texture(textures[texIndex], vec3(uv.xy + off * 2.0, 0.0)).rgb * weights[1];
    result += texture(textures[texIndex], vec3(uv.xy - off * 2.0, 0.0)).rgb * weights[1];
    result += texture(textures[texIndex], vec3(uv.xy + off * 4.0, 0.0)).rgb * weights[2];
    result += texture(textures[texIndex], vec3(uv.xy - off * 4.0, 0.0)).rgb * weights[2];
    result += texture(textures[texIndex], vec3(uv.xy + off * 6.0, 0.0)).rgb * weights[3];
    result += texture(textures[texIndex], vec3(uv.xy - off * 6.0, 0.0)).rgb * weights[3];
    result += texture(textures[texIndex], vec3(uv.xy + off * 8.0, 0.0)).rgb * weights[4];
    result += texture(textures[texIndex], vec3(uv.xy - off * 8.0, 0.0)).rgb * weights[4];
    fragColor = vec4(result, 1.0);
}
