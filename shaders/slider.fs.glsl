#version 460 core

in float color; // 0 = edge, 1 = center

out vec4 frag_color;

// note(isak): writes the radial distance field into the R16F SLIDERS target. overlapping
// circles resolve through MAX blending: max over circles of (1 - d/r) == 1 - dist_to_path/r.
// banding into border/body colors happens in slider_present.fs at composite time.
void main() {
    frag_color = vec4(color, 0.0, 0.0, 1.0);
}
