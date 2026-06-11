#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require

layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2DArray textures[];
};
#else
uniform sampler2DArray textures[16];
#endif

// note: multi-input passes read their src texture slots here instead of the quad's texIndex.
// srcSlots.x = first src ("scene"), srcSlots.y = second ("bloom_b").
layout(std140, binding = 16) uniform PostParams {
    uvec4 srcSlots;
};

// note: Lua-configurable params. Shader.set_param(i, v) writes the i-th float into a
// tightly-packed buffer; in std140 those read back as vec4 params[16], so the i-th float
// is params[i/4][i%4]. param 0 is the bloom strength (set in test.lua on_init).
layout(std140, binding = 7) uniform UserParams {
    vec4 params[16];
};
#define BLOOM_STRENGTH params[0].x

in vec3 uv;
in vec4 color;
flat in uint texIndex;

out vec4 fragColor;

void main() {
    vec3 scene = texture(textures[srcSlots.x], vec3(uv.xy, 0.0)).rgb;
    vec3 bloom = texture(textures[srcSlots.y], vec3(uv.xy, 0.0)).rgb;
    // additive blend mode adds this on top of the crisp screen (background + slider bodies),
    // so scene re-adds the captured circles and bloom layers their glow.
    fragColor = vec4(scene + bloom * BLOOM_STRENGTH, 1.0);
}
