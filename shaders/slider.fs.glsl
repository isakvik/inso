#version 460 core

layout (binding = 6, std140) uniform sliderParams {
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

void main() {
    vec4 tt = vec4(0,1,0,1);
    
    vec4 outer_border_color = vec4(body_color.rgb, color);
    
    if (color < SHADOW_WIDTH) {
        frag_color = vec4(OUTER_SHADOW_COLOR.rgb, color * (OUTER_SHADOW_COLOR.a / SHADOW_WIDTH));
    } 
    if (color >= SHADOW_WIDTH && color < SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) {
        float delta = (color - SHADOW_WIDTH + BORDER_TRANSITION_WIDTH) / (2 * BORDER_TRANSITION_WIDTH);
        //float delta = (color - SHADOW_WIDTH) / (BORDER_TRANSITION_WIDTH);
        
        frag_color = mix(OUTER_SHADOW_COLOR, border_color, delta);
    }
    if (color >= SHADOW_WIDTH + BORDER_TRANSITION_WIDTH && color < SHADOW_WIDTH + BORDER_TRANSITION_WIDTH + BORDER_WIDTH) {
        frag_color = border_color;
    } 
    if (color >= SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH && color < SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH * 2) {
        float width_at = SHADOW_WIDTH + BORDER_WIDTH;
        float delta = (color - width_at - BORDER_TRANSITION_WIDTH) / (2 * BORDER_TRANSITION_WIDTH);
        frag_color = mix(border_color, outer_border_color, delta);
    } 
    if (color >= SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH * 2) {
        float width_at = SHADOW_WIDTH + BORDER_WIDTH + BORDER_TRANSITION_WIDTH * 2;
        float body_t = (color - width_at) / (1.0 - width_at);
        frag_color = vec4(mix(body_color.rgb * 0.7, body_color.rgb, body_t), body_color.a);
    }
}
