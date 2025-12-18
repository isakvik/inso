package notosu

import "core:math/linalg"
import sa "core:container/small_array"


osu_playfield_size_osupx :: 512

osu_map_hit_objects: sa.Small_Array(128, Hit_Object)

Hit_Object_Type :: enum {
    NONE,
    CIRCLE,
    SLIDER,
    // CUSTOM // note(isak) big plans?
}

Hit_Object :: struct {
    start_time_ms, end_time_ms: f64,
    pos: vec2,
    type: Hit_Object_Type,
}


Game_Mode :: enum {
    UNINITIALIZED,
    MENU,
    PLAY,
}

Osu_Sample_Set :: enum {
    NORMAL,
    SOFT,
    DRUM
}

Osu_Map :: struct {
    audio_filename: string,
    audio_lead_in: f64,
    length_ms: f64,
    sample_set: Osu_Sample_Set
}

game: struct {
    mode: Game_Mode,

    play_timer_ms: f64,
    active_map: Osu_Map
}

make_test_obj :: proc(time, preempt: f64, pos: vec2, type: Hit_Object_Type = .CIRCLE) -> ^Hit_Object {
    sa.append(&osu_map_hit_objects, Hit_Object{
        start_time_ms = time - preempt,
        end_time_ms = time,
        pos = pos,
        type = type
    })
    return &osu_map_hit_objects.data[osu_map_hit_objects.len]
}



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

osu_slider_curve_points_separation: f32 = 2.5

test_nodes: sa.Small_Array(128, Slider_Node)
test_slider: Slider
test_slider2: Slider


make_test_slider :: proc(slider: ^Slider, x_shift: f32) {
    node_i := test_nodes.len

    for i in 0..<20 {
        sa.append(&test_nodes, Slider_Node{{0.056*f32(i) + x_shift, 0}, .LINEAR})
    }

    slider^ = {
        pos = {0 + x_shift, 0},
        nodes = test_nodes.data[node_i + 0:node_i + 20]
    }
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
