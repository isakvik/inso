#version 460 core

in float color;

out vec4 frag_color;

void main() {
    float pixelColor = color;
    frag_color = vec4(vec3(pixelColor), 1.0);
}
