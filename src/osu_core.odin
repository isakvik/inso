package notosu

import "core:math/linalg"
import sa "core:container/small_array"


osu_playfield_size_osupx :: 512

osu_map_hit_objects: sa.Small_Array(128, Hit_Object)

Hit_Object_Type :: enum {
    NONE,
    CIRCLE,
    SLIDER,
    SPINNER,
    // CUSTOM // note(isak) big plans?
}

Hit_Object :: struct {
    start_time_ms, end_time_ms: f64,
    pos: vec2,
    type: Hit_Object_Type,
    
    type_flags: int,
    hitsound_flags: byte,
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
    sample_set: Osu_Sample_Set,

    title: string,
    title_unicode: string,
    artist: string,
    artist_unicode: string,
    creator: string,
    difficulty_name: string,

    diff_hp_drain: f64,
    diff_circle_size: f64,
    diff_overall_difficulty: f64,
    diff_approach_rate: f64,
    diff_slider_velocity: f64,
    diff_slider_tickrate: int,

    hit_objects: []Hit_Object
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

circle_radius_osupx: f32 = 40

make_test_slider :: proc(slider: ^Slider, x_shift: f32) {
    node_i := test_nodes.len

    for i in 0..<4 {
        sa.append(&test_nodes, Slider_Node{{100*f32(i)/circle_radius_osupx, 100*f32(i)/circle_radius_osupx}, .LINEAR})
    }

    slider^ = {
        pos = {0 + x_shift, 0},
        nodes = test_nodes.data[node_i + 0:node_i + 20]
    }
}

render_hit_object :: proc(renderer: ^Renderer, hobj: ^Hit_Object) {
    
    if game.play_timer_ms < hobj.start_time_ms {
        return
    }

    #partial switch hobj.type {
        case .CIRCLE: {
            if hobj.start_time_ms < game.play_timer_ms && game.play_timer_ms < hobj.end_time_ms {
                ho_pos := rect_translate_by_anchor(Rect{hobj.pos.x, hobj.pos.y, 40, 40}, .CENTER)
                push_rect(&renderer.quad_geometry, ho_pos, vec4(0.5), skin_texture_slot(.HITCIRCLE))
            }
        }
        case .SLIDER: {
            render_slider(renderer, &test_slider)
        }
    }

}

render_slider :: proc(renderer: ^Renderer, slider: ^Slider) {
    // todo(isak): we don't need to do the instance writing immediate mode, just do a pass on instances on mapset load
    // and generate the draws and the bounding quads like the smart cookie you are

    instance_at := renderer.slider_instances.count
    for i in 0..<len(slider.nodes) {
        buffer_push(&renderer.slider_instances, slider.nodes[i].pos)
    }

    command_push_bind_pipeline({.SLIDER})
    command_push_bind_framebuffer({ write = .SLIDERS })
    command_push_clear()

    pf_size: f32 = 512/circle_radius_osupx

    command_push_push_transform({transform_from_bounds({0,0,pf_size,pf_size}, window.aspect_ratio)})

    command_push_draw_slider(Command_Draw_Slider{
        base_instance = u32(instance_at),
        instance_count = renderer.slider_instances.count - instance_at
    })
    
    command_push_bind_framebuffer({ read = .SLIDERS })
    command_push_bind_pipeline({.QUAD})
    
    begin_draw_with_transform(transform_from_bounds({0, 0, 1, 1}, 1))
    push_rect(&renderer.quad_geometry, {0, 0, 1, 1}, {1, 1, 1, 0.5}, reserved_texture(.SLIDER_FRAMEBUFFER))
}


convert_approach_rate_to_preempt :: proc(ar: f64) -> f64 {
    return 1800 - min(ar, 5) * 120 - (max(ar, 5) - 5) * 150
}


osu_on_update :: proc(dt: f64) {
    
    game.play_timer_ms += dt * 1000
    if game.play_timer_ms > game.active_map.length_ms {
        game.play_timer_ms = -game.active_map.audio_lead_in
    }


}
