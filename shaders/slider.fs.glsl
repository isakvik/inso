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

const float BORDER_WIDTH = 0.10;
const float BORDER_TRANSITION_WIDTH = 0.011;
const float SHADOW_WIDTH = 0.08;

const vec4 OUTER_SHADOW_COLOR = vec4(0.0, 0.0, 0.0, 0.2);

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
    vec4 tt = vec4(0,1,0,1);
    
    vec4 outer_border_color = vec4(body_color.rgb, color);
    
    if (color < SHADOW_WIDTH) {
        frag_color = vec4(OUTER_SHADOW_COLOR.rgb, color * (OUTER_SHADOW_COLOR.a / SHADOW_WIDTH));
    } 
    else if (color >= SHADOW_WIDTH && color < SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) {
        float delta = (color - SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) / (2 * BORDER_TRANSITION_WIDTH);
        //float delta = (color - SHADOW_WIDTH) / (BORDER_TRANSITION_WIDTH);
        
        frag_color = mix(OUTER_SHADOW_COLOR, border_color, delta);
    }
    else if (color >= SHADOW_WIDTH + BORDER_TRANSITION_WIDTH && color < SHADOW_WIDTH + BORDER_TRANSITION_WIDTH + BORDER_WIDTH) {
        frag_color = border_color;
    } 
    else if (color >= SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH && color < SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH * 2) {
        float width_at = SHADOW_WIDTH + BORDER_WIDTH;
        float delta = (color - width_at - BORDER_TRANSITION_WIDTH) / (2 * BORDER_TRANSITION_WIDTH);
        frag_color = mix(border_color, outer_border_color, delta);
    } 
    else if (color >= SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH * 2) {
        float width_at = SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH * 2;
        float body_t = (color - width_at) / (1.0 - width_at);

        vec4 inner = vec4(getInnerBodyColor(body_color).rgb, body_color.a);
        vec4 outer = vec4(getOuterBodyColor(body_color).rgb, body_color.a);
        
        frag_color = mix(outer, inner, body_t);
    }
}
