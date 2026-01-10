package notosu

import "core:math"
import "base:runtime"
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

    hit_objects: []Hit_Object,
    slider_paths: []Slider_Path,
}

game: struct {
    mode: Game_Mode,

    play_timer_ms: f64,
    active_mapset: ^Mapset
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



Slider_Path_Type :: enum {
    LINEAR,
    BEZIER,
    ARC,
}

Slider_Node :: vec2

Slider_Path :: struct {
    pos: vec2,
    type: Slider_Path_Type,
    distance_osupx: f64,

    nodes: []Slider_Node, // note(isak): slice into our array of all nodes
    curves: []Slider_Curve, // note(isak): slice into mapset arena
    
    instances: []vec2, // note(isak): slice into the gpu mapped instance buffer
    instances_loaded: bool,
    first_instance_at: int,
}


Difficulty_Setting :: struct {
    circle_size_osupx: f32
}


Layer :: enum {
    NONE,
    BACKGROUND,
    FOREGROUND,
    HIT_OBJECT,
    OVERLAY,
    UI,
    DEBUG
}

osu_slider_curve_points_separation: f32 = 2.5

Slider_Curve :: []Slider_Node

test_nodes: sa.Small_Array(128, Slider_Node)
test_slider: Slider_Path
test_slider2: Slider_Path

test_curve: Slider_Curve

// todo(isak): move this to arena and to osu_map as slider_count (offset in parsing function)
map_sliders: [128]Slider_Path
slider_offset: int

split_path_into_curves :: proc(path: ^Slider_Path, alloc: runtime.Allocator) -> []Slider_Curve {
    return nil
}

write_instances_from_curve :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64) -> f64 {
        if type == .ARC {
        is_parallel: bool

        base_dist : f32 = 2.5
        if is_parallel {
            start_pos := curve[0]
            end_pos := curve[2]
            h := (end_pos.y - start_pos.y) / (end_pos.x - start_pos.x)
            y := base_dist / (math.pow(math.pow(h, 2) + 1, 0.5))
            x := base_dist * h / (math.pow(math.pow(h, 2) + 1, 0.5))
            iterations := abs((end_pos.x - start_pos.x) / x)
            xy_vector : [2]f32 = {x, y}
            for i in 0..<iterations {
                buffer_push(slider_instances, start_pos + i * xy_vector)
            }

            travelled_distance := math.pow(math.pow(end_pos.y - start_pos.y, 2) + math.pow(end_pos.x - start_pos.x, 2), 0.5)
            buffer_push(slider_instances, start_pos + iterations * xy_vector)
            remaining_distance := curve_distance - travelled_distance
        } else {
            //todo(yokes): buffer_push points between nodes (arc)
        }
    } else if type == .LINEAR || len(curve) < 3 {
        //todo(yokes): buffer_push points between nodes (linear)
    } else {
        //todo(yokes): buffer_push points inbetween nodes (bezier)
    }

    return curve_distance
}

write_instances_from_path :: proc(instance_buf: ^Buffer(vec2), path: ^Slider_Path, alloc: runtime.Allocator) {
    path.curves = split_path_into_curves(path, alloc)

    distance_to_cover := path.distance_osupx
    for curve in path.curves {
        if distance_to_cover > 0 {
            distance_covered_by_curve := 
                write_instances_from_curve(instance_buf, 
                                           curve, 
                                           path.type,
                                           distance_to_cover)
            distance_to_cover -= distance_covered_by_curve
        }
    }
}


circle_radius_osupx: f32 = 40

make_test_slider :: proc(slider: ^Slider_Path, x_shift: f32) {
    node_i := test_nodes.len

    sa.append(&test_nodes, Slider_Node{0/circle_radius_osupx, 0/circle_radius_osupx})
    sa.append(&test_nodes, Slider_Node{100/circle_radius_osupx, 0/circle_radius_osupx})
    sa.append(&test_nodes, Slider_Node{100/circle_radius_osupx, 100/circle_radius_osupx})
    sa.append(&test_nodes, Slider_Node{200/circle_radius_osupx, 100/circle_radius_osupx})

    slider^ = {
        pos = {0 + x_shift, 0},
        nodes = test_nodes.data[node_i + 0:node_i + 4]
    }

    test_curve = slider.nodes
}

make_test_instances :: proc(slider: ^Slider_Path) {
    instance_buf := &window.renderer.slider_instances

    ct := int(instance_buf.count)
    slider.first_instance_at = ct
    slider.instances = instance_buf.data[ct:ct + len(slider.nodes)]
    for i in 0..<len(slider.nodes) {
        buffer_push(instance_buf, slider.nodes[i])
    }
}


osu_on_init :: proc() {
    mapset := game.active_mapset
    osu_map := &game.active_mapset.osu_map

    make_test_slider(&test_slider, 0)
    make_test_slider(&test_slider2, 1)

    make_test_instances(&test_slider)

    preempt: f64 = convert_approach_rate_to_preempt(osu_map.diff_approach_rate)
    
    final_hobj_time_ms: f64
    for hobj in osu_map.hit_objects {
        make_test_obj(hobj.end_time_ms, preempt, hobj.pos)

        final_hobj_time_ms = max(final_hobj_time_ms, hobj.end_time_ms)
    }

    osu_map.length_ms = final_hobj_time_ms + 500
    osu_map.audio_lead_in = preempt + 1000
    game.play_timer_ms = -osu_map.audio_lead_in
}


osu_on_update :: proc(dt: f64) {
    osu_map := &game.active_mapset.osu_map
    
    game.play_timer_ms += dt * 1000
    if game.play_timer_ms > osu_map.length_ms {
        game.play_timer_ms = -osu_map.audio_lead_in
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

render_slider :: proc(renderer: ^Renderer, slider: ^Slider_Path) {
    // todo(isak): we don't need to do the instance writing immediate mode, just do a pass on instances on mapset load
    // and generate the draws and the bounding quads like the smart cookie you are

    command_push_bind_pipeline({.SLIDER})
    command_push_bind_framebuffer({ write = .SLIDERS })
    command_push_clear()

    pf_size: f32 = 512/circle_radius_osupx

    command_push_push_transform({transform_from_bounds({0,0,pf_size,pf_size}, window.aspect_ratio)})

    command_push_draw_slider(Command_Draw_Slider{
        base_instance = u32(slider.first_instance_at),
        instance_count = i32(len(slider.instances))
    })
    
    command_push_bind_framebuffer({ read = .SLIDERS })
    command_push_bind_pipeline({.QUAD})
    
    begin_draw_with_transform(transform_from_bounds({0, 0, 1, 1}, 1))
    push_rect(&renderer.quad_geometry, {0, 0, 1, 1}, {1, 1, 1, 0.5}, reserved_texture(.SLIDER_FRAMEBUFFER))
}


convert_approach_rate_to_preempt :: proc(ar: f64) -> f64 {
    return 1800 - min(ar, 5) * 120 - (max(ar, 5) - 5) * 150
}

