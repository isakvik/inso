#version 460 
#extension GL_ARB_bindless_texture : require

layout (binding = 3, std140) uniform globalData {
    mat3 t;
    float circleSizeOsupx;
    float time;
};
layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2D textures[];
};

in vec3 uv;
in vec4 color;
flat in uint texIndex;

out vec4 frag_color;

#define PI 3.1415926535897
#define TAU (2.0 * PI)

//Convert rectangular to polar coordinates
vec2 rect_to_polar(vec2 rect) {
    float r = length(rect);
    float theta = atan(rect.y, rect.x) + PI;
    
    return vec2(r, theta / TAU);
}

vec2 rotateZAxis(vec2 uv, float th) {
  return mat2(cos(th), sin(th), -sin(th), cos(th)) * uv;
}

void main() {
    float s = time * 0.001;
    vec2 delta = (gl_FragCoord.xy - vec2(1280, 720) * 0.5) / 720;
    float c = length(delta);

    vec2 polar = rect_to_polar(delta);
    polar.y = abs(polar.y - 0.5)*2;
    float swirl = 0.5 * sin(polar.x - s)+0.5;

    polar.x = sin((polar.x-s*0.01) * 20)*0.5+0.5;
    
    vec2 coords = uv.xy + rotateZAxis(polar, s)*0.05;
    frag_color = texture(textures[texIndex], clamp(coords, 0.001, 1.0)) * color;
    //frag_color = vec4(rotateZAxis(polar, s), 0, 1);
}
