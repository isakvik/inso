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
layout(std140, binding = 14) uniform PostParams {
    uvec4 srcSlots;
};

in vec3 uv;
in vec4 color;
flat in uint texIndex;

out vec4 fragColor;

void main() {
    vec3 scene = texture(textures[srcSlots.x], vec3(uv.xy, 0.0)).rgb;
    vec3 bloom = texture(textures[srcSlots.y], vec3(uv.xy, 0.0)).rgb;
    // additive blend mode adds this on top of the crisp screen (background + slider bodies),
    // so scene re-adds the captured circles and bloom layers their glow.
    fragColor = vec4(scene + bloom * 1.4, 1.0);
}
