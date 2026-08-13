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

// note: this pass doubles as the bloom prefilter, keeping only the bright parts of the
// captured scene before the horizontal gaussian. blur_v then just blurs.
const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);

layout(std140, binding = 7) uniform UserParams {
    vec4 params[16];
};
#define TEXEL params[3].yz

vec3 prefilter(vec3 c) {
    return max(c - 0.45, 0.0) * 1.8;
}

void main() {
    vec2 off = vec2(TEXEL.x, 0.0);
    vec3 result = prefilter(texture(textures[texIndex], vec3(uv.xy, 0.0)).rgb) * weights[0];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy + off * 2.0, 0.0)).rgb) * weights[1];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy - off * 2.0, 0.0)).rgb) * weights[1];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy + off * 4.0, 0.0)).rgb) * weights[2];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy - off * 4.0, 0.0)).rgb) * weights[2];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy + off * 6.0, 0.0)).rgb) * weights[3];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy - off * 6.0, 0.0)).rgb) * weights[3];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy + off * 8.0, 0.0)).rgb) * weights[4];
    result += prefilter(texture(textures[texIndex], vec3(uv.xy - off * 8.0, 0.0)).rgb) * weights[4];
    fragColor = vec4(result, 1.0);
}
