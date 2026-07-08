#version 460 core

layout (binding = 6, std140) uniform sliderParams {
    mat3 transform;
    vec4 border_color;
    vec4 body_color;
    vec2 script_translation_osupx;
    uint baseInstance;
    float radiusOsupx;
};

in float color; // 0 = edge, 1 = center

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

void main() {
    vec4 inner_body = vec4(getInnerBodyColor(body_color).rgb, body_color.a);
    vec4 outer_body = vec4(getOuterBodyColor(body_color).rgb, body_color.a);

    if (color < SHADOW_WIDTH - BORDER_TRANSITION_WIDTH) {
        float delta = color / (SHADOW_WIDTH - BORDER_TRANSITION_WIDTH);
        frag_color = mix(vec4(0.0), OUTER_SHADOW_COLOR, delta);
    }
    else if (color < SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) {
        float delta = (color - SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) / (2.0 * BORDER_TRANSITION_WIDTH);
        frag_color = mix(OUTER_SHADOW_COLOR, border_color, delta);
    }
    else if (color < SHADOW_WIDTH + BORDER_WIDTH - BORDER_TRANSITION_WIDTH) {
        frag_color = border_color;
    }
    else if (color < SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH) {
        float delta = (color - SHADOW_WIDTH - BORDER_WIDTH + BORDER_TRANSITION_WIDTH) / (2.0 * BORDER_TRANSITION_WIDTH);
        frag_color = mix(border_color, outer_body, delta);
    }
    else {
        float band_start = SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH;
        float delta = (color - band_start) / (1.0 - band_start);
        frag_color = mix(outer_body, inner_body, delta);
    }
}
