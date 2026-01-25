package notosu

import "base:sanitizer"
import "rb"

import "core:fmt"
import "base:intrinsics"
import "base:runtime"
import "core:math/linalg"
import "core:mem/virtual"
import q "core:container/queue"

import sdl "vendor:sdl3"


osu_playfield_size_osupx :: f32(512)
playfield_rect :: Rect{ 0, 0, osu_playfield_size_osupx, osu_playfield_size_osupx }

osu_slider_curve_points_separation :: f32(2.5)

// note(isak): state struct. keep it lean, put large data fields in arenas

game: struct {
    // note(isak): game logic fields
    mode: Game_Mode,
    play_timer_ms: f64,
    play_paused: bool,
    time_rate: f64,
    dt: f64,

    active_mapset: ^Mapset,
    active_map: ^Osu_Map,
    active_skin: [Skin_Element_Type]Skin_Element,
    
    // note(isak): game view fields
    entities: rb.Ring_Buffer(Entity),
    last_added_entity: uint,

    /*
        note(isak): entities refer to an element, which in turn refer to a set of animations that determine 
        the final transform. the given element of an entity can be overridden mid-map by scripts for effects
    */
    elements: q.Queue(Element),    
    animations: q.Queue(Animation),

    ui_timeline: UI_Timeline,
}

null_element := Element{}

osu_controller: struct {
    k1, k2, m1, m2: Button_State,
    k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu
    
    mouse_keys_enabled: bool,
    mouse_pos: vec2,
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
    first_element_at, num_entities: int,
    
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
    
    instance_count, first_instance_at: i32, // note(isak): this could be a slice, but data reads are probs unnecessary
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
    HIT_OBJECTS,
    UI,
    DEBUG
}

Osu_Sample_Set :: enum {
    NORMAL,
    SOFT,
    DRUM
}

Notosu_Map :: struct {
    lua_entry_point: string,
    shaders: []Shader,
}

Osu_Map :: struct {
    using Osu_Map_File_Data: struct {
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
        
        bg_filename: string,
    },

    hit_objects: []Hit_Object,
    visible_hit_object_state: Visibility_State,

    slider_paths: []Slider_Path,
    length_ms: f64,
    total_lead_in_ms: f64,

    preempt_ms: f64,
    circle_radius_osupx: f32,
}

/*
    todo(isak): game todos

    hittesting
    notelock
    slider mechanics
    scripting
    music, sounds and sound sync
    

    Entity to framebuffer binding
    osu_on_resize potentially relevant for FrameElement or something fbo-related
*/

osu_on_init :: proc() {
    game.last_added_entity = 1
    game.time_rate = 1.0
    game.play_timer_ms = -500
    game.mode = .PLAY
    
    ui_init_timeline(&game.ui_timeline)
    
    osu_controller.k1_key = sdl.Scancode.Z
    osu_controller.k2_key = sdl.Scancode.X

    osu_on_map_init()
}

osu_on_map_init :: proc() {
    q.init(&game.elements, 1024, memory.mapset_allocator)
    q.append(&game.elements, null_element)
    q.init(&game.animations, 1024, memory.mapset_allocator)

    write_default_elements(&game.elements, &game.animations, game.active_map)

    rb.init(&game.entities, 8192, memory.element_allocator)
    game.entities.length = cap(game.entities.data)
    
    // todo(isak): opinionated entity pushing; needs to be rewritten to take scripting (and skin metrics)
    // and 
    // into account
    write_default_entities_from_map(&game.entities, game.active_map)
    
    test_bg_push(game.active_mapset, "kawayabughorou.jpg")
}

osu_on_map_unload :: proc() {
    // note(isak): unused
    for &e in game.entities.data {
        e.flags &= ~{.ACTIVE}
    }
}

osu_restart_map :: proc(reset_time: bool = true) {
    game.mode = .PLAY
    if reset_time {
        game.play_timer_ms = clamp(-game.active_map.total_lead_in_ms, -1800, 0)
    }
    game.active_mapset.osu_map.visible_hit_object_state = {}
    
    game.active_mapset = mapset_free_and_reload(game.active_mapset)
    game.active_map = &game.active_mapset.osu_map
    osu_on_map_init()
}


osu_on_update :: proc() {
    map_dt := game.dt * game.time_rate * (game.play_paused ? 0 : 1)

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        osu_restart_map(false)
    }
    
    game.play_timer_ms += map_dt * 1000
    game.active_map.total_lead_in_ms = game.active_map.preempt_ms + game.active_map.audio_lead_in
    if game.play_timer_ms > game.active_map.length_ms {
        osu_restart_map()
    }
    
    // game logic

    #partial switch game.mode {
        case .PLAY: osu_handle_play_input()
    }
    
    time := game.play_timer_ms
    hobj_it := get_visible_hobj_iterator(&game.active_map.visible_hit_object_state, game.play_timer_ms)

    
    valid_key_press :: proc() -> bool {
        if osu_controller.mouse_keys_enabled {
            if is_pressed(osu_controller.k1) && !is_down(osu_controller.m1) ||
                is_pressed(osu_controller.k2) && !is_down(osu_controller.m2) {
                return true
            }
            
            return is_pressed(osu_controller.m1) && !is_down(osu_controller.k1) || 
                is_pressed(osu_controller.m2) && !is_down(osu_controller.k2)
        } else {
            return is_pressed(osu_controller.k1) || is_pressed(osu_controller.k2)
        }
    }
    
    playfield_transform := transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    if valid_key_press() {
        osu_px_to_px := window.rect.h / f32(osu_playfield_size_osupx)
        circle_radius_px := game.active_map.circle_radius_osupx * osu_px_to_px
        
        for &hobj, i in hobj_it {
            if hobj.num_entities == 1 {
                continue
            }
            
            if !point_in_circle(osu_controller.mouse_pos, hobj.pos, circle_radius_px) {
                continue
            }
            
            clear_hitobject_entities(&game.entities, hobj)
            hobj.first_element_at, hobj.num_entities = reserve_entities(&game.entities, 1)
            
            entity_push(&game.entities, Entity{
                flags = {.ACTIVE},
                element = element_id(.JUDGMENT),
                pos = hobj.pos,
                size = game.active_map.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_white,
                start_time_ms = time,
                end_time_ms = time + 600
            })
        }
    }
    
    // game render
    
    r_push_layer(.HIT_OBJECTS)
    
    for hobj, i in hobj_it {
        if time < hobj.start_time_ms - game.active_map.preempt_ms || hobj.end_time_ms < time {
            continue
        }
        if hobj.type == .SLIDER {
            render_slider(&window.renderer, &game.active_map.slider_paths[hobj.slider_path_index])
        }
    }
    
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(playfield_transform)

    // note(isak): we render hitobject elements back to front for correct blending
    // todo(isak): @speed - long iteration, but seems necessary to not cull gfx objects outside an 
    // object's given start/end time window 
    #reverse for &hobj in game.active_map.hit_objects {
        for i in 0..<hobj.num_entities {
            e := rb.at(&game.entities, hobj.first_element_at + i)
            render_entity(e, time)
        }
    }
    
    // render map elements
    r_push_layer(.BACKGROUND, transform = fullscreen_transform)
    #reverse for &gfx in game.active_mapset.gfx_objects.data[:q.len(game.active_mapset.gfx_objects)] {
        for i in 0..<gfx.num_entities {
            e := rb.at(&game.entities, gfx.first_entity_at + i)
            render_entity(e, 0)
        }
    }
    
    
    // render script elements

    ui_update_timeline(&game.ui_timeline)
    render_timeline(&game.ui_timeline)
    
    render_input_display()
}

osu_handle_play_input :: proc() {
    if is_key_pressed(.ESCAPE) || is_key_pressed(.SPACE) {
        game.play_paused = !game.play_paused
    }
    if is_key_pressed(.F10) {
        osu_controller.mouse_keys_enabled = !osu_controller.mouse_keys_enabled
    }
    
    osu_controller.k1.is_down = keyboard.buttons[osu_controller.k1_key]
    osu_controller.k1.was_down = keyboard.buttons_prev_frame[osu_controller.k1_key]
    osu_controller.k2.is_down = keyboard.buttons[osu_controller.k2_key]
    osu_controller.k2.was_down = keyboard.buttons_prev_frame[osu_controller.k2_key]
    osu_controller.m1 = mouse.buttons[.LEFT]
    osu_controller.m2 = mouse.buttons[.RIGHT]
}

mapset_texture :: proc(name: string) -> u32 {
    assert(game.active_mapset != nil)
    return map_texture(game.active_mapset.texture_slot_by_name[name])
}

mapset_shader :: proc(name: string) -> u32 {
    assert(game.active_mapset != nil)
    return map_pipeline(game.active_mapset.shader_slot_by_name[name])
}

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

//////////////////////////////////////////////////////
// NOTE(yokes): in-game button input api 

is_down :: proc(button: Button_State) -> bool {
    return button.is_down
}

is_pressed :: proc(button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

is_released :: proc(button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

is_key_down :: proc(code: sdl.Scancode) -> bool {
    return keyboard.buttons[code]
}

is_key_pressed :: proc(code: sdl.Scancode) -> bool {
    return keyboard.buttons[code] && !keyboard.buttons_prev_frame[code]
}

is_key_released :: proc(code: sdl.Scancode) -> bool {
    return !keyboard.buttons[code] && keyboard.buttons_prev_frame[code]
}
