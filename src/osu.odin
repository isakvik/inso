package notosu

import "core:time"
import sb "swap_buffer"
import "slotmap"

import "core:log"
import "core:math/linalg"
import vmem "core:mem/virtual"
import "core:strings"

import sdl "vendor:sdl3"


playfield_size_osupx :: f32(512)
osu_slider_curve_points_separation :: f32(2.5)

// note(isak): osu!'s actual play area is 512x384 within the 512x512 osu!px coordinate space,
// with a small vertical offset for the HUD. these constants define that base placement and
// are always applied in playfield_build_transform, independent of any lua adjustments.
playfield_base_scale :: f32(512.0 / 480.0)
playfield_base_translation_osupx :: vec2{0, 72} // (512-384)/2 + 8

// note(isak): state struct. keep it lean, put large data fields in arenas and point to it here
game: struct {
    dt: f64, 
    active_mapset: ^Mapset,
    active_notosu_map: ^Notosu_Map,
    active_map: ^Osu_Map,
    active_map_ref: Map_Reference,
    active_skin: ^Skin,
    
    mode: Game_Mode,
    
    user_config: User_Configuration,
    
    // note(isak): map game logic fields
    
    beatmap: Beatmap,
    playfield_transform: Transform,
    playfield_dirty_transform: bool,

    paused: bool,
    time_rate: f32,
    
    // note(isak): map game view fields
    
    ui_timeline: UI_Timeline,
    
    input: struct {
        k1, k2, m1, m2: Button_State,
        k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu

        mouse_keys_enabled: bool,
        mouse_pos: vec2,

        available_presses: int,
        last_hit_at, last_valid_press_at: f64,
    },

    // note(isak): managed sounds to be used with the game_sound_* api. we create BASS streams 
    // from samples, and then BASS handles the rest - not quite sure if we can further reuse sound data 
    // instead of creating multiple BASS handles, but i think it's fine.
    sounds: slotmap.Slotmap(Sound),
}

// note(isak): we reserve the first slot for safety reasons, and we crash on modification for debug reasons
@(rodata) null_drawable := Drawable{}
@(rodata) null_element := Element{}
@(rodata) null_judgement := Judgement{}
@(rodata) null_sound := Sound{}

// note(isak): core types

Visibility_State :: struct {
    earliest_i, latest_i: int,
}

Hitobject_Type :: enum u32 {
    NONE,
    CIRCLE,
    SLIDER,
    SPINNER,
    // CUSTOM // note(isak) big plans?
}


Hitobject_Flags :: distinct bit_set[Hitobject_Flag]
Hitobject_Flag :: enum {
    VISIBLE,
    HIT, // note(isak): has result
    EXPIRED,
    LAST_IN_COMBO,
    
    NEW_COMBO,
    WHISTLE,
    FINISH,
    CLAP,
}

Hitobject_Phase :: enum u8 {
    NONE,
    ACTIVE,  // on screen, hittable
    HOLD,    // slider: tracking the ball
    HIT,
    MISS,
}

Phase_Transition :: struct {
    hitobject_index: int,
    from, to: Hitobject_Phase,
}

Deferred_Activation :: struct {
    hitobject_index: int,
    visible_start_time_ms: f64,
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
    combo_index: int, // note(isak): 1-indexed combo within the current map
    combo_number: u16,
    combo_color_skip_offset: u8, // note(isak): how many combo colors to skip on new combo

    slider_path_index: int,
    slider_state: Slider_State,

    phase: Hitobject_Phase,
    custom_preempt_ms: f64,          // note(isak): per-object approach rate override. 0 = use global
    deferred_activation_index: int,  // note(isak): index+1 into beatmap.deferred_activations. 0 = not in list
    custom_elements: [Hitobject_Phase]Element_ID,

    judgement_index: int,
    gfx_handles: []Drawable_Handle,
}

Slider_Flags :: distinct bit_set[Slider_Flag]
Slider_Flag :: enum {
    TRACKING,
    HEAD_CHECKED,
    HEAD_HIT,
    END_TRACKED,
}

Slider_State :: struct {
    flags: Slider_Flags,
    down_key: int, // 0 = missed head or free (any key), 1 = k1 hit head, 2 = k2 hit head

    velocity: f64,
    distance, duration_ms: f64,
    
    tick_interval_ms: f64,
    tick_count: int,
    
    path_travel_count, checked_repeats_count, checked_path_ticks_count: int,
    hit_judgement_count: int,

    contingency_window_scorepoint_count: int,
    contingency_window_scorepoints: bit_set[0..<64; u64], // note(isak): ticks are 0, repeats are 1

    slide_sound: slotmap.Handle,
}

hitobject_pos :: proc(hobj: ^Hitobject) -> vec2 {
    return hobj.pos + hobj.script_pos_translation
}

hitobject_duration :: proc(hobj: ^Hitobject) -> (result: f64) {
    return hobj.end_time_ms - hobj.start_time_ms
}

hitobject_preempt_ms :: proc(hobj: ^Hitobject) -> f64 {
    return hobj.custom_preempt_ms if hobj.custom_preempt_ms != 0 else game.beatmap.preempt_ms
}

// note(isak): uses max_preempt_ms (max of global and all per-object preempts) to keep visible
// start times monotonic for the iterator while still including custom-preempt objects on time.
hitobject_visible_start_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    start_time := hobj.start_time_ms
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER: start_time -= game.beatmap.max_preempt_ms
    }
    return start_time
}

hitobject_visible_end_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    end_time := hobj.end_time_ms        
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER: end_time += game.beatmap.timing_windows.ok
    }
    return end_time
}

DEFAULT_COMBO_COLORS := [4]Color {
    {240, 150, 0, 0xFF},
    {5, 240, 5, 0xFF},
    {5, 5, 240, 0xFF},
    {240, 5, 5, 0xFF},
}

hitobject_combo_color :: proc(hobj: ^Hitobject) -> (result: Color) {
    if game.active_map.num_combo_colors > 0 {
        color_index := hobj.combo_index % game.active_map.num_combo_colors    
        result = game.active_map.combo_colors[color_index]
    } else {
        color_index := hobj.combo_index % len(DEFAULT_COMBO_COLORS)
        result = DEFAULT_COMBO_COLORS[color_index]
    }
    return result
}

hitobject_emit_phase_transition :: proc(hobj: ^Hitobject, to: Hitobject_Phase) {
    sb.append(&game.beatmap.phase_transitions, Phase_Transition{hobj.index, hobj.phase, to})
    hobj.phase = to
}


Timing_Point_Type :: enum {
    UNINHERITED, // red lines
    INHERITED,   // green lines
}

Timing_Point :: struct {
    time: f64,
    beat_length: f64,
    meter: u8,
    sample_set: u8,
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

    // note(isak): angles at the two endpoints, in radians (0 = pointing right).
    // head_angle_rad: direction from head toward the path interior (first -> second instance)
    // tail_angle_rad: direction of travel arriving at tail (second-to-last -> last instance)
    head_angle_rad, end_angle_rad: f32,
}

Game_Mode :: enum {
    UNINITIALIZED,
    MAIN_MENU,
    PLAY,
    EDITOR,
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
    SLIDER_SCOREPOINT_MISS,
    
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
    bg_pipeline_name: string,
}

Osu_Map :: struct {
    using Osu_Map_File_Data: struct {
        audio_filename: string,
        audio_lead_in: f64,
        preview_time_ms: f64,
        sample_set: Osu_Map_Sample_Set,
    
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

// note(isak): builds game.playfield_transform from playfield_offset_osupx, playfield_scale,
// and playfield_rotation_rad. maps osu!px -> NDC with full affine support (translate, scale,
// rotate). the inverse correctly maps window pixels back to osu!px without extra adjustment.
playfield_build_transform :: proc "contextless" () -> Transform {
    effective_scale       := playfield_base_scale * game.beatmap.playfield_scale
    effective_translation := playfield_base_translation_osupx + game.beatmap.playfield_translation_osupx

    k  := effective_scale * window.rect.h / playfield_size_osupx
    cx := window.rect.w * 0.5 + effective_translation.x * k
    cy := window.rect.h * 0.5 + effective_translation.y * k

    ndc_from_px := mat3{
        2 / window.rect.w, 0,                 -1,
        0,                 2 / window.rect.h, -1,
        0,                 0,                  1,
    }
    t_center := mat3{
        1, 0, -playfield_size_osupx * 0.5,
        0, 1, -playfield_size_osupx * 0.5,
        0, 0,  1,
    }

    return mat3_to_transform(ndc_from_px * mat3_affine({cx, cy}, k, game.beatmap.playfield_rotation_rad) * t_center)
}


osu_on_init :: proc() {
    game.time_rate = 1.0
    game.mode = .PLAY

    game_sounds_clear()
    ui_init_timeline(&game.ui_timeline)

    game.input.k1_key = sdl.Scancode.Z
    game.input.k2_key = sdl.Scancode.X

    beatmap_on_init(game.active_map_ref, &game.beatmap)
    game.playfield_transform = playfield_build_transform()
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
        case .MAIN_MENU: handle_menu_input_events()
    }
    
    map_time := beatmap_music_time_ms(&game.beatmap)
    visible_hobjs := get_visible_hitobjects(&game.beatmap.visible_hitobject_state, map_time)
    
    // note(isak): phase emitter - advance hitobjects entering the visibility window
    for &hobj in visible_hobjs {
        if hobj.phase == .NONE && hobj.custom_preempt_ms == 0 {
            if hitobject_visible_start_time(&hobj) < map_time && map_time < hitobject_visible_end_time(&hobj) {
                hitobject_emit_phase_transition(&hobj, .ACTIVE)
                hobj.flags |= {.VISIBLE}
                sb.append(&game.beatmap.expiring_hitobjects, hobj.index)
            }
        }
    }

    // note(isak): deferred activations for objects with per-object approach rate
    for da in game.beatmap.deferred_activations {
        if da.visible_start_time_ms > map_time do continue
        hobj := &game.beatmap.hitobjects[da.hitobject_index]
        if hobj.phase == .NONE {
            hitobject_emit_phase_transition(hobj, .ACTIVE)
            hobj.flags |= {.VISIBLE}
            sb.append(&game.beatmap.expiring_hitobjects, hobj.index)
        }
    }

    process_expiring_hitobjects(&game.beatmap.expiring_hitobjects)


    // todo(isak): valid key presses system needs testing
    game.input.available_presses = 0
    if game.input.mouse_keys_enabled {
        if button_is_pressed(game.input.k1) && !button_is_down(game.input.m1) do game.input.available_presses += 1
        if button_is_pressed(game.input.k2) && !button_is_down(game.input.m2) do game.input.available_presses += 1
        if button_is_pressed(game.input.m1) && !button_is_down(game.input.k1) do game.input.available_presses += 1
        if button_is_pressed(game.input.m2) && !button_is_down(game.input.k2) do game.input.available_presses += 1
    } else {
        if button_is_pressed(game.input.k1) do game.input.available_presses += 1
        if button_is_pressed(game.input.k2) do game.input.available_presses += 1
    }

    if valid_controller_press() {
        game.input.last_valid_press_at = map_time

        for &hobj, i in visible_hobjs {
            if hobj.phase != .ACTIVE {
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

            #partial switch hobj.type {
            case .CIRCLE:
                hitobject_emit_phase_transition(&hobj, .HIT)
                judgement_new_drawable(&hobj)
            case .SLIDER:
                hitobject_emit_phase_transition(&hobj, .HOLD)
            }

            consume_controller_press()
            break
        }
    }

    if game.playfield_dirty_transform {
        game.playfield_transform = playfield_build_transform()
        game.playfield_dirty_transform = false
    }

    // note(isak): process phase transitions — creates/replaces drawables in response to game logic
    process_phase_transitions()

    // beatmap render

    r_bind_layer_and_push_current_state(.HITOBJECTS)

    // todo(isak) @beta sliders SHOULD go on top of hitobjects appearing later, so the
    // render hitobjects loop should be integrated into this

    for &hobj in visible_hobjs {
        if map_time < hobj.start_time_ms - hitobject_preempt_ms(&hobj) || hobj.end_time_ms < map_time {
            continue
        }
        if hobj.type == .SLIDER {
            path := &game.beatmap.slider_paths[hobj.slider_path_index]
            render_slider_path(&window.renderer, &hobj, path)

            r_push_transform(game.playfield_transform)
            render_slider_quads(&hobj, path, map_time)
        }
    }

    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(game.playfield_transform)

    // note(isak): render hitobject elements back to front for correct blending
    #reverse for &hobj in visible_hobjs {
        alpha_mul: f32 = 1.0
        if hobj.judgement_index == 0 {
            preempt := hitobject_preempt_ms(&hobj)
            fade_in_ms := min(preempt * 0.4, 400.0)
            visible_start := hobj.start_time_ms - preempt
            alpha_mul = f32(clamp((map_time - visible_start) / fade_in_ms, 0, 1))
        }
        #reverse for handle in hobj.gfx_handles {
            e := slotmap.get(&game.beatmap.drawables, handle) or_continue
            if .ACTIVE in e.flags {
                render_drawable(e, map_time, hitobject_pos(&hobj), alpha_mul)
            }
        }
    }
    
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
get_visible_hitobjects :: proc(state: ^Visibility_State, time: f64) -> []Hitobject {
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
    case .CIRCLE, .SLIDER:
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
        if hobj.type == .SLIDER {
            slider_on_click(hobj)
        } else {
            judgement_new(hobj, result, time_error_ms)
            hobj.flags |= {.HIT, .EXPIRED}
        }

        timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
        sample_set := Skin_Sample_Set(timing_point.sample_set)
        
        // todo(isak): we don't handle custom sampleset timing sections, need to reserve some space and add indirection
        sample_play(&game.active_skin.hitsounds[sample_set][.HITNORMAL])
        
        if .WHISTLE in hobj.flags {
            sample_play(&game.active_skin.hitsounds[sample_set][.HITWHISTLE])
        }
        if .CLAP in hobj.flags {
            sample_play(&game.active_skin.hitsounds[sample_set][.HITCLAP])
        }
        if .FINISH in hobj.flags {
            sample_play(&game.active_skin.hitsounds[sample_set][.HITFINISH])
        }
    }
    return result
}


handle_play_input_events :: proc() {
    if key_is_pressed(.ESCAPE) || key_is_pressed(.SPACE) {
        beatmap_pause(&game.beatmap, !game.paused)
    }
    if key_is_pressed(.R) {
        beatmap_reload(&game.beatmap, !key_is_down(.LSHIFT))
    }
    
    if key_is_pressed(.HOME) {
        game.time_rate = 1
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    if key_is_pressed(.PAGEUP) {
        game.time_rate *= 2
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    if key_is_pressed(.PAGEDOWN) {
        game.time_rate /= 2
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    
    if key_is_pressed(.KP_PLUS) {
        game.user_config.universal_offset_ms += key_is_down(.LSHIFT) ? 1 : 5
    }
    if key_is_pressed(.KP_MINUS) {
        game.user_config.universal_offset_ms -= key_is_down(.LSHIFT) ? 1 : 5
    }
    
    if key_is_pressed(.F10) {
        game.input.mouse_keys_enabled = !game.input.mouse_keys_enabled
    }
    
    game.input.k1.is_down = keyboard.buttons[game.input.k1_key]
    game.input.k1.was_down = keyboard.buttons_prev_frame[game.input.k1_key]
    game.input.k2.is_down = keyboard.buttons[game.input.k2_key]
    game.input.k2.was_down = keyboard.buttons_prev_frame[game.input.k2_key]
    game.input.m1 = mouse.buttons[.LEFT]
    game.input.m2 = mouse.buttons[.RIGHT]
    
    screen_mouse := vec2{mouse.pos.x, mouse.pos.y}

    old_mouse_pos := game.input.mouse_pos
    game.input.mouse_pos = transform_point_space(screen_mouse,
        transform_to_mat3(window.screenspace_transform),
        transform_to_mat3(game.playfield_transform)
    )
    
    if lua_cares_about_event(.ON_CURSOR_MOVED) && game.input.mouse_pos != old_mouse_pos {
        lua_beatmap_on_cursor_moved(game.input.mouse_pos)
    }
    
    if lua_cares_about_event(.ON_KEY_DOWN) {
        for code in sdl.Scancode {
            if key_is_pressed(code) do lua_beatmap_on_key_pressed(code)
        }
    }
    if lua_cares_about_event(.ON_KEY_UP) {
        for code in sdl.Scancode {
            if key_is_released(code) do lua_beatmap_on_key_released(code)
        }
    }
    if lua_cares_about_event(.ON_CONTROLLER_PRESSED) {
        if button_is_pressed(game.input.k1) do lua_beatmap_on_controller_pressed("k1")
        if button_is_pressed(game.input.k2) do lua_beatmap_on_controller_pressed("k2")
        if button_is_pressed(game.input.m1) do lua_beatmap_on_controller_pressed("m1")
        if button_is_pressed(game.input.m2) do lua_beatmap_on_controller_pressed("m2")
    }
    if lua_cares_about_event(.ON_CONTROLLER_RELEASED) {
        if button_is_released(game.input.k1) do lua_beatmap_on_controller_released("k1")
        if button_is_released(game.input.k2) do lua_beatmap_on_controller_released("k2")
        if button_is_released(game.input.m1) do lua_beatmap_on_controller_released("m1")
        if button_is_released(game.input.m2) do lua_beatmap_on_controller_released("m2")
    }
}

handle_menu_input_events :: proc() {
    if key_is_pressed(.S) {
        if key_is_down(.LCTRL) || key_is_down(.LSHIFT) || key_is_down(.LALT) {
            skin_reload(game.active_skin)
        }
    }
}

valid_controller_press :: proc() -> bool {
    return game.input.available_presses > 0
}

consume_controller_press :: proc() {
    game.input.available_presses -= 1
}

// returns whether key_num (1 or 2) was freshly pressed this frame, applying mouse_keys exclusion
controller_key_pressed :: proc(key_num: int) -> bool {
    if key_num == 1 {
        if game.input.mouse_keys_enabled {
            return button_is_pressed(game.input.k1) && !button_is_down(game.input.m1) ||
                   button_is_pressed(game.input.m1) && !button_is_down(game.input.k1)
        }
        return button_is_pressed(game.input.k1)
    } else {
        if game.input.mouse_keys_enabled {
            return button_is_pressed(game.input.k2) && !button_is_down(game.input.m2) ||
                   button_is_pressed(game.input.m2) && !button_is_down(game.input.k2)
        }
        return button_is_pressed(game.input.k2)
    }
}

// returns whether key_num (1 or 2) is currently held
controller_key_down :: proc(key_num: int) -> bool {
    if key_num == 1 {
        return button_is_down(game.input.k1) || game.input.mouse_keys_enabled && button_is_down(game.input.m1)
    } else {
        return button_is_down(game.input.k2) || game.input.mouse_keys_enabled && button_is_down(game.input.m2)
    }
}

// returns which key (1 or 2) was freshly pressed this frame, 0 if neither
pressed_controller_key :: proc() -> int {
    if controller_key_pressed(1) do return 1
    if controller_key_pressed(2) do return 2
    return 0
}


//////////////////////////////////////////////////////
// note(isak): managed game sound API

game_sound_play :: proc(s: ^Sample, loop: bool = false, volume: f32 = 1.0, category: Sound_Category = .HITSOUND) -> (result: slotmap.Handle) {
    sound: Sound
    ok: bool
    if loop {
        sound, ok = sound_stream_init_from_memory(s.file_data, loop = true)
    } else {
        sound, ok = sound_channel_init(s)
    }
    if !ok do return

    handle := slotmap.insert(&game.sounds, sound)
    snd := slotmap.get(&game.sounds, handle) or_else {}
    sound_play(snd, loop = loop, volume = volume, category = category)
    return handle
}

game_sound_stop :: proc(handle: slotmap.Handle) {
    sound, ok := slotmap.get(&game.sounds, handle)
    if ok {
        sound_destroy(sound)
        slotmap.remove(&game.sounds, handle)
    }
}

game_sound_is_playing :: proc(handle: slotmap.Handle) -> (result: bool) {
    sound, ok := slotmap.get(&game.sounds, handle)
    if ok {
        result = sound_is_playing(sound)
    }
    return result
}

game_sounds_clear :: proc() {
    for &s in game.sounds.values {
        sound_destroy(&s)
    }
    slotmap.destroy(&game.sounds)
    slotmap.init(&game.sounds, allocator = memory.allocators[.SOUND], capacity = 128)
    null_sound_handle := slotmap.insert(&game.sounds, null_sound)
}

//////////////////////////////////////////////////////
// NOTE(yokes): in-game button input api

button_is_down :: proc "c" (button: Button_State) -> bool {
    return button.is_down
}

button_is_pressed :: proc "c" (button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

button_is_released :: proc "c" (button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

key_is_down :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code]
}

key_is_pressed :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code] && !keyboard.buttons_prev_frame[code]
}

key_is_released :: proc "c" (code: sdl.Scancode) -> bool {
    return !keyboard.buttons[code] && keyboard.buttons_prev_frame[code]
}
