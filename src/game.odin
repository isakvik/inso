package notosu

import "core:math/linalg"


Slider_Node_Type :: enum {
    LINEAR,
    BEZIER_NODE,
    ARC,
}

Slider_Node :: struct {
    pos: vec2,
    type: Slider_Node_Type
}

Slider :: struct {
    pos: vec2,
    nodes: []Slider_Node, // note(isak): slice into our array of all nodes
}


Difficulty_Setting :: struct {
    circle_size_osupx: f32
}


Layer :: enum {
    DEFAULT,
    BACKGROUND,
    FOREGROUND,
    HIT_OBJECT,
    OVERLAY,
    DEBUG
}


test_nodes: [128]Slider_Node
test_node_count: i32
test_slider: Slider
test_slider2: Slider


make_test_slider :: proc(slider: ^Slider, x_shift: f32) {
    node_i := test_node_count
    test_nodes[node_i + 0] = {{0.0 + x_shift, 0.0}, .LINEAR}
    //test_nodes[node_i + 1] = {{0.2 + x_shift, 0.2}, .LINEAR}
    //test_nodes[node_i + 2] = {{0.3 + x_shift, 0.0}, .LINEAR}
    //test_nodes[node_i + 3] = {{0.4 + x_shift, 0.2}, .LINEAR}

    slider^ = {
        pos = {0 + x_shift, 0},
        nodes = test_nodes[node_i + 0 : node_i + 1]
    }
    test_node_count += 1
}

push_slider :: proc(renderer: ^Renderer, slider: ^Slider) {
    instance_at := renderer.slider_instances.count
    for i in 0..<len(slider.nodes) {
        buffer_push(&renderer.slider_instances, slider.nodes[i].pos)
    }

    command_push_draw_slider(Command_Draw_Slider{
        base_instance = u32(instance_at),
        instance_count = renderer.slider_instances.count - instance_at
    })
}

line_normal :: proc(from_to: vec2) -> vec2 {
    return linalg.normalize(linalg.vector2_orthogonal(from_to))
}
