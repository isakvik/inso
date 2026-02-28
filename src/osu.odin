
package notosu
import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import "base:intrinsics"
import "base:runtime"
import "core:math/linalg"
import q "core:container/queue"

import sdl "vendor:sdl3"


playfield_size_osupx :: f32(512)
playfield_rect :: Rect{ 0, 0, playfield_size_osupx, playfield_size_osupx }

osu_slider_curve_points_separation :: f32(2.5)

// note(isak): state struct. keep it lean, put large data fields in arenas and point to it here
game: struct {
    dt: f64, 
    active_mapset: ^Mapset,
    active_notosu_map: ^Notosu_Map,
    active_map: ^Osu_Map,
    active_skin: [Skin_Element_Type]Skin_Element,
    
    mode: Game_Mode,
    
    // note(isak): map game logic fields
    
    beatmap: Beatmap,
    
    paused: bool,
    time_rate: f32,
    
    // note(isak): map game view fields
    
    ui_timeline: UI_Timeline,
    
    input: struct {
        k1, k2, m1, m2: Button_State,
        k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu
        
        mouse_keys_enabled: bool,
        mouse_pos: vec2,
    }
}

// note(isak): we reserve the first slot for safety reasons, and we crash on modification for debug reasons
@(rodata) null_drawable := Drawable{}
@(rodata) null_element := Element{}

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
    index: int,
    type: Hit_Object_Type,
    start_time_ms, end_time_ms: f64,
    pos, script_pos_translation: vec2,
    
    type_flags: int,
    hitsound_flags: byte,

    slider_path_index: int,
    slider_repeats, slider_repeat_at: int,
    
    gfx_handles: []Drawable_Handle,
}

hit_object_pos :: proc(hobj: ^Hit_Object) -> vec2 {
    return hobj.pos + hobj.script_pos_translation
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

Judgement :: enum {
    NONE,
    
    MISS,
    BAD,
    GOOD,
    GREAT,
    
    SLIDER_SMALL_SCOREPOINT, // 10
    SLIDER_LARGE_SCOREPOINT, // 30
    
    IGNORED_HIT, // note(isak): used when we need a result that doesn't affect score 
    COMBO_BREAK, // note(isak): intended for scripted misses
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
    
    audio_filepath: string,
    hit_objects: []Hit_Object,
    slider_paths: []Slider_Path,
}

osu_on_init :: proc() {
    game.time_rate = 1.0
    game.mode = .PLAY
    
    ui_init_timeline(&game.ui_timeline)
    
    game.input.k1_key = sdl.Scancode.Z
    game.input.k2_key = sdl.Scancode.X

    beatmap_on_init(&game.beatmap)
}


osu_on_update :: proc(dt: f64) {
    game.dt = dt

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        beatmap_reload(&game.beatmap)
    } else if updated_systems[.SCRIPTS] {
        lua_reload(game.active_notosu_map.lua_entry_point)
        lua_call_beatmap_func("on_init")
    }
    
    // note(isak): game logic - map
    
    beatmap_on_update(&game.beatmap)
    
    // todo(isak): this really handles a bunch of debug stuff too. fix up the modes and such
    #partial switch game.mode {
        case .PLAY: handle_play_input_events()
    }
    
    map_time := game.beatmap.music_time_ms
    hobj_it := get_visible_hobj_iterator(&game.beatmap.visible_hit_object_state, map_time)
    
    playfield_transform := transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    //-- @temp
    // todo(isak): valid key presses system needs testing
    if valid_key_press() {
        for &hobj, i in hobj_it {
            if len(hobj.gfx_handles) == 2 {
                continue
            }
            
            hobj_pos := hit_object_pos(&hobj)
            if !point_in_circle(game.input.mouse_pos, hobj_pos, game.beatmap.circle_radius_osupx) {
                continue
            }
            
            clear_hitobject_drawables(&hobj)
            
            hobj.gfx_handles = reserve_handles(&game.beatmap.persistent_gfx, 2) or_continue
            
            hobj.gfx_handles[0] = drawable_new({
                flags = {.ACTIVE},
                element = builtin_element_slot(.CLICKED_HIT_CIRCLE_OVERLAY),
                layer = .HIT_OBJECTS,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_white,
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
            hobj.gfx_handles[1] = drawable_new({
                flags = {.ACTIVE},
                element = builtin_element_slot(.CLICKED_HIT_CIRCLE),
                layer = .HIT_OBJECTS,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_purple,
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
            
            drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
                flags = {.ACTIVE},
                element = builtin_element_slot(.JUDGEMENT),
                layer = .HIT_OBJECTS,
                pos = hobj_pos,
                size = [2]f32{0.5, 1} * game.beatmap.circle_radius_osupx,
                anchor = .CENTER,
                color = color_sky_blue,
                
                angle_vel = 360.0,
                
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
        } 
    }
    //--
    
    
    if lua_cares_about_event(.ON_KEY_DOWN) {
        for code in sdl.Scancode {
            if is_key_pressed(code) do lua_beatmap_on_key_pressed(code)
        }
    }
    if lua_cares_about_event(.ON_KEY_UP) {
        for code in sdl.Scancode {
            if is_key_released(code) do lua_beatmap_on_key_released(code)
        }
    }
    if lua_cares_about_event(.ON_CONTROLLER_PRESSED) {
        if is_pressed(game.input.k1) do lua_beatmap_on_controller_pressed("k1")
        if is_pressed(game.input.k2) do lua_beatmap_on_controller_pressed("k2")
        if is_pressed(game.input.m1) do lua_beatmap_on_controller_pressed("m1")
        if is_pressed(game.input.m2) do lua_beatmap_on_controller_pressed("m2")
    }
    if lua_cares_about_event(.ON_CONTROLLER_RELEASED) {
        if is_released(game.input.k1) do lua_beatmap_on_controller_released("k1")
        if is_released(game.input.k2) do lua_beatmap_on_controller_released("k2")
        if is_released(game.input.m1) do lua_beatmap_on_controller_released("m1")
        if is_released(game.input.m2) do lua_beatmap_on_controller_released("m2")
    }
    
    
    // beatmap render
    
    r_bind_layer_and_push_current_state(.HIT_OBJECTS)
    
    //-- @temp
    // todo(isak): for the eventual rewrite here that takes object type into account, consider a
    // function pointer in the hitobject struct that renders (and maybe one that updates? continual
    // logic is necessary for sliders... hitting circles is a keyboard event kind of thing)
    for &hobj in hobj_it {
        if map_time < hobj.start_time_ms - game.beatmap.preempt_ms || hobj.end_time_ms < map_time {
            continue
        }
        if hobj.type == .SLIDER {
            render_slider(&window.renderer, &hobj)
        }
    }
    //--
    
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(playfield_transform)

    // note(isak): we render hitobject elements back to front for correct blending
    // todo(isak): @speed - use persistent_gfx for visible set optimization
    #reverse for &hobj in game.beatmap.hit_objects {
        #reverse for handle in hobj.gfx_handles {
            e := slotmap.get(&game.beatmap.drawables, handle) or_continue
            if .ACTIVE in e.flags {
                render_drawable(e, map_time, hit_object_pos(&hobj))
            }
        }
    }
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.gameplay_expiring_gfx)
    
    r_bind_layer_and_push_current_state(.BACKGROUND, transform = playfield_transform)
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.map_expiring_gfx)
    
    // ui render
    
    // todo(isak): "screens" implementation for determining relevant UI components?
    handle_and_render_timeline()
    render_input_display()
}

// note(isak): this function assumes the start times of objects are sorted, but doesn't require end times to be.
// a pathological case might be a 2B element that stretches from the beginning of the map to the end
// todo(isak): latest object state is not implemented
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
        game.input.mouse_keys_enabled = !game.input.mouse_keys_enabled
    }
    
    game.input.k1.is_down = keyboard.buttons[game.input.k1_key]
    game.input.k1.was_down = keyboard.buttons_prev_frame[game.input.k1_key]
    game.input.k2.is_down = keyboard.buttons[game.input.k2_key]
    game.input.k2.was_down = keyboard.buttons_prev_frame[game.input.k2_key]
    game.input.m1 = mouse.buttons[.LEFT]
    game.input.m2 = mouse.buttons[.RIGHT]
}

valid_key_press :: proc() -> bool {
    if game.input.mouse_keys_enabled {
        if is_pressed(game.input.k1) && !is_down(game.input.m1) ||
            is_pressed(game.input.k2) && !is_down(game.input.m2) {
            return true
        }
        
        return is_pressed(game.input.m1) && !is_down(game.input.k1) || 
            is_pressed(game.input.m2) && !is_down(game.input.k2)
    } else {
        return is_pressed(game.input.k1) || is_pressed(game.input.k2)
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

is_down :: proc "c" (button: Button_State) -> bool {
    return button.is_down
}

is_pressed :: proc "c" (button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

is_released :: proc "c" (button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

is_key_down :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code]
}

is_key_pressed :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code] && !keyboard.buttons_prev_frame[code]
}

is_key_released :: proc "c" (code: sdl.Scancode) -> bool {
    return !keyboard.buttons[code] && keyboard.buttons_prev_frame[code]
}
