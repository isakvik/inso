package notosu

import "core:slice"
import "core:mem/virtual"
import "base:runtime"
import "core:math/linalg"
import queue "core:container/queue"
import sa "core:container/small_array"

import sdl "vendor:sdl3"


osu_playfield_size_osupx :: 512
playfield_rect :: Rect{ 0, 0, osu_playfield_size_osupx, osu_playfield_size_osupx }

// note(isak): state struct. keep it lean, put large data fields in arenas

game: struct {
    mode: Game_Mode,
    play_timer_ms: f64,
    time_rate: f64,

    active_mapset: ^Mapset,
    active_map: ^Osu_Map,
    active_skin: [Skin_Element_Type]Skin_Element,
    
    animations: queue.Queue(Animation),
    elements: queue.Queue(Element),
    bound_element_animations: [Element_Type][]Animation
}

// note(isak): core types

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

    slider_path_index: int,
    slider_repeats: int,
}

Slider_Path_Type :: enum {
    NONE,
    LINEAR,
    BEZIER,
    ARC,
    CATMULL,
}

Slider_Node :: vec2
Slider_Curve :: []Slider_Node

Slider_Path :: struct {
    pos: vec2,
    type: Slider_Path_Type,
    distance_osupx: f64,

    nodes: []Slider_Node, // note(isak): slice into our array of all nodes
    curves: []Slider_Curve, // note(isak): slice into mapset arena
    
    instance_count, first_instance_at: i32, // todo(isak): this could be a slice, but data reads are probs unnecessary...
}


Game_Mode :: enum {
    UNINITIALIZED,
    MENU,
    PLAY,
}

Layer :: enum {
    BACKGROUND,
    FOREGROUND,
    OVERLAY,
    UI,
    DEBUG
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
    total_lead_in_ms: f64,

    preempt_ms: f64,
    circle_radius_osupx: f32,
}


osu_slider_curve_points_separation: f32 = 2.5


test_slider: Slider_Path
test_slider2: Slider_Path

test_curve: Slider_Curve

// todo(isak): move this to arena and to osu_map as slider_count (offset in parsing function)
map_sliders: [128]Slider_Path
slider_offset: int

/*
    game todos(isak)

    element storage...
        should elements use some kinda ring buffer? if there's a memory budget we should stick to....

        a lot of elements can be calculated at load time, but scripts will add stuff at runtime
        a lot of these runtime els will probably run for a short duration, they can be marked inactive and
        slots reused... yeah a runtime ring buffer with alive/dead flags will work.
        queue is good, can alloc a finite big amount and just not grow it but rather loop through and find new slots.
        priority system might be prudent (gameplay elements always pushes over visual elements if there are no
        open slots.)
*/

osu_on_init :: proc() {
    game.time_rate = 1.0
    game.play_timer_ms = -500

    osu_on_map_init()
}

osu_on_map_init :: proc() {
    queue.init(&game.animations, 1024, memory.mapset_allocator)
    queue.init(&game.elements, 8192, memory.element_allocator)

    //make_test_slider(&test_slider, 0)
    //make_test_instances(&test_slider)
    //write_instances_from_path(&window.renderer.slider_instances, &test_slider, memory.mapset_allocator)
    
    write_default_animations(&game.animations, game.active_map)
    write_default_elements_from_map(&game.elements, game.active_map)
}

osu_on_update :: proc(dt: f64) {
    dt := dt * game.time_rate

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        game.active_mapset = mapset_clear_and_reload(game.active_mapset)
        game.active_map = &game.active_mapset.osu_map
        osu_on_map_init()
    }
    
    game.play_timer_ms += dt * 1000
    game.active_map.total_lead_in_ms = game.active_map.preempt_ms + game.active_map.audio_lead_in
    if game.play_timer_ms > game.active_map.length_ms {
        game.play_timer_ms = clamp(-game.active_map.total_lead_in_ms, -1000, 0)
    }
    
    for hobj in game.active_map.hit_objects {
        if hobj.type != .SLIDER || 
                game.play_timer_ms < hobj.start_time_ms - game.active_map.preempt_ms || 
                hobj.end_time_ms < game.play_timer_ms {
            continue
        }

        render_slider(&window.renderer, &game.active_map.slider_paths[hobj.slider_path_index])
    }

    render_timeline(&window.renderer)

    r_push_transform(transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio))
    // todo(isak): create some kinda iterator for this; keep track of earliest active object and 
    // stop once first nonstarted obj is done
    #reverse for &e in game.elements.data[:game.elements.len] {
        render_element(&e, game.play_timer_ms - e.start_time)
    }
}

split_path_into_curves :: proc(path: ^Slider_Path, alloc: runtime.Allocator) -> []Slider_Curve {
    // todo(isak): we just make a curve for each node here for testing, but we have to read nodes to figure out 
    // which ones are red nodes and split by those
    result := make_slice([]Slider_Curve, len(path.nodes))
    for i in 0..<len(path.nodes) {
        result[i] = path.nodes[i:i+1]
    }
    return result
}

write_instances_from_curve :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64) -> f64 {
    return curve_distance
}

/*
 note(isak): calculates and writes slider instances, or positions used for rendering to the screen, based on a 
 given path. it should write instances into the bounds of [0, playfield_size / circle size]. if this proves to be
 cumbersome we could add the circle size as a size uniform to the slider shader instead (because it only has to be)
 calculated once, but right now this is the way it is.
*/
write_instances_from_path :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, circle_size: f32, alloc: runtime.Allocator = context.allocator
) -> (i32, i32) {
    instance_offset := instance_buf.count

    // todo(isak): test code that just pushes a point for each node
    path.curves = split_path_into_curves(path, alloc)
    for curve in path.curves {
        buffer_push(instance_buf, curve[0] / circle_size)
    }
    if true {
        return instance_buf.count - instance_offset, instance_offset
    }

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

    return 0, 0
}

make_test_slider :: proc(slider: ^Slider_Path, x_shift: f32) {
    circle_radius_osupx := convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    
    nodes := new([4]Slider_Node, memory.mapset_allocator)
    nodes^ = {
        Slider_Node{0/circle_radius_osupx, 0/circle_radius_osupx},
        Slider_Node{100/circle_radius_osupx, 0/circle_radius_osupx},
        Slider_Node{100/circle_radius_osupx, 100/circle_radius_osupx},
        Slider_Node{200/circle_radius_osupx, 100/circle_radius_osupx},
    }

    slider^ = {
        pos = {0 + x_shift, 0},
        nodes = slice.from_ptr(&nodes[0], len(nodes)),
        distance_osupx = 999,

        first_instance_at = window.renderer.slider_instances.count,
        instance_count = len(nodes),
    }
    
    instance_buf := &window.renderer.slider_instances
    //write_instances_from_path(instance_buf, slider, memory.mapset_allocator)
    
    //num_instances_written := int(window.renderer.slider_instances.count)
    //slider.instances = window.renderer.slider_instances.data[slider.first_instance_at:num_instances_written]
}

make_test_instances :: proc(slider: ^Slider_Path) {
    instance_buf := &window.renderer.slider_instances

    ct := instance_buf.count
    slider.first_instance_at = ct
    slider.instance_count = i32(len(slider.nodes))
    //slider.instances = instance_buf.data[ct:ct + i32(len(slider.nodes))]
    for i in 0..<len(slider.nodes) {
        buffer_push(instance_buf, slider.nodes[i])
    }
}

render_slider :: proc(renderer: ^Renderer, slider: ^Slider_Path) {
    // todo(isak): generate partial instance draws (snaking) and the bounding quads like the smart cookie you are

    r_bind_pipeline({.SLIDER})
    r_bind_framebuffer({ write = .SLIDERS })    
    r_bind_ssbo(&window.circle_geo_buffer, .VERTEX_BUFFER)
    r_clear()

    pf_size: f32 = osu_playfield_size_osupx / game.active_map.circle_radius_osupx

    r_push_transform(transform_from_bounds({0,0,pf_size,pf_size}, window.aspect_ratio))

    command_push_draw_slider(Command_Draw_Slider{
        base_instance = u32(slider.first_instance_at),
        instance_count = i32(slider.instance_count)
    })
    
    r_bind_framebuffer({ read = .SLIDERS })
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_bind_pipeline({.QUAD})
    
    r_push_transform(fullscreen_transform)
    r_draw_rect(&renderer.quad_geometry, {0, 0, 1, 1}, with_alpha(color_white, 0.4), reserved_texture(.SLIDER_FRAMEBUFFER))
}

render_timeline :: proc(renderer: ^Renderer) {
    active_map := game.active_map
    preempt := active_map.preempt_ms
    map_len_with_preempt := active_map.length_ms + preempt

    active_map_leadin_fract := f32(max(0, -game.play_timer_ms - preempt) / (active_map.total_lead_in_ms - preempt))
    active_map_finish_fract := f32((game.play_timer_ms + active_map.total_lead_in_ms) / map_len_with_preempt)
    
    r_push_transform(window_get_clipspace_transform())
    
    timeline_h_px := 4 / window.rect.h
    r_draw_layout_rect(&renderer.quad_geometry, {0, 1, 1, timeline_h_px}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.1))
    r_draw_layout_rect(&renderer.quad_geometry, {0, 1, active_map_finish_fract, timeline_h_px}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.4))
    if active_map_leadin_fract > 0 {
        r_draw_layout_rect(&renderer.quad_geometry, {0, 1, active_map_leadin_fract, timeline_h_px}, 
                         .BOTTOM_LEFT, with_alpha(color_lime_green, 0.2))
    }
}

render_input_display :: proc(geometry: ^Buffer(Quad)) {
    render_input_key :: proc(key: Button_State, rect: Rect, anchor: Layout_Anchor, color: Color, tex_index: u32 = 0) {
        if is_pressed(key) {
            r_draw_layout_rect(&window.renderer.quad_geometry, rect, anchor, color, tex_index)
        } else if is_held(key) {
            r_draw_layout_rect(&window.renderer.quad_geometry, rect, anchor, color, tex_index)
        } else if is_released(key) {
            r_draw_layout_rect(&window.renderer.quad_geometry, rect, anchor, color_dark_gray, tex_index)
        } else {
            r_draw_layout_rect(&window.renderer.quad_geometry, rect, anchor, color_dark_gray, tex_index)
        }
    }

    render_input_key(osu_controller.k1, { window.rect.w, window.rect.h / 2 - 30, 30, 30 }, .BOTTOM_RIGHT, color_light_gray)
    render_input_key(osu_controller.k2, { window.rect.w, window.rect.h / 2,      30, 30 }, .BOTTOM_RIGHT, color_light_gray)
    render_input_key(osu_controller.m1, { window.rect.w, window.rect.h / 2 + 30, 30, 30 }, .BOTTOM_RIGHT, color_light_gray)
    render_input_key(osu_controller.m2, { window.rect.w, window.rect.h / 2 + 60, 30, 30 }, .BOTTOM_RIGHT, color_light_gray)
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
