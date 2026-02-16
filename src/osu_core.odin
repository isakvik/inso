package notosu

import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import "base:intrinsics"
import "base:runtime"
import "core:math/linalg"
import q "core:container/queue"

import sdl "vendor:sdl3"


osu_playfield_size_osupx :: f32(512)
playfield_rect :: Rect{ 0, 0, osu_playfield_size_osupx, osu_playfield_size_osupx }

osu_slider_curve_points_separation :: f32(2.5)

// note(isak): state struct. keep it lean, put large data fields in arenas

game: struct {
    dt: f64, 
    active_mapset: ^Mapset,
    active_map: ^Osu_Map,
    active_skin: [Skin_Element_Type]Skin_Element,
    
    mode: Game_Mode,
    
    // note(isak): map game logic fields
    
    beatmap: Beatmap,
    
    paused: bool,
    time_rate: f32,
    
    // note(isak): map game view fields

    gfx_handles: rb.Ring_Buffer(slotmap.Handle),
    temp_gfx_refs: sb.Swap_Buffer(slotmap.Handle),
    map_gfx_refs: q.Queue(slotmap.Handle),
    
    entities: slotmap.Slotmap(Entity),
    next_entity_id: int, // note(isak): rolling entity id sequence
    
    /*
        note(isak): entities refer to an element, which in turn refer to a set of animations that determine 
        the final transform. the given element of an entity can be overridden mid-map by scripts for effects
    */
    elements: q.Queue(Element),
    animations: q.Queue(Animation),
    
    script_gfx_objects: q.Queue(Graphics_Object),

    ui_timeline: UI_Timeline,
}

null_entity := Entity{}
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
    
    type_flags: int,
    hitsound_flags: byte,

    slider_path_index: int,
    slider_repeats: int,
    
    gfx_handles: []slotmap.Handle,
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
    slider_paths: []Slider_Path,
}

osu_on_init :: proc() {
    game.next_entity_id = 1
    game.time_rate = 1.0
    game.mode = .PLAY
    
    ui_init_timeline(&game.ui_timeline)
    
    osu_controller.k1_key = sdl.Scancode.Z
    osu_controller.k2_key = sdl.Scancode.X

    beatmap_on_init(&game.beatmap)
}


osu_on_update :: proc(dt: f64) {
    game.dt = dt

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        beatmap_reload(&game.beatmap)
    }
    
    // note(isak): game logic - map
    
    if sound_is_finished(&game.beatmap.music) {
        beatmap_reload(&game.beatmap)
        sound_set_position_ms(&game.beatmap.music, 0)
    }
    
    beatmap_on_update(&game.beatmap)

    map_time: f64
    if game.beatmap.music_time_ms < 0 {
        game.beatmap.music_time_ms += game.dt * f64(game.paused ? 0 : game.time_rate)
        map_time = game.beatmap.music_time_ms
        
        if game.beatmap.music_time_ms >= 0 {
            sound_resume(&game.beatmap.music)
            sound_set_position_ms(&game.beatmap.music, 0)
            
            map_time = beatmap_music_position_interpolated_ms(&game.beatmap)
            game.beatmap.music_time_ms = map_time
        }
    } else {
        // note(isak): map play time is determined by the sound library (and whether we were able to play music or not), 
        // but song time interpolation is required because BASS reports play position in buffer size granularity
        map_time = beatmap_music_position_interpolated_ms(&game.beatmap)
        game.beatmap.music_time_ms = map_time
    }
    
    #partial switch game.mode {
        case .PLAY: handle_play_input_events()
    }
    
    hobj_it := get_visible_hobj_iterator(&game.beatmap.visible_hit_object_state, game.beatmap.music_time_ms)
    
    playfield_transform := transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    if valid_key_press() {
        for &hobj, i in hobj_it {
            if len(hobj.gfx_handles) == 2 {
                continue
            }
            
            if !point_in_circle(osu_controller.mouse_pos, hobj.pos, game.beatmap.circle_radius_osupx) {
                continue
            }
            
            clear_hitobject_entities(&hobj)
            
            hobj.gfx_handles = reserve_handles(&game.gfx_handles, 2) or_continue
            
            hobj.gfx_handles[0] = push_entity({
                flags = {.ACTIVE},
                element = element_id(.CLICKED_HIT_CIRCLE_OVERLAY),
                layer = .HIT_OBJECTS,
                pos = hobj.pos,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_white,
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
            hobj.gfx_handles[1] = push_entity({
                flags = {.ACTIVE},
                element = element_id(.CLICKED_HIT_CIRCLE),
                layer = .HIT_OBJECTS,
                pos = hobj.pos,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_purple,
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
            
            push_entity_temp({
                flags = {.ACTIVE},
                element = element_id(.JUDGMENT),
                layer = .HIT_OBJECTS,
                pos = hobj.pos,
                size = [2]f32{0.5, 1} * game.beatmap.circle_radius_osupx,
                anchor = .CENTER,
                color = color_sky_blue,
                
                angle_vel = 360.0,
                
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
        }
    }
    
    // game render
    
    r_bind_layer_and_push_current_state(.HIT_OBJECTS)
    
    for hobj, i in hobj_it {
        if map_time < hobj.start_time_ms - game.beatmap.preempt_ms || hobj.end_time_ms < map_time {
            continue
        }
        if hobj.type == .SLIDER {
            render_slider(&window.renderer, &game.beatmap.slider_paths[hobj.slider_path_index])
        }
    }
    
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(playfield_transform)

    // note(isak): we render hitobject elements back to front for correct blending
    // todo(isak): @speed - long iteration, but seems necessary to not cull gfx objects outside an 
    // object's given start/end time window
    #reverse for &hobj in game.beatmap.hit_objects {
        #reverse for handle in hobj.gfx_handles {
            e := slotmap.get(&game.entities, handle) or_continue
            if .ACTIVE in e.flags {
                render_entity(e, map_time)
            }
        }
    }
    
    process_and_draw_temp_gfx_handles()
    r_bind_layer_and_push_current_state(.BACKGROUND, transform = playfield_transform)
    
    for handle in game.beatmap.map_gfx_refs {
        e := slotmap.get(&game.entities, handle) or_continue
        if .ACTIVE in e.flags {
            render_entity(e, map_time)
        }
    }
    
    // render ui
    // todo(isak): "screens" implementation for determining relevant UI components?
    handle_and_render_timeline()
    render_input_display()
}

// note(isak): this function assumes the start times of objects are sorted, but doesn't require end times to be.
// a pathological case might be a 2B element that stretches from the beginning of the map to the end
// todo(isak): it doesn't read from the latest object state; it's a viable small optimization
get_visible_hobj_iterator :: proc(state: ^Visibility_State, time: f64) -> []Hit_Object {
    result: []Hit_Object
    updated_from_index := state.earliest_i

    hit_objects := game.beatmap.hit_objects
    if len(hit_objects) > 0 {
        looking_for_finished_objects := true
        count_until_next_unstarted_hobj: int
        includes_final_index := 1

        for hobj, i in hit_objects[state.earliest_i:] {
            count_until_next_unstarted_hobj = i
            if time < hobj.start_time_ms - game.beatmap.preempt_ms {
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

handle_play_input_events :: proc() {
    if is_key_pressed(.ESCAPE) || is_key_pressed(.SPACE) {
        beatmap_pause(&game.beatmap, !game.paused)
    }
    if is_key_pressed(.R) {
        beatmap_reload(&game.beatmap)
    }
    if is_key_pressed(.HOME) {
        game.time_rate = 1
    }
    if is_key_pressed(.PAGEUP) {
        game.time_rate *= 2
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    if is_key_pressed(.PAGEDOWN) {
        game.time_rate /= 2
        sound_set_speed(&game.beatmap.music, game.time_rate)
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

// todo(isak): game logic. needs testing
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


split_path_into_curves :: proc(path: ^Slider_Path, alloc: runtime.Allocator) -> []Slider_Curve {
    // todo(isak): we just make a curve for each node here for testing, but we have to read nodes to figure out 
    // which ones are red nodes and split by those
    result := make_slice([]Slider_Curve, len(path.nodes))
    for i in 0..<len(path.nodes) {
        result[i] = path.nodes[i:i+1]
    }
    return result
}

write_instances_from_curve :: proc(
    instance_buf: ^Buffer(vec2), curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64
) -> f64 {
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
