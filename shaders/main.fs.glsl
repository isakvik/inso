#version 430 

layout(binding = 0) uniform sampler2D tex_smp;
            
in vec4 color;
                
out vec4 frag_color;
            
void main() {
    frag_color = color;
}
