package notosu

import "core:time"
import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:container/queue"

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
    active_skin: ^Skin,
    
    mode: Game_Mode,
    
    universal_offset_ms: f64,
    
    // note(isak): map game logic fields
    
    beatmap: Beatmap,
    playfield_transform: Transform,
    
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
@(rodata) null_judgement := Judgement{}

// note(isak): core types

Visibility_State :: struct {
    earliest_i, latest_i: int,
}

Hitobject_Type :: enum u32 {
    NONE,
    CIRCLE,
    SLIDER_HEAD,
    SLIDER_PATH,
    SLIDER_TICK,
    SLIDER_REPEAT,
    SPINNER,
    // CUSTOM // note(isak) big plans?
}


Hitobject_Flags :: distinct bit_set[Hitobject_Flag; u32]
Hitobject_Flag :: enum u32 {
    VISIBLE,
    EXPIRED,
    
    NEW_COMBO,
    WHISTLE,
    FINISH,
    CLAP,
}

Hitobject :: struct {
    type: Hitobject_Type,
    flags: Hitobject_Flags,
    index: int,
    
    start_time_ms, end_time_ms: f64,
    pos, script_pos_translation: vec2,
    
    timing_point_index_uninherited: int,
    timing_point_index_inherited: int,
    hitsound_flags: byte,
    combo_color_offset: u8, // note(isak): bits 4-6 of osu type byte; how many combo colors to skip on new combo

    slider_path_index: int,
    slider_repeats, slider_repeat_at: int,
    slider_velocity: f64,
    
    judgement_index: int, 
    gfx_handles: []Drawable_Handle,
}

hitobject_pos :: proc(hobj: ^Hitobject) -> vec2 {
    return hobj.pos + hobj.script_pos_translation
}

hitobject_duration :: proc(hobj: ^Hitobject) -> (result: f64) {
    return hobj.end_time_ms - hobj.start_time_ms
}

hitobject_visible_start_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    start_time := hobj.start_time_ms
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER_HEAD: start_time -= game.beatmap.preempt_ms
    }
    return start_time
}

hitobject_visible_end_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    end_time := hobj.end_time_ms        
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER_HEAD: end_time += game.beatmap.timing_windows.ok
    }
    return end_time
}


Slider_Hitobject :: struct {
    
}


Timing_Point_Type :: enum {
    UNINHERITED, // red lines
    INHERITED,   // green lines
}

Timing_Point :: struct {
    time: f64,
    beat_length: f64,
    meter: u8,
    sample_set: Osu_Sample_Set,
    volume: f64,
    type: Timing_Point_Type,
    kiai: bool,
    
    starts_at_beat: int,
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
    pos, end_pos: vec2,
    type: Slider_Path_Type,
    distance_osupx: f64,

    nodes: []Slider_Node, // note(isak): slice into our array of all nodes
    curves: []Slider_Curve, // note(isak): slice into mapset arena
    
    bounds_min, bounds_max: vec2,
    
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
    HITOBJECTS,
    OVERLAY,
    UI,
    DEBUG
}


Timing_Window :: struct {
    marvelous, good, ok, miss: f64
}

Judgement_Type :: enum {
    NONE,
    
    MISS,
    OK,
    GOOD,
    MARVELOUS,
    
    SLIDER_SMALL_SCOREPOINT, // 10
    SLIDER_LARGE_SCOREPOINT, // 30
    
    IGNORED_HIT, // note(isak): used when we need a result that doesn't affect score 
    COMBO_BREAK, // note(isak): intended for scripted misses
}

// note(isak): need to handle (min_result, max_result) somehow
Judgement :: struct {
    result: Judgement_Type,
    time: f64,
}

Notosu_Map :: struct {
    lua_entry_point: string,
    shaders: []Shader,
}

Osu_Map :: struct {
    using Osu_Map_File_Data: struct {
        audio_filename: string,
        audio_lead_in: f64,
        preview_time_ms: f64,
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
        diff_slider_tickrate: f64,
        
        bg_filename: string,

        combo_colors: [8]Color,
        num_combo_colors: int,
    },
    
    audio_filepath: string,
    hitobjects: []Hitobject,
    slider_paths: []Slider_Path,
    timing_points: []Timing_Point,
}

osu_on_init :: proc() {
    game.time_rate = 1.0
    game.mode = .PLAY
    
    ui_init_timeline(&game.ui_timeline)
    
    game.input.k1_key = sdl.Scancode.Z
    game.input.k2_key = sdl.Scancode.X

    beatmap_on_init(&game.beatmap)
    game.playfield_transform = transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    // todo(isak): universal offset sync interface
    game.universal_offset_ms = -28
}


osu_on_update :: proc(dt: f64) {
    game.dt = dt

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] || updated_systems[.NOTOSU_FILE] {
        beatmap_reload(&game.beatmap, true)
    }
    if updated_systems[.SCRIPTS] {
        lua_reload(game.active_notosu_map.lua_entry_point)
        if lua_cares_about_event(.ON_INIT) {
            lua_call_beatmap_func(lua_beatmap_event_names[.ON_INIT])
        }
    } 
    if updated_systems[.SHADERS] {
        mapset_reinit_custom_shaders(game.active_mapset)
    }
    
    // note(isak): game logic - map
    
    beatmap_on_update(&game.beatmap)
    
    // todo(isak): this really handles a bunch of debug stuff too. fix up the modes and such
    #partial switch game.mode {
        case .PLAY: handle_play_input_events()
    }
    
    map_time := beatmap_music_time_ms(&game.beatmap)
    hobj_it := get_visible_hobj_iterator(&game.beatmap.visible_hitobject_state, map_time)
    
    for &hobj in hobj_it {
        if .VISIBLE not_in hobj.flags && .EXPIRED not_in hobj.flags {
            if hitobject_visible_start_time(&hobj) < map_time && map_time < hitobject_visible_end_time(&hobj) {
                hobj.flags |= {.VISIBLE}
                sb.append(&game.beatmap.expiring_hitobjects, hobj.index)
            }
        }
    }
    process_expiring_hitobjects(&game.beatmap.expiring_hitobjects)
    
    
    // todo(isak) off by one error here. makes hitting the final object impossible
    
    // todo(isak): valid key presses system needs testing
    if valid_controller_press() {
        for &hobj, i in hobj_it {
            if .EXPIRED in hobj.flags {
                continue
            }
            hobj_pos := hitobject_pos(&hobj)
            if !point_in_circle(game.input.mouse_pos, hobj_pos, game.beatmap.circle_radius_osupx) {
                continue
            }
            judgement := hitobject_on_click(&hobj)
            if judgement == .NONE {
                continue
            }
            
            clear_hitobject_drawables(&hobj)
            
            hobj.gfx_handles = reserve_handles(&game.beatmap.persistent_gfx, 2) or_continue
            
            hobj.gfx_handles[0] = drawable_new({
                flags = {.ACTIVE},
                element = builtin_element_slot(.CLICKED_HIT_CIRCLE_OVERLAY),
                layer = .HITOBJECTS,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_white,
                start_time_ms = map_time,
                end_time_ms = map_time + 250
            })
            hobj.gfx_handles[1] = drawable_new({
                flags = {.ACTIVE},
                element = builtin_element_slot(.CLICKED_HIT_CIRCLE),
                layer = .HITOBJECTS,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_purple,
                start_time_ms = map_time,
                end_time_ms = map_time + 250
            })
            
            judgement_new_drawable(&hobj)
            
            break
        } 
    }
    //--
    
    // beatmap render
    
    r_bind_layer_and_push_current_state(.HITOBJECTS)
    
    //-- @temp
    // todo(isak): for the eventual rewrite here that takes object type into account, consider a
    // function pointer in the hitobject struct that renders (and maybe one that updates? continual
    // logic is necessary for sliders... hitting circles is a keyboard event kind of thing)
    
    // todo(isak) ALSO don't forget that sliders SHOULD go on top of hitobjects appearing later, so the 
    // render hitobjects loop should be integrated into this
    for &hobj in hobj_it {
        if map_time < hobj.start_time_ms - game.beatmap.preempt_ms || hobj.end_time_ms < map_time {
            continue
        }
        if hobj.type == .SLIDER_HEAD {
            slider := &game.beatmap.slider_paths[hobj.slider_path_index]
            render_slider(&window.renderer, &hobj, slider)
            
            r_push_transform(game.playfield_transform)
            
            cs := game.beatmap.circle_radius_osupx
            sliderend_rect := Rect{ slider.end_pos.x - cs, slider.end_pos.y - cs, cs * 2, cs * 2 }
            r_draw_rect(&window.renderer.quad_geometry, sliderend_rect, with_alpha(color_white, 0.2), skin_texture(.HITCIRCLEOVERLAY))
        }
    }
    
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(game.playfield_transform)

    // note(isak): we render hitobject elements back to front for correct blending
    // todo(isak): @speed - use persistent_gfx for visible set optimization
    fade_in_ms := min(game.beatmap.preempt_ms * 0.4, 400.0)
    #reverse for &hobj in game.beatmap.hitobjects {
        alpha_mul: f32 = 1.0
        if hobj.judgement_index == 0 {
            visible_start := hobj.start_time_ms - game.beatmap.preempt_ms
            alpha_mul = f32(clamp((map_time - visible_start) / fade_in_ms, 0, 1))
        }
        #reverse for handle in hobj.gfx_handles {
            e := slotmap.get(&game.beatmap.drawables, handle) or_continue
            if .ACTIVE in e.flags {
                render_drawable(e, map_time, hitobject_pos(&hobj), alpha_mul)
            }
        }
    }
    //--
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.gameplay_expiring_gfx)
    
    r_bind_layer_and_push_current_state(.BACKGROUND, transform = game.playfield_transform)
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.map_expiring_gfx)
    
    // ui render
    
    // todo(isak): "screens" implementation for determining relevant UI components?
    handle_and_render_timeline()
    render_input_display()
}

// note(isak): this function assumes the start times of objects are sorted, but doesn't require end times to be.
// a pathological case might be a 2B element that stretches from the beginning of the map to the end
get_visible_hobj_iterator :: proc(state: ^Visibility_State, time: f64) -> []Hitobject {
    result: []Hitobject
    updated_from_index := state.earliest_i

    hitobjects := game.beatmap.hitobjects
    if len(hitobjects) > 0 {
        looking_for_finished_objects := true
        count_until_next_unstarted_hobj: int
        includes_final_index := 1

        for &hobj, i in hitobjects[state.earliest_i:] {
            count_until_next_unstarted_hobj = i
            if time < hitobject_visible_start_time(&hobj) {
                includes_final_index = 0
                break
            }
            if looking_for_finished_objects {
                if hitobject_visible_end_time(&hobj) < time {
                    updated_from_index += 1
                } else {
                    looking_for_finished_objects = false
                }
            }
        }
        state.latest_i = updated_from_index + count_until_next_unstarted_hobj + includes_final_index
        state.earliest_i = updated_from_index
        result = hitobjects[state.earliest_i:min(state.latest_i, len(hitobjects))]
    }
    return result
}

hitobject_on_click :: proc(hobj: ^Hitobject) -> (result: Judgement_Type) {
    // todo(isak): input timings should be threaded, should be more granular that way during heavy load
    click_time := beatmap_music_time_ms(&game.beatmap)
    time_error_ms: f64
    
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER_HEAD:
        time_error_ms = click_time - hobj.start_time_ms
        if abs(time_error_ms) < game.beatmap.timing_windows.marvelous {
            result = .MARVELOUS
        } else if abs(time_error_ms) < game.beatmap.timing_windows.good {
            result = .GOOD
        } else if abs(time_error_ms) < game.beatmap.timing_windows.ok {
            result = .OK
        } else if abs(time_error_ms) < game.beatmap.timing_windows.miss {
            result = .MISS
        }
    }
    
    if result != .NONE {
        judgement_new(hobj, result, time_error_ms)
        hobj.flags |= {.EXPIRED}
    }
    return result
}


handle_play_input_events :: proc() {
    if is_key_pressed(.ESCAPE) || is_key_pressed(.SPACE) {
        beatmap_pause(&game.beatmap, !game.paused)
    }
    if is_key_pressed(.R) {
        beatmap_reload(&game.beatmap, true)
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
    
    pf_mouse := vec2{mouse.pos.x, mouse.pos.y}
    pf_mouse.x -= (window.rect.w - window.rect.h) / 2
    
    old_mouse_pos := game.input.mouse_pos
    game.input.mouse_pos = transform_point_space(pf_mouse,
        transform_to_mat3(window.screenspace_transform),
        transform_to_mat3(game.playfield_transform)
    )
    
    if lua_cares_about_event(.ON_CURSOR_MOVED) && game.input.mouse_pos != old_mouse_pos {
        lua_beatmap_on_cursor_moved(game.input.mouse_pos)
    }
    
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
}

valid_controller_press :: proc() -> bool {
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


playfield_to_screenspace_transform :: proc() -> mat3 {
    return transform_to_mat3(game.playfield_transform) * linalg.matrix3_inverse(transform_to_mat3(window.screenspace_transform))
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
