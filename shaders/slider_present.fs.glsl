#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require

layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2DArray textures[];
};
#else
uniform sampler2DArray textures[16];
#endif

layout (binding = 3, std140) uniform globalData {
    mat3 t;
    mat3 playfieldTransform;
    float time;
    float circleSizeOsupx;
    vec2 cursorPos;
    vec2 resolution;
    vec4 sliderBorderColor;
    vec4 sliderBodyColor;
};

in vec3 uv; // xy = tex coords, z = array layer index
in vec4 color;
flat in uint texIndex;

out vec4 frag_color;

// note(isak): band widths are fractions of the circle radius, matching mcosu's slider shader
// (defaultBorderSize / defaultTransitionSize / outerShadowSize)
const float BORDER_WIDTH = 0.11;
const float BORDER_TRANSITION_WIDTH = 0.011;
const float SHADOW_WIDTH = 0.08;

const vec4 OUTER_SHADOW_COLOR = vec4(0.0, 0.0, 0.0, 0.25);

vec4 getInnerBodyColor(vec4 bodyColor) {
	float brightnessMultiplier = 0.25;
	bodyColor.r = min(1.0, bodyColor.r * (1.0 + 0.5 * brightnessMultiplier) + brightnessMultiplier);
	bodyColor.g = min(1.0, bodyColor.g * (1.0 + 0.5 * brightnessMultiplier) + brightnessMultiplier);
	bodyColor.b = min(1.0, bodyColor.b * (1.0 + 0.5 * brightnessMultiplier) + brightnessMultiplier);
	return vec4(bodyColor);
}

vec4 getOuterBodyColor(vec4 bodyColor) {
	float darknessMultiplier = 0.1;
	bodyColor.r = min(1.0, bodyColor.r / (1.0 + darknessMultiplier));
	bodyColor.g = min(1.0, bodyColor.g / (1.0 + darknessMultiplier));
	bodyColor.b = min(1.0, bodyColor.b / (1.0 + darknessMultiplier));
	return vec4(bodyColor);
}

// field: 0 = outside/edge, 1 = path spine
vec4 bandColor(float field) {
    vec4 inner_body = vec4(getInnerBodyColor(sliderBodyColor).rgb, sliderBodyColor.a);
    vec4 outer_body = vec4(getOuterBodyColor(sliderBodyColor).rgb, sliderBodyColor.a);

    if (field < SHADOW_WIDTH - BORDER_TRANSITION_WIDTH) {
        float delta = field / (SHADOW_WIDTH - BORDER_TRANSITION_WIDTH);
        return mix(vec4(0.0), OUTER_SHADOW_COLOR, delta);
    }
    else if (field < SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) {
        float delta = (field - SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) / (2.0 * BORDER_TRANSITION_WIDTH);
        return mix(OUTER_SHADOW_COLOR, sliderBorderColor, delta);
    }
    else if (field < SHADOW_WIDTH + BORDER_WIDTH - BORDER_TRANSITION_WIDTH) {
        return sliderBorderColor;
    }
    else if (field < SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH) {
        float delta = (field - SHADOW_WIDTH - BORDER_WIDTH + BORDER_TRANSITION_WIDTH) / (2.0 * BORDER_TRANSITION_WIDTH);
        return mix(sliderBorderColor, outer_body, delta);
    }
    else {
        float band_start = SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH;
        float delta = (field - band_start) / (1.0 - band_start);
        return mix(outer_body, inner_body, delta);
    }
}

void main() {
    float field = texture(textures[texIndex], uv).r;
    frag_color = bandColor(field) * color;
}
