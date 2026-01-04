package notosu

import "base:runtime"
import "core:math/linalg"
import queue "core:container/queue"
import sa "core:container/small_array"

import sdl "vendor:sdl3"


osu_playfield_size_osupx :: 512
playfield_rect :: Rect{ 0, 0, osu_playfield_size_osupx, osu_playfield_size_osupx }

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
    using Osu_File_Data: struct {
        audio_filename: string,
        audio_lead_in: f64,
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
    },

    // map 

    hit_objects: []Hit_Object,
    slider_paths: []Slider_Path,
    length_ms: f64,
    lead_in: f64,

    play_timer_ms: f64,
}

game: struct {
    mode: Game_Mode,

    active_mapset: ^Mapset,
    active_map: ^Osu_Map,
    
    test_nodes: sa.Small_Array(128, Slider_Node),
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
    first_instance_at: int,
}


Difficulty_Setting :: struct {
    circle_size_osupx: f32
}


Layer :: enum {
    BACKGROUND,
    FOREGROUND,
    OVERLAY,
    UI,
    DEBUG
}

osu_slider_curve_points_separation: f32 = 2.5

Slider_Curve :: []Slider_Node

test_slider: Slider_Path
test_slider2: Slider_Path

test_curve: Slider_Curve

// todo(isak): move this to arena and to osu_map as slider_count (offset in parsing function)
map_sliders: [128]Slider_Path
slider_offset: int


osu_on_init :: proc() {
    osu_on_map_init()
}

osu_on_map_init :: proc() {
    make_test_slider(&test_slider, 0)
    make_test_slider(&test_slider2, 1)

    make_test_instances(&test_slider)
    write_instances_from_path(&window.renderer.slider_instances, &test_slider, memory.mapset_allocator)
    
    preempt: f64 = convert_approach_rate_to_preempt(game.active_map.diff_approach_rate)
    
    active_map := game.active_map

    final_hobj_time_ms: f64
    for &hobj in game.active_map.hit_objects {
        hobj.start_time_ms -= preempt
        final_hobj_time_ms = max(final_hobj_time_ms, hobj.end_time_ms)
    }

    active_map.lead_in = preempt + active_map.audio_lead_in
    active_map.length_ms = final_hobj_time_ms + 1000
    active_map.play_timer_ms = -active_map.lead_in
}

osu_on_update :: proc(dt: f64) {
    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        game.active_mapset = mapset_clear_and_reload(game.active_mapset)
        game.active_map = &game.active_mapset.osu_map
        osu_on_map_init()
    }
    
    active_map := game.active_map
    
    active_map.play_timer_ms += dt * 1000
    if active_map.play_timer_ms > active_map.length_ms {
        active_map.play_timer_ms = -active_map.lead_in
    }

    render_timeline()

    // todo(isak): create some kinda iterator for this; keep track of earliest active object and 
    // stop once first nonstarted obj is done
    r_push_transform(transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio))
    for &hit_object in game.active_map.hit_objects {
        render_hit_object(&window.renderer, &hit_object)
    }
}

check_game_input :: proc(event: sdl.Event) {
    //osu_controller.k1_key = sdl.Scancode.Z
    //osu_controller.k2_key = sdl.Scancode.X

    if (event.type == sdl.EventType.KEY_DOWN) { //TODO(yokes): make this code shorter
        if (event.key.scancode == osu_controller.k1_key) {
            osu_controller.k1.is_down = true
        }
        if (event.key.scancode == osu_controller.k2_key) {
            osu_controller.k2.is_down = true
        }
    }
    if (event.type == sdl.EventType.KEY_UP) {
        if (event.key.scancode == osu_controller.k1_key) {
            osu_controller.k1.is_down = false
        }
        if (event.key.scancode == osu_controller.k2_key) {
            osu_controller.k2.is_down = false
        }
    }
    if (event.type == sdl.EventType.MOUSE_BUTTON_DOWN) {
        if (event.button.button == sdl.BUTTON_LEFT) {
            osu_controller.m1.is_down = true
        }
        if (event.button.button == sdl.BUTTON_RIGHT) {
            osu_controller.m2.is_down = true
        }
    }
    if (event.type == sdl.EventType.MOUSE_BUTTON_UP) {
        if (event.button.button == sdl.BUTTON_LEFT) {
            osu_controller.m1.is_down = false
        }
        if (event.button.button == sdl.BUTTON_RIGHT) {
            osu_controller.m2.is_down = false
        }
    }
}

//NOTE(yokes): API for in-game button input

is_held :: proc(button: Button_State) -> bool {
    return button.is_down
}

is_pressed :: proc(button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

is_released :: proc(button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

split_path_into_curves :: proc(path: ^Slider_Path, alloc: runtime.Allocator) -> []Slider_Curve {
    return nil
}

write_instances_from_curve :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64) -> f64 {
    return curve_distance
}

// todo(isak): caller needs to populate path with num instances written, plus instance offset.
// maybe not the best api?
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

    // todo(yokes): if we still have distance left over but zero curves, a linear path needs to cover
    // the remaining distance. maybe mcosu has something neat for this?
    if distance_to_cover > 0 {

    }
}

// todo(isak): temp to be calculated from osu map cs
circle_radius_osupx: f32 = 40

make_test_slider :: proc(slider: ^Slider_Path, x_shift: f32) {
    node_i := game.test_nodes.len

    sa.append(&game.test_nodes, Slider_Node{0/circle_radius_osupx, 0/circle_radius_osupx})
    sa.append(&game.test_nodes, Slider_Node{100/circle_radius_osupx, 0/circle_radius_osupx})
    sa.append(&game.test_nodes, Slider_Node{100/circle_radius_osupx, 100/circle_radius_osupx})
    sa.append(&game.test_nodes, Slider_Node{200/circle_radius_osupx, 100/circle_radius_osupx})

    slider^ = {
        pos = {0 + x_shift, 0},
        nodes = game.test_nodes.data[node_i + 0:node_i + 4],
        distance_osupx = 999,

        first_instance_at = int(window.renderer.slider_instances.count)
    }
    
    instance_buf := &window.renderer.slider_instances
    write_instances_from_path(instance_buf, slider, memory.mapset_allocator)
    
    num_instances_written := int(window.renderer.slider_instances.count)
    slider.instances = 
        window.renderer.slider_instances.data[slider.first_instance_at:num_instances_written]
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


render_hit_object :: proc(renderer: ^Renderer, hobj: ^Hit_Object) {
    using game

    if active_map.play_timer_ms < hobj.start_time_ms {
        return
    }

    #partial switch hobj.type {
        case .CIRCLE: {
            if hobj.start_time_ms < active_map.play_timer_ms && active_map.play_timer_ms < hobj.end_time_ms {
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
    // todo(isak):  generate partial instance draws (snaking) and the bounding quads like the smart cookie you are

    r_bind_pipeline({.SLIDER})
    r_bind_framebuffer({ write = .SLIDERS })    
    r_bind_ssbo(&window.circle_geo_buffer, .VERTEX_BUFFER)
    r_clear()

    pf_size: f32 = 512/circle_radius_osupx

    r_push_transform(transform_from_bounds({0,0,pf_size,pf_size}, window.aspect_ratio))

    command_push_draw_slider(Command_Draw_Slider{
        base_instance = u32(slider.first_instance_at),
        instance_count = i32(len(slider.instances))
    })
    
    r_bind_framebuffer({ read = .SLIDERS })
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_bind_pipeline({.QUAD})
    
    r_push_transform(transform_from_bounds({0, 0, 1, 1}, 1))
    push_rect(&renderer.quad_geometry, {0, 0, 1, 1}, {1, 1, 1, 0.5}, reserved_texture(.SLIDER_FRAMEBUFFER))
}

render_timeline :: proc() {
    active_map := game.active_map
    preempt := convert_approach_rate_to_preempt(active_map.diff_overall_difficulty)
    map_len_with_preempt := active_map.length_ms + preempt

    active_map_leadin_fract := f32(max(0, -active_map.play_timer_ms - preempt) / (active_map.lead_in - preempt))
    active_map_finish_fract := f32((active_map.play_timer_ms + active_map.lead_in) / map_len_with_preempt)
    
    r_push_transform(window_get_clipspace_transform())
    
    timeline_h_px := 4 / window.rect.h
    push_layout_rect(&window.renderer.quad_geometry, {0, 1, 1, timeline_h_px}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.1))
    push_layout_rect(&window.renderer.quad_geometry, {0, 1, active_map_finish_fract, timeline_h_px}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.4))
    if active_map_leadin_fract > 0 {
        push_layout_rect(&window.renderer.quad_geometry, {0, 1, active_map_leadin_fract, timeline_h_px}, 
                         .BOTTOM_LEFT, with_alpha(color_lime_green, 0.2))
    }
}

render_input_display :: proc(geometry: ^Buffer(Quad)) {
    render_input_key :: proc(key: Button_State, rect: Rect, anchor: Layout_Anchor, color: vec4, tex_index: u32 = 0) {
        if is_pressed(key) {
            push_layout_rect(&window.renderer.quad_geometry, rect, anchor, color, tex_index)
        } else if is_held(key) {
            push_layout_rect(&window.renderer.quad_geometry, rect, anchor, color, tex_index)
        } else if is_released(key) {
            push_layout_rect(&window.renderer.quad_geometry, rect, anchor, {0.2,0.2,0.2,1}, tex_index)
        } else {
            push_layout_rect(&window.renderer.quad_geometry, rect, anchor, {0.2,0.2,0.2,1}, tex_index)
        }
    }

    render_input_key(osu_controller.k1, { window.rect.w, window.rect.h / 2 - 30, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
    render_input_key(osu_controller.k2, { window.rect.w, window.rect.h / 2,      30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
    render_input_key(osu_controller.m1, { window.rect.w, window.rect.h / 2 + 30, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
    render_input_key(osu_controller.m2, { window.rect.w, window.rect.h / 2 + 60, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
}

convert_approach_rate_to_preempt :: proc(ar: f64) -> f64 {
    return 1800 - min(ar, 5) * 120 - (max(ar, 5) - 5) * 150
}

