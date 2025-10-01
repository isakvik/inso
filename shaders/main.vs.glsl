#version 430

uniform vec4 vs_params[4];

struct Vertex {
    vec2 pos;
    vec2 uv;
    vec4 color;
};

layout(binding = 0, std430) buffer vertexData {
    Vertex vertices[];
};

out vec4 color;
out vec2 uv;
            
void main()
{
    Vertex v = vertices[gl_VertexID];
    uv = v.uv;
    color = v.color;  
    gl_Position = vec4(v.pos, 0.0, 1.0);
}
