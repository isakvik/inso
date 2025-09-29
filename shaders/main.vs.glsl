#version 430

uniform vec4 vs_params[4];
layout(location = 0) in vec4 pos;
layout(location = 1) in vec4 color0;

out vec4 color;
out vec2 uv;
            
void main()
{
    
    gl_Position = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]) * pos;
    color = color0;
}
