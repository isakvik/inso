#version 460

in vec3 norm;
in vec2 uv;

out vec4 frag_color;

void main() {
    vec3 n = normalize(norm);
    vec3 light = normalize(vec3(0.4, 0.8, 0.5));
    float diffuse = max(dot(n, light), 0.0);
    float ambient = 0.25;
    vec3 base = n * 0.5 + 0.5; // tint faces by orientation so the cube reads as 3d
    frag_color = vec4(base * (ambient + diffuse), 1.0);
}
