package notosu

import "rb"

import "core:sort"
import "base:intrinsics"
import "base:runtime"
import "core:math/linalg"
import q "core:container/queue"

import sdl "vendor:sdl3"


osu_playfield_size_osupx :: 512
playfield_rect :: Rect{ 0, 0, osu_playfield_size_osupx, osu_playfield_size_osupx }

// note(isak): state struct. keep it lean, put large data fields in arenas

game: struct {
    mode: Game_Mode,
    play_timer_ms: f64,
    play_paused: bool,
    time_rate: f64,

    active_mapset: ^Mapset,
    active_map: ^Osu_Map,
    active_skin: [Skin_Element_Type]Skin_Element,
    
    elements: rb.Ring_Buffer(Element),
    last_added_element: uint,
    visible_element_state: Visibility_State,

    animations: q.Queue(Animation),
    bound_element_animations: [Element_Type][]Animation,
}

// note(isak): core types

Visibility_State :: struct {
    earliest_i, latest_i: int,
}

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
    first_element_at, num_elements: int,
    
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
    visible_hit_object_state: Visibility_State,

    slider_paths: []Slider_Path,
    length_ms: f64,
    total_lead_in_ms: f64,

    preempt_ms: f64,
    circle_radius_osupx: f32,
}

/*
    game todos(isak)

    
*/

osu_on_init :: proc() {
    game.time_rate = 1.0
    game.play_timer_ms = -500
    game.mode = .PLAY
    
    osu_controller.k1_key = sdl.Scancode.Z
    osu_controller.k2_key = sdl.Scancode.X

    osu_on_map_load()
}

osu_on_map_load :: proc() {
    q.init(&game.animations, 1024, memory.mapset_allocator)
    write_default_animations(&game.animations, game.active_map)

    rb.init(&game.elements, 8192, memory.element_allocator)
    game.elements.length = cap(game.elements.data)
    write_default_elements_from_map(&game.elements, game.active_map)
}

osu_on_map_unload :: proc() {
    for &e in game.elements.data {
        e.flags &= ~{.ACTIVE}
    }
}

osu_restart_map :: proc(osu_map: ^Osu_Map) {
    game.mode = .PLAY
    game.play_timer_ms = clamp(-game.active_map.total_lead_in_ms, -1000, 0)
    
    osu_map.visible_hit_object_state = {}
    game.visible_element_state = {}
    
    osu_on_map_unload()
    write_default_elements_from_map(&game.elements, game.active_map)
}

osu_on_update :: proc(dt: f64) {
    dt := dt * game.time_rate * (game.play_paused ? 0 : 1)

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        game.active_mapset = mapset_clear_and_reload(game.active_mapset)
        game.active_map = &game.active_mapset.osu_map
        osu_on_map_load()
    }
    
    game.play_timer_ms += dt * 1000
    game.active_map.total_lead_in_ms = game.active_map.preempt_ms + game.active_map.audio_lead_in
    if game.play_timer_ms > game.active_map.length_ms {
        osu_restart_map(game.active_map)
    }

    time := game.play_timer_ms
    hobj_it := get_visible_hobj_iterator(&game.active_map.visible_hit_object_state, game.play_timer_ms)
    for hobj, i in hobj_it {      
        if time < hobj.start_time_ms - game.active_map.preempt_ms || hobj.end_time_ms < time {
            continue
        }
        if hobj.type == .SLIDER {
            render_slider(&window.renderer, &game.active_map.slider_paths[hobj.slider_path_index])
        }
    }

    if is_pressed(osu_controller.k1) {
        debug_simulate_press = true
    }

    if debug_simulate_press {
        for &hobj, i in hobj_it {
            if hobj.num_elements == 1 {
                continue
            }
            clear_hitobject_elements(&game.elements, hobj)
            hobj.first_element_at, hobj.num_elements = reserve_elements(&game.elements, 1)

            push_element(&game.elements, Element{
                flags = {.ACTIVE},
                type = .JUDGMENT,
                pos = hobj.pos,
                size = game.active_map.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_white,
                start_time_ms = time,
                end_time_ms = time + 600
            })
        }
        debug_simulate_press = false
    }

    r_push_transform(transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio))

    // note(isak): we render elements back to front for correct blending
    #reverse for &hobj in game.active_map.hit_objects {
        t := time

        for i in 0..<hobj.num_elements {
            e := &game.elements.data[hobj.first_element_at + i %% cap(game.elements.data)]
            render_element(e, t)
        }
    }

    render_timeline(&window.renderer)
}

debug_simulate_press: bool


// note(isak): this function assumes the start times of objects are sorted, but doesn't require end times to be.
// a pathological case might be a 2B element that stretches from the beginning of the map to the end
// todo(isak): it doesn't read from the latest object state; it's a viable small optimization
get_visible_hobj_iterator :: proc(state: ^Visibility_State, time: f64) -> []Hit_Object {
    result: []Hit_Object
    updated_from_index := state.earliest_i

    hit_objects := game.active_map.hit_objects
    if len(hit_objects) > 0 {
        looking_for_finished_objects := true
        count_until_next_unstarted_hobj: int
        includes_final_index := 1

        for hobj, i in hit_objects[state.earliest_i:] {
            count_until_next_unstarted_hobj = i
            if time < hobj.start_time_ms - game.active_map.preempt_ms {
                includes_final_index = 0
                break
            }
            if looking_for_finished_objects {
                if hobj.end_time_ms < time {
                    updated_from_index += 1
                } else {
                    looking_for_finished_objects = false
                }
            }
        }
        state.latest_i = updated_from_index + count_until_next_unstarted_hobj + includes_final_index
        state.earliest_i = updated_from_index
        result = hit_objects[state.earliest_i:min(state.latest_i, len(hit_objects))]
    }
    return result
}


osu_slider_curve_points_separation :: f32(2.5)

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
    given path. it should write instances into the bounds of [0, playfield_size]
*/
write_instances_from_path :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, alloc: runtime.Allocator = context.allocator
) -> (i32, i32) {
    instance_offset := instance_buf.count

    // todo(isak): test code that just pushes a point for each node
    path.curves = split_path_into_curves(path, alloc)
    for curve in path.curves {
        buffer_push(instance_buf, curve[0])
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


check_game_input :: proc(event: sdl.Event) {
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
