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

vec3 prefilter(vec3 c) {
    return max(c - 0.45, 0.0) * 1.8;
}

void main() {
    vec2 texel = 1.0 / vec2(textureSize(textures[texIndex], 0).xy);
    vec3 result = prefilter(texture(textures[texIndex], vec3(uv.xy, 0.0)).rgb) * weights[0];
    for (int i = 1; i < 5; ++i) {
        vec2 off = vec2(texel.x * float(i) * 2.0, 0.0);
        result += prefilter(texture(textures[texIndex], vec3(uv.xy + off, 0.0)).rgb) * weights[i];
        result += prefilter(texture(textures[texIndex], vec3(uv.xy - off, 0.0)).rgb) * weights[i];
    }
    fragColor = vec4(result, 1.0);
}
