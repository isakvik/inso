#version 460

// uv is the offset from the flashlight center, measured in flashlight radii
in vec3 uv;
in vec4 color;

out vec4 frag_color;

const float EDGE_FALLOFF_END = 1.4;

void main() {
    float dist = length(vec2(uv.x, 1.0 - uv.y));
    float darkness = smoothstep(1.0, EDGE_FALLOFF_END, dist);
    frag_color = vec4(color.rgb, color.a * darkness);
}
