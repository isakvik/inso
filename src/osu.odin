package notosu

import "core:time"
import sb "swap_buffer"
import "slotmap"

import "core:log"
import "core:math"
import "core:math/linalg"
import vmem "core:mem/virtual"
import "core:strings"

import sdl "vendor:sdl3"


PLAYFIELD_SIZE_OSUPX :: f32(512)
OSU_SLIDER_CURVE_POINTS_SEPARATION :: f32(2.5)
OSU_HIT_ANIMATION_LENGTH :: 250

NOTELOCK_SHAKE_DURATION_MS :: f64(120)
NOTELOCK_SHAKE_AMPLITUDE_OSUPX :: f32(8)
NOTELOCK_SHAKE_OSCILLATIONS :: f64(3)

// note(isak): osu!'s actual play area is 512x384 within the 512x512 osupx coordinate space,
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
    active_skin: ^Skin,
    
    mode: Game_Mode,
    
    user_config: User_Configuration,
    
    input: struct {
        k1, k2, m1, m2: Button_State,
        k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu

        mouse_keys_enabled: bool,
        mouse_pos: vec2,

        mouse_secondary_pos: vec2,
        ms1, ms2: Button_State,

        available_presses: int,
        last_hit_at, last_valid_press_at: f64,
    },

    // note(isak): map game logic fields
    
    beatmap: Beatmap,
    beatmap_active: bool,
    playfield_transform: Transform,
    playfield_dirty_transform: bool,

    paused: bool,
    time_rate: f32,
    
    // note(isak): map game view fields
    
    ui_timeline: UI_Timeline,
    hit_error_bar: Hit_Error_Bar,

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

    HIDE_COMBO_NUMBERS,
    HIDDEN_BY_SCRIPT,
}

Hitobject_Phase :: enum u8 {
    NONE,
    PREEMPT,  // visible before note time
    POSTEMPT, // visible after note time
    HOLD,     // slider: tracking the ball
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
    extra_bits: u64, // note(isak): from the notosu file
    combo_index: int, // note(isak): 1-indexed combo within the current map
    combo_number: u16,
    combo_color_skip_offset: u8, // note(isak): how many combo colors to skip on new combo

    slider_path_index: int,
    slider_state: Slider_State,
    slider_edge_hitsounds: []Slider_Edge_Hitsound,

    phase: Hitobject_Phase,
    notelock_shake_at_ms: f64,
    custom_preempt_ms: f64, // note(isak): per-object approach time override. 0 = use global
    custom_radius_osupx: f32, // note(isak): per-object circle size override. 0 = use global
    deferred_activation_index: int, // note(isak): index+1 into beatmap.deferred_activations. 0 = not in list
    custom_elements: [Hitobject_Phase][]Element_ID,
    custom_element_nums: [Hitobject_Phase]int,
    custom_hit_animation_len_ms: f64,

    judgement_index: int,
    gfx_handles: []Drawable_Handle,
}

Slider_Flags :: distinct bit_set[Slider_Flag]
Slider_Flag :: enum {
    TRACKING,
    HEAD_CHECKED,
    HEAD_HIT,
    HEAD_CONTINGENCY_WINDOW_PASSED,
    END_TRACKED,
}

Slider_Handles :: struct {
    ball, follow:                           Drawable_Handle,
    end_circle, end_overlay, end_repeat:    Drawable_Handle, // tail position
    head_circle, head_overlay, head_repeat: Drawable_Handle, // head turnaround position
    ticks: []Drawable_Handle,
}

// note(isak): exposed to lua
Slider_Part :: enum u8 {
    BALL,
    FOLLOW_CIRCLE,
    TICK,
    REPEAT,
    END,
    END_OVERLAY,
}

Slider_Edge_Hitsound :: struct {
    hitsound:     u8, // osu bitmask: whistle (2), finish (4), clap (8)
    normal_set:   u8,
    addition_set: u8,
}

Slider_State :: struct {
    flags: Slider_Flags,
    down_key: int, // note(isak): 0 = missed head or free (any key), 1 = k1 hit head, 2 = k2 hit head

    velocity: f64,
    distance, duration_ms: f64,
    follow_circle_radius_mult: f32,
    
    tick_interval_ms: f64,
    tick_count: int,
    
    path_travel_count, checked_repeats_count, checked_path_ticks_count: int,
    hit_judgement_count: int,
    tracked_timestamp_at: f64,

    tick_hits: []bool, // note(isak): cleared on repeat. allocated with the mapset allocator

    contingency_window_scorepoint_count: int,
    contingency_window_scorepoints: bit_set[0..<64; u64], // note(isak): ticks are 0, repeats are 1

    slide_sound: slotmap.Handle,
    whistle_sound: slotmap.Handle,

    gfx: Slider_Handles,
    // note(isak): per-part element override set from lua (0 = use the builtin slot)
    custom_elements: [Slider_Part]Element_ID,
}

hitobject_pos :: proc(hobj: ^Hitobject) -> vec2 {
    return hobj.pos + hobj.script_pos_translation
}

hitobject_tail_pos :: proc(hobj: ^Hitobject) -> vec2 {
    path := &game.beatmap.slider_paths[hobj.slider_path_index]
    tail_pos := (path.pos if hobj.slider_state.path_travel_count % 2 == 0 else path.end_pos) + hobj.script_pos_translation
    return tail_pos
}

hitobject_duration :: proc(hobj: ^Hitobject) -> (result: f64) {
    return hobj.end_time_ms - hobj.start_time_ms
}

// note(isak): whether the object's head can still receive a press, which is what notelock keys off. we look
// at the start time window only, never the end time - so an in-progress slider (head hit, or its head window
// elapsed) stops blocking the next object, matching osu!. a hit head sits in HOLD so the phase check excludes
// it; an unhit head stops counting once its late window passes.
hitobject_head_hittable :: proc(hobj: ^Hitobject, map_time: f64) -> bool {
    if hobj.phase != .PREEMPT && hobj.phase != .POSTEMPT do return false
    if hobj.type != .CIRCLE && hobj.type != .SLIDER do return false
    return map_time <= hobj.start_time_ms + game.beatmap.timing_windows.ok
}

// note(isak): render-only horizontal offset for the notelock shake. does not affect hit detection
hitobject_notelock_shake_offset :: proc(hobj: ^Hitobject, map_time: f64) -> vec2 {
    if hobj.notelock_shake_at_ms == 0 do return {}
    t := map_time - hobj.notelock_shake_at_ms
    if t < 0 || t >= NOTELOCK_SHAKE_DURATION_MS do return {}

    progress := t / NOTELOCK_SHAKE_DURATION_MS
    envelope := f32(1 - progress)
    phase := f32(2 * math.PI * NOTELOCK_SHAKE_OSCILLATIONS * progress)
    return {NOTELOCK_SHAKE_AMPLITUDE_OSUPX * envelope * math.sin(phase), 0}
}

hitobject_preempt_ms :: proc(hobj: ^Hitobject) -> f64 {
    return hobj.custom_preempt_ms if hobj.custom_preempt_ms != 0 else game.beatmap.preempt_ms
}

hitobject_radius_osupx :: proc(hobj: ^Hitobject) -> f32 {
    return hobj.custom_radius_osupx if hobj.custom_radius_osupx != 0 else game.beatmap.circle_radius_osupx
}

// note(isak): uses max_preempt_ms (max of global and all per-object preempts) to keep visible
// start times monotonic for the iterator while still including custom-preempt objects on time.
hitobject_visible_start_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    start_time := hobj.start_time_ms
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER: start_time -= max(game.beatmap.max_preempt_ms, game.beatmap.timing_windows.miss)
    }
    return start_time
}

hitobject_visible_end_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    end_time := hobj.end_time_ms + game.beatmap.timing_windows.ok
    hit_anim_len := hobj.custom_hit_animation_len_ms != 0 ? hobj.custom_hit_animation_len_ms : OSU_HIT_ANIMATION_LENGTH
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER: end_time += hit_anim_len
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

hitobject_set_preempt :: proc(hobj: ^Hitobject, preempt: f64) {
    hobj.custom_preempt_ms = preempt
    beatmap := &game.beatmap
    visible_start := hobj.start_time_ms - preempt
    if hobj.deferred_activation_index != 0 {
        beatmap.deferred_activations[hobj.deferred_activation_index - 1].visible_start_time_ms = visible_start
    } else {
        append(&beatmap.deferred_activations, Deferred_Activation{hobj.index, visible_start})
        hobj.deferred_activation_index = len(beatmap.deferred_activations)
    }
    if preempt > beatmap.max_preempt_ms {
        beatmap.max_preempt_ms = preempt
    }
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
    bg_pipeline_name: string,
    double_mouse: bool,

    shaders: []Shader,

    // note(isak): parsed [HitObjectExtraBits] rows, applied to hitobjects after the whole mapset is walked
    // (the .osu and .notosu files can be parsed in either order)
    hitobject_extra_bits: [dynamic]Hitobject_Extra_Bits,
}

Hitobject_Extra_Bits :: struct {
    time_ms: int,
    bits:    u64,
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
// and playfield_rotation_rad. maps osupx -> NDC with full affine support (translate, scale, rotate). 
// the inverse correctly maps window pixels back to osupx without extra adjustment.
playfield_build_transform :: proc "contextless" () -> Transform {
    effective_scale       := playfield_base_scale * game.beatmap.playfield_scale
    effective_translation := playfield_base_translation_osupx + game.beatmap.playfield_translation_osupx

    k  := effective_scale * window.rect.h / PLAYFIELD_SIZE_OSUPX
    cx := window.rect.w * 0.5 + effective_translation.x * k
    cy := window.rect.h * 0.5 + effective_translation.y * k

    ndc_from_px := mat3{
        2 / window.rect.w, 0,                 -1,
        0,                 2 / window.rect.h, -1,
        0,                 0,                  1,
    }
    t_center := mat3{
        1, 0, -PLAYFIELD_SIZE_OSUPX * 0.5,
        0, 1, -PLAYFIELD_SIZE_OSUPX * 0.5,
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
}


osu_on_update :: proc(dt: f64) {
    game.dt = dt

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] || updated_systems[.NOTOSU_FILE] || updated_systems[.SCRIPTS] {
        beatmap_open(game.beatmap.map_reference, true)
    }
    if updated_systems[.SHADERS] {
        mapset_reinit_custom_shaders(game.active_mapset)
    }
    
    // note(isak): game logic - map
    
    beatmap_on_update(&game.beatmap)
    
    // todo(isak): this really handles a bunch of debug stuff too. fix up the modes and such
    #partial switch game.mode {
        case .PLAY: 
            handle_menu_input_events() // @temp todo(isak): mode switching isn't handled yet
            handle_play_input_events()
            
        case .MAIN_MENU: handle_menu_input_events()
    }
    
    map_time := beatmap_music_time_ms(&game.beatmap)
    visible_hobjs := beatmap_get_visible_hitobjects(&game.beatmap, map_time)
    
    // note(isak): handle hitobject phase changes
    for &hobj in visible_hobjs {
        if hobj.phase == .NONE && hobj.custom_preempt_ms == 0 {
            if hitobject_visible_start_time(&hobj) < map_time && map_time < hitobject_visible_end_time(&hobj) {
                hitobject_emit_phase_transition(&hobj, .PREEMPT)
                hobj.flags |= {.VISIBLE}
                sb.append(&game.beatmap.expiring_hitobjects, hobj.index)
            }
        } else if hobj.phase == .PREEMPT && hobj.start_time_ms < map_time {
            hitobject_emit_phase_transition(&hobj, .POSTEMPT)
        }
    }

    // note(isak): deferred activations for objects with per-object approach rate
    for da in game.beatmap.deferred_activations {
        if da.visible_start_time_ms > map_time do continue
        hobj := &game.beatmap.hitobjects[da.hitobject_index]
        if hobj.phase == .NONE {
            hitobject_emit_phase_transition(hobj, .PREEMPT)
            hobj.flags |= {.VISIBLE}
            sb.append(&game.beatmap.expiring_hitobjects, hobj.index)
        }
    }
    
    if game.playfield_dirty_transform {
        game.playfield_transform = playfield_build_transform()
        game.playfield_dirty_transform = false
    }

    process_expiring_hitobjects(&game.beatmap.expiring_hitobjects)
    process_hitobject_hittesting(visible_hobjs, map_time)
    process_hitobject_phase_transitions()

    // game render

    r_bind_layer_and_push_current_state(.HITOBJECTS, transform = game.playfield_transform)

    #reverse for &hobj in visible_hobjs {
        if .HIDDEN_BY_SCRIPT in hobj.flags do continue
        r_check_and_bind_layer(.HITOBJECTS)
        if hobj.start_time_ms - hitobject_preempt_ms(&hobj) <= map_time && map_time <= hobj.end_time_ms {
            
            if hobj.type == .SLIDER {
                path := &game.beatmap.slider_paths[hobj.slider_path_index]
                slider_render_path(&window.renderer, &hobj, path)
    
                r_push_transform(game.playfield_transform)
                slider_render_gfx(&hobj, map_time)
            }
        }
        
        r_push_transform(game.playfield_transform)
        r_bind_framebuffer({read = builtin_framebuffer(.DEFAULT), write = builtin_framebuffer(.DEFAULT)})
        
        shake_offset := hitobject_notelock_shake_offset(&hobj, map_time)
        #reverse for handle in hobj.gfx_handles {
            e := slotmap.get(&game.beatmap.drawables, handle) or_continue
            if .ACTIVE in e.flags {
                render_drawable(e, map_time, hitobject_pos(&hobj) + shake_offset)
            }
        }
    }
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.gameplay_expiring_gfx)
    
    r_bind_layer_and_push_current_state(.BACKGROUND, transform = game.playfield_transform)
    process_and_draw_expiring_gfx_refs(&game.beatmap.map_expiring_gfx)
    
    // ui render
    r_bind_layer_and_push_current_state(.UI, 
        transform = game.playfield_transform,
        pipeline = {builtin_pipeline_slot(.QUAD)})
    
    // -- @temp playfield border
    playfield_border_draw :: proc() {
        cs := game.beatmap.circle_radius_osupx
        pf_outline := Rect{
            -cs, -cs, PLAYFIELD_SIZE_OSUPX+2*cs, (PLAYFIELD_SIZE_OSUPX*3/4)+2*cs
        }
        r_draw_rect_outline(&window.renderer.quad_geometry, pf_outline, with_alpha(color_white, 0.1), 2)
    }
    playfield_border_draw()
    // --
    
    // todo(isak): "screens" implementation for determining relevant UI components?
    timeline_update(&game.ui_timeline)
    render_timeline_clipspace(&game.ui_timeline)
    
    hit_error_bar_draw_screenspace(&game.hit_error_bar)
    input_display_draw_screenspace()

    cursor_draw(mouse.pos, skin_texture(.CURSOR))
    if app.mouse_input_mode == .DOUBLE_MOUSE_INPUT {   
        cursor_draw(mouse_secondary.pos, skin_texture(.CURSOR))
    }

    r_bind_layer(.DEBUG)
    r_color_mask(false, false, false, true)
    r_draw_layout_rect(&window.renderer.quad_geometry, {0, 0, window.rect.w, window.rect.h }, .TOP_LEFT, color_black)
    r_color_mask(true, true, true, true)
}

cursor_draw :: proc(pos: vec2, tex_index: u32) {
    cursor_size := 160 * (window.rect.h / 1440) * game.user_config.cursor_size_multiplier
    cursor_rect: Rect = { f32(pos.x), f32(pos.y), cursor_size, cursor_size }
    r_draw_layout_rect(&window.renderer.quad_geometry, cursor_rect, .CENTER, color_white, 
        tex_index, f32(time_s_since_beginning_of_program()))
}


// note(isak): converts a screen-space pixel position (origin top-left, in window pixels) into playfield
// osupx space, the coordinate space hitobjects and playfield drawables live in. the inverse of the
// playfield transform, so it tracks any lua playfield translate/scale/rotate automatically.
screenspace_to_playfield_osupx :: proc(pos: vec2) -> vec2 {
    return transform_point_space(pos,
        transform_to_mat3(window.screenspace_transform),
        transform_to_mat3(game.playfield_transform)
    )
}

transform_mouse_pos :: proc(pos: vec2) -> vec2 {
    return screenspace_to_playfield_osupx(pos)
}

handle_play_input_events :: proc() {
    if key_is_pressed(.ESCAPE) || key_is_pressed(.SPACE) {
        beatmap_pause(&game.beatmap, !game.paused)
    }
    if key_is_pressed(.R) {
        beatmap_open(game.beatmap.map_reference, !key_is_down(.LSHIFT))
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
        notify_warn("mouse keys enabled" if game.input.mouse_keys_enabled else "mouse keys disabled")
    }
    
    game.input.k1.is_down = keyboard.buttons[game.input.k1_key]
    game.input.k1.was_down = keyboard.buttons_prev_frame[game.input.k1_key]
    game.input.k2.is_down = keyboard.buttons[game.input.k2_key]
    game.input.k2.was_down = keyboard.buttons_prev_frame[game.input.k2_key]
    game.input.m1 = mouse.buttons[.LEFT]
    game.input.m2 = mouse.buttons[.RIGHT]
    
    old_mouse_pos := game.input.mouse_pos
    game.input.mouse_pos = transform_mouse_pos(vec2{mouse.pos.x, mouse.pos.y})
    
    if lua_cares_about_event(.ON_CURSOR_MOVED) && game.input.mouse_pos != old_mouse_pos {
        lua_beatmap_on_cursor_moved(game.input.mouse_pos)
    }

    if app.mouse_input_mode == .DOUBLE_MOUSE_INPUT {
        game.input.mouse_secondary_pos = transform_mouse_pos(vec2{mouse_secondary.pos.x, mouse_secondary.pos.y})
        game.input.ms1 = mouse_secondary.buttons[.LEFT]
        game.input.ms2 = mouse_secondary.buttons[.RIGHT]
    }
    
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
        if key_is_down(.LCTRL) && key_is_down(.LSHIFT) && key_is_down(.LALT) {
            skin_reload(game.active_skin)
        }
    }
}


//////////////////////////////////////////////////////
// note(isak): managed game sound API

game_sound_play :: proc(s: ^Sample, loop: bool = false, volume: f32 = 1.0, category: Sound_Category = .HITSOUND) -> (result: slotmap.Handle) {
    if s.handle == 0 do return
    
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
    vmem.arena_free_all(&memory.arenas[.SOUND])
    slotmap.init(&game.sounds, allocator = memory.allocators[.SOUND], capacity = 128)
    null_sound_handle := slotmap.insert(&game.sounds, null_sound)
}
