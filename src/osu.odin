package inso

import "core:time"
import sb "swap_buffer"
import "slotmap"

import "core:math"
import "core:math/linalg"
import "core:strings"

import sdl "vendor:sdl3"


PLAYFIELD_SIZE_OSUPX :: f32(512)
OSU_HIT_ANIMATION_LENGTH :: 250

OSU_HITOBJECT_DIM_FACTOR :: f32(0.9)
OSU_HITOBJECT_DIM_UNTIL_MS :: f64(300)
OSU_HITOBJECT_DIM_FADE_MS :: f64(100)

NOTELOCK_SHAKE_DURATION_MS :: f64(120)
NOTELOCK_SHAKE_AMPLITUDE_OSUPX :: f32(8)
NOTELOCK_SHAKE_OSCILLATIONS :: f64(3)

// note(isak): osu!'s actual play area is 512x384 within the 512x512 osupx coordinate space,
// with a small vertical offset for the HUD
PLAYFIELD_BASE_sCALE :: f32(512.0 / 480.0)
PLAYFIELD_BASE_TRANSLATION_OSUPX :: vec2{0, 72} // (512-384)/2 + 8

// note(isak): state struct. keep it lean, put large data fields in arenas and point to it here
game: struct {

    dt: f64,
    frame_clock_s: f64,
    frame_clock_tsc: i64,
    
    active_mapset: ^Mapset,
    active_inso_map: ^Inso_Map,
    active_map: ^Osu_Map,
    active_skin: ^Skin,
    
    mode, mode_switching_to: Game_Mode,
    mode_seek_time_on_switch: f64,
    
    user_config: User_Configuration,
    tournament_client: bool,
    tournament_initial_map_path: string,
    
    input: struct {
        k1, k2, m1, m2: Button_State,
        keys: [Rebindable_Input_Key]sdl.Scancode,

        rebinding_key: Rebindable_Input_Key,
        captured_scancode: sdl.Scancode,

        mouse_keys_enabled: bool,
        mouse_pos: vec2,

        mouse_secondary_pos: vec2,
        ms1, ms2: Button_State,

        available_presses: int,
        last_hit_at, last_valid_press_at: f64,

        // note(isak): per-event judgement state (see osu_input)
        
        frame_events: []Input_Event,
        frame_start_mouse_screen: vec2,
        // note(isak): tracks physical controller state across frames so keyboard autorepeat
        // makes and stale releases can't fabricate presses
        raw_held: struct { k1, k2, m1, m2: bool },
    },

    // note(isak): map game logic fields

    mods: Osu_Mods,
    
    beatmap: Beatmap,
    beatmap_active: bool,
    playfield_transform: Transform,
    playfield_dirty_transform: bool,
    window_resized: bool,

    paused: bool,
    time_rate: f32,
    
    // note(isak): map game view fields
    
    ui_timeline: UI_Timeline,
    hit_error_bar: Hit_Error_Bar,
    accuracy_display: f64, // note(isak): eased toward score_accuracy for the rolling HUD counter
    ui_scale: f32,

    last_mode_switch_time: f64,

    // note(isak): managed sounds to be used with the game_sound_* api. we create BASS streams
    // from samples, and then BASS handles the rest - not quite sure if we can further reuse sound data
    // instead of creating multiple BASS handles, but i think it's fine.
    sounds: slotmap.Slotmap(Sound),
    expiring_sounds: sb.Swap_Buffer(slotmap.Handle),
}

Game_Mode :: enum {
    NONE,
    MAIN_MENU,
    PLAY,
    EDITOR,
    TOURNAMENT_WAIT_SCREEN,
}

@(rodata) null_mapset := Mapset{}
@(rodata) null_skin := Skin{}

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
}


Hitobject_Flags :: distinct bit_set[Hitobject_Flag]
Hitobject_Flag :: enum {
    VISIBLE,
    HAS_RESULT,
    EXPIRED,
    LAST_IN_COMBO,

    NEW_COMBO,

    HIDE_COMBO_NUMBERS,
    HIDDEN_BY_SCRIPT,

    NO_FOLLOWPOINT_IN,
    NO_FOLLOWPOINT_OUT,

    SLIDER_SNAKE_IN,
    SLIDER_SNAKE_OUT,
}

Hitsound_Flags :: distinct bit_set[Hitsound_Flag; u8]
Hitsound_Flag :: enum u8 {
    NORMAL,
    WHISTLE,
    FINISH,
    CLAP,
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

Followpoint_Connection :: struct {
    from_index, to_index:  int, // note(isak): into beatmap.hitobjects; positions resolved live at emit
    visible_start_time_ms: f64, // note(isak): from.end_time - preempt; a coarse lower bound for culling
}

Hitobject :: struct {
    type: Hitobject_Type,
    flags: Hitobject_Flags,
    index: int,

    start_time_ms, end_time_ms: f64,
    pos, script_pos_translation: vec2,
    stack_count: int, // note(isak): the stack offset is baked into pos (and the slider path) on beatmap load

    timing_point_index_uninherited: int,
    timing_point_index_inherited: int,
    hitsound_timing_point_index: int, // note(isak): resolved with hitsound leniency at start_time_ms
    hitsound_flags: Hitsound_Flags,
    extra_bits: u64, // note(isak): from the inso file
    combo_index: int, // note(isak): 1-indexed combo within the current map
    combo_color_index: int, // note(isak): combo_index plus every preceding combo's skip offset
    combo_number: u16,
    combo_color_skip_offset: u8, // note(isak): how many combo colors to skip on new combo

    slider_path_index: int,
    slider_state: Slider_State,
    slider_edge_hitsounds: []Slider_Edge_Hitsound,

    phase: Hitobject_Phase,
    notelock_shake_at_ms: f64,
    custom_preempt_ms: f64, // note(isak): per-object approach time override. 0 = use global
    custom_radius_osupx: f32, // note(isak): per-object circle size override. 0 = use global
    custom_elements: [Hitobject_Phase][]Element_ID,
    custom_element_nums: [Hitobject_Phase]int,
    custom_hit_animation_len_ms: f64,

    judgement_index: int,

    gfx_handles: []Drawable_Handle,
    gfx_handles_backing: []Drawable_Handle, // note(isak): kept across clears so respawns after a seek reuse it
}

Slider_Flags :: distinct bit_set[Slider_Flag]
Slider_Flag :: enum {
    TRACKING,
    HEAD_CHECKED,
    HEAD_HIT,
    HEAD_CONTINGENCY_WINDOW_PASSED,
    END_TRACKED,
    FINALIZED, // note(isak): scoring done at end_time; the slider lingers for its fade-out tail
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
    hitsound:     Hitsound_Flags,
    normal_set:   u8,
    addition_set: u8,
    timing_point_index: int, // note(isak): resolved with hitsound leniency at the edge's nominal time
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
    // note(isak): hitsound timing point per tick, traversal-major in temporal order
    // (traversal * tick_count + ordinal). allocated with the mapset allocator
    tick_timing_point_indices: []int,

    contingency_window_scorepoint_count: int,
    contingency_window_scorepoints: bit_set[0..<64; u64], // note(isak): ticks are 0, repeats are 1

    slide_sound: slotmap.Handle,
    whistle_sound: slotmap.Handle,

    gfx: struct {
        ball, follow:                           Drawable_Handle,
        end_circle, end_overlay, end_repeat:    Drawable_Handle, // tail position
        head_circle, head_overlay, head_repeat: Drawable_Handle, // head turnaround position
        clicked_circle, clicked_overlay:        Drawable_Handle, // head click animation, owner-drawn under the ball
        ticks: []Drawable_Handle,
    },
    // note(isak): per-part element override set from lua (0 = use the builtin slot)
    custom_elements: [Slider_Part]Element_ID,

    body_cache: Slider_Body_Cache,
}

Timing_Point_Type :: enum {
    UNINHERITED, // red lines
    INHERITED,   // green lines
}

Timing_Point :: struct {
    time: f64,
    beat_length: f64,
    meter: u8,
    sample_set: Skin_Sample_Set,
    sample_index: u32,
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

Layer :: enum {
    BACKGROUND,
    FOREGROUND,
    HITOBJECTS,
    OVERLAY,
    UI,
    CURSOR,
    TOP,
    PLATFORM, // note(isak): engine/debug overlays; always composited onto the real screen, on top of any post-processing
    BLANK,
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
    
    SLIDER_SMALL_SCOREPOINT, // tick, 10
    SLIDER_LARGE_SCOREPOINT, // repeat, 30
    SLIDER_SCOREPOINT_MISS,
    
    // note(isak): these don't affect score, but are useful for triggering effects in lua
    SLIDER_HEAD_MISS,
    SLIDER_HEAD_OK,
    SLIDER_HEAD_GOOD,
    SLIDER_HEAD_MARVELOUS,
    SLIDER_END_MISS,
    
    IGNORED_HIT, // note(isak): intended for when we need a result that doesn't affect score
    COMBO_BREAK, // note(isak): intended for scripted misses
}

// todo(isak): need to handle (min_result, max_result) somehow
Judgement :: struct {
    result: Judgement_Type,
    time: f64,
    time_error_ms: f64,
    hobj_index: int,
}

Score_State :: struct {
    hit_counts: [Judgement_Type]int,
    combo: int,
    max_combo: int,
    completed: bool, // note(isak): set once when the last scoring object is judged; gates the results screen, file save and on_map_complete

    // note(isak): accumulated in judgement_new so stat queries stay O(1) on marathon maps
    hit_errors: struct {
        sum, sum_squares:     f64,
        early_sum, late_sum:  f64,
        count, early_count, late_count: int,
    },
}

Inso_Map :: struct {
    lua_entry_point: string,
    bg_pipeline_name: string,
    double_mouse: bool,
    use_backbuffer: bool,
    fixed_update_rate_hz: f64, // note(isak): on_fixed_update / scheduled-event tick rate

    shaders: []Shader,

    // note(isak): parsed [HitObjectExtraBits] rows from the .inso
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
        sample_set: Skin_Sample_Set,
    
        title: string,
        title_unicode: string,
        artist: string,
        artist_unicode: string,
        creator: string,
        difficulty_name: string,
    
        stack_leniency: f64,

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
    bookmarks_ms: []f64,
}


osu_on_init :: proc() {
    startup_mode: Game_Mode = .TOURNAMENT_WAIT_SCREEN if game.tournament_client else .EDITOR

    game.active_mapset = &null_mapset
    game.active_inso_map = &null_mapset.inso_map
    game.active_map = &null_mapset.osu_map
    game.active_skin = skin_load(game.user_config.skin_path)
    
    game.time_rate = 1.0
    game.mode = startup_mode

    game_sounds_clear()
    ui_init_timeline(&game.ui_timeline)

    game.input.keys = game.user_config.keys
    game.input.mouse_keys_enabled = game.user_config.mouse_keys_enabled
    
    if game.tournament_client {
        if game.user_config.osu_install_path != "" {
            config_import_from_osu(game.user_config.osu_install_path)
        }
        
        if game.tournament_initial_map_path != "" {
            game.beatmap.map_reference = map_reference_from_path(game.tournament_initial_map_path)
        }
    } else {
        //-- @temp todo(isak): handle this properly when menu mode is a thing
        initial_map_ref :=
            len(app.map_references) > 0 ? app.map_references[0] : Map_Reference{ folder_path = "songs/test/" }
        //--
        beatmap_open(initial_map_ref)
    }
}

osu_on_update :: proc(dt: f64, frame_tsc: i64) {
    game.dt = dt
    game.frame_clock_s += dt / 1000
    game.frame_clock_tsc = frame_tsc

    window_set_resizable(game.mode != .PLAY)
    windows_key_set_disabled(game.mode == .PLAY && window.focused)
    platform_set_scheduling_priority(game.mode == .PLAY)
    
    if game.mode != .PLAY {
        updated_file := mapset_check_system_file_watch(&game.active_mapset.watch)
        if updated_file != {} {
            if updated_file[.SHADERS] {
                mapset_reinit_custom_shaders(game.active_mapset)
            } else {
                beatmap_open(game.beatmap.map_reference, true, 
                    reload_assets = updated_file[.INSO_FILE] || updated_file[.ASSETS])
            }
        }
    }
    
    // note(isak): game logic - map
    
    osu_handle_mode_switch()
    
    #partial switch game.mode {
        case .PLAY:
            handle_play_input_events()

        case .EDITOR:
            handle_menu_input_events()
            handle_editor_input_events()

        case .MAIN_MENU: 
            handle_menu_input_events()
            
        case .TOURNAMENT_WAIT_SCREEN: 
            if key_is_pressed(.RETURN) {
                game_switch_mode(.PLAY, 0)
            }
    }
    handle_universal_input_events()

    if game.beatmap_active {
        beatmap_on_update(&game.beatmap)
        
        map_time := beatmap_music_time_ms(&game.beatmap)
        visible_hobjs := beatmap_get_visible_hitobjects(&game.beatmap, map_time)
        
        // note(isak): handle hitobject phase changes
        for &hobj in visible_hobjs {
            if hobj.phase == .NONE {
                if hitobject_activation_time(&hobj) < map_time && map_time < hitobject_visible_end_time(&hobj) {
                    hitobject_emit_phase_transition(&hobj, .PREEMPT)
                    hobj.flags |= {.VISIBLE}
                    sb.append(&game.beatmap.expiring_hitobjects, hobj.index)
                }
            } else if hobj.phase == .PREEMPT && hobj.start_time_ms < map_time {
                hitobject_emit_phase_transition(&hobj, .POSTEMPT)
            }
        }
    
        if game.playfield_dirty_transform {
            game.playfield_transform = playfield_build_transform()
            game.playfield_dirty_transform = false
        }
    
        process_expiring_hitobjects(&game.beatmap.expiring_hitobjects)
        process_hitobject_hittesting(visible_hobjs, map_time)
        process_hitobject_phase_transitions()
        game_sounds_process_expiry()
        
        results_screen_update()
    
        // game render
        
        r_bind_layer_and_push_current_state(.HITOBJECTS, transform = game.playfield_transform)
        
        playfield_draw(visible_hobjs, map_time)
        
        r_bind_layer_and_push_current_state(.UI,
            transform = game.playfield_transform,
            pipeline = { pipeline = builtin_pipeline_slot(.QUAD) })
    
        playfield_border_draw()
        timeline_draw()
        edit_mode_label_draw()
    
        hit_error_bar_draw_screenspace(&game.hit_error_bar)
        input_display_draw_screenspace()
        //accuracy_display_draw_screenspace()
        results_screen_draw()
    }
    
    if !lua_beatmap.hide_skin_cursor {
        cursor_layer := lua_beatmap.cursor_layer
        if cursor_layer == .BACKGROUND do cursor_layer = .CURSOR
        r_bind_layer_and_push_current_state(cursor_layer, transform = window.screenspace_transform)
    
        cursor_expand_update()
        cursor_trail_draw(&cursor_trails[0], mouse.pos)
        cursor_draw(mouse.pos, skin_texture(.CURSOR))
        if app.mouse_input_mode == .RAW_DOUBLE_MOUSE_INPUT {
            cursor_trail_draw(&cursor_trails[1], mouse_secondary.pos)
            cursor_draw(mouse_secondary.pos, skin_texture(.CURSOR))
        }
    }
    
    tournament_waiting_screen_draw()
    
    rebind_screen_draw()
    fade_transition_draw()
}

game_switch_mode :: proc(mode: Game_Mode, seek_time: f64) {
    game.mode_switching_to = mode
    game.mode_seek_time_on_switch = seek_time
    game.last_mode_switch_time = game.frame_clock_s
}

osu_handle_mode_switch :: proc() {
    if game.mode_switching_to != .NONE &&
            game.frame_clock_s >= game.last_mode_switch_time + GAME_MODE_SWITCH_PRE_FADE_S {
        target := game.mode_switching_to
        game.mode = target
        game.mode_switching_to = .NONE

        beatmap_open(game.beatmap.map_reference)

        seek_time := game.mode_seek_time_on_switch
        if seek_time >= 0 {
            beatmap_seek(&game.beatmap, seek_time)
        } else {
            // note(isak): negative time is the empty lead-in; beatmap_on_update counts it up and
            // resumes the audio once it reaches zero, so we leave the freshly opened stream paused
            game.beatmap.music_time_ms = seek_time
            game.beatmap.auto_last_hit_time_ms = beatmap_music_time_ms(&game.beatmap)
        }

        game.paused = target == .EDITOR
        if game.paused {
            sound_pause(&game.beatmap.music)
        } else if game.beatmap.music_time_ms >= 0 {
            sound_resume(&game.beatmap.music)
        }
        if lua_cares_about_event(.ON_PAUSE_CHANGE) {
            lua_beatmap_on_pause_change(game.paused)
        }
    }
}

playfield_draw :: proc(visible_hobjs: []Hitobject, map_time: f64) {
    for i in followpoint_first_active(&game.beatmap, map_time)..<len(game.beatmap.followpoint_connections) {
        conn := &game.beatmap.followpoint_connections[i]
        if conn.visible_start_time_ms > map_time do break
        followpoint_emit(&game.beatmap, conn, map_time)
    }

    // note(isak): hitobjects render through render_drawable, which pushes its own state if necessary
    r_check_and_bind_layer(.HITOBJECTS)
    hitobjects_draw(visible_hobjs, map_time)
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.gameplay_expiring_gfx)
    process_and_draw_expiring_gfx_refs(&game.beatmap.judgement_expiring_gfx)
    
    r_bind_layer_and_push_current_state(.BACKGROUND, transform = game.playfield_transform)
    process_and_draw_expiring_gfx_refs(&game.beatmap.map_expiring_gfx)
}

hitobjects_draw :: proc(visible_hobjs: []Hitobject, map_time: f64) {
    // note(isak): we preprocess render order into sets so that we can support two cases for paths:
    // - sliderpaths that end before the next slider should go on top of succeeding objects (stacking)
    // - slider that begin during other sliders should have their elements go on top of the path (2B)
    cluster_bounds := make([dynamic]int, 0, len(visible_hobjs) + 1, context.temp_allocator)
    running_end_ms := math.inf_f64(-1)
    for &hobj, i in visible_hobjs {
        if hobj.start_time_ms > running_end_ms {
            append(&cluster_bounds, i)
        }
        running_end_ms = max(running_end_ms, hobj.end_time_ms)
    }
    append(&cluster_bounds, len(visible_hobjs))

    for ci := len(cluster_bounds) - 2; ci >= 0; ci -= 1 {
        cluster := visible_hobjs[cluster_bounds[ci]:cluster_bounds[ci + 1]]

        #reverse for &hobj in cluster {
            if hobj.type != .SLIDER do continue
            if .HIDDEN_BY_SCRIPT in hobj.flags do continue
            if hobj.start_time_ms - hitobject_preempt_ms(&hobj) <= map_time &&
               map_time <= hobj.end_time_ms + OSU_HIT_ANIMATION_LENGTH {
                r_check_and_bind_layer(.HITOBJECTS)
                path := &game.beatmap.slider_paths[hobj.slider_path_index]
                slider_render_path(&window.renderer, &hobj, path, map_time)
            }
        }

        #reverse for &hobj in cluster {
            r_check_and_bind_layer(.HITOBJECTS)
            if hobj.type == .SLIDER {
                r_push_transform(game.playfield_transform)
                slider_render_gfx(&hobj, map_time)
            }

            shake_offset := hitobject_notelock_shake_offset(&hobj, map_time)
            #reverse for handle in hobj.gfx_handles {
                e := slotmap.get(&game.beatmap.drawables, handle) or_continue
                if .ACTIVE in e.flags {
                    render_drawable(e, map_time, hitobject_pos(&hobj) + shake_offset)
                }
            }
        }

        #reverse for &hobj in cluster {
            if hobj.type != .SLIDER do continue
            r_check_and_bind_layer(.HITOBJECTS)
            slider_render_tracking_gfx(&hobj, map_time)
        }
    }
}

cursor_draw :: proc(pos: vec2, tex_index: u32) {
    cursor_size := cursor_size_px() * transition_mix(cursor_expand, 1, CURSOR_EXPAND_FACTOR)
    cursor_rect: Rect = { f32(pos.x), f32(pos.y), cursor_size, cursor_size }
    angle := f32(time_s_since_beginning_of_program()) if game.active_skin.cursor_rotate else 0
    r_draw_layout_rect(&window.renderer.quad_geometry, cursor_rect, .CENTER, color_white,
        tex_index, angle)

    // note(isak): cursormiddle sits centered on top and neither rotates nor expands, like stable
    if window.skin_textures[.CURSOR_MIDDLE].tex_id != 0 {
        size := cursor_companion_size_px(.CURSOR_MIDDLE)
        r_draw_layout_rect(&window.renderer.quad_geometry,
            { f32(pos.x), f32(pos.y), size.x, size.y }, .CENTER,
            color_white, skin_texture(.CURSOR_MIDDLE))
    }
}

// note(isak): stable scales the cursor texture against a 768px reference height
CURSOR_SPRITE_RES :: 768

cursor_size_px :: proc() -> f32 {
    cursor_width := game.active_skin.elements[.CURSOR].metrics.x
    return cursor_width * (window.rect.h / CURSOR_SPRITE_RES) * game.user_config.cursor_size_multiplier
}

cursor_companion_size_px :: proc(el: Skin_Element_Type) -> vec2 {
    cursor_metrics := game.active_skin.elements[.CURSOR].metrics
    if cursor_metrics.x <= 0 do return {cursor_size_px(), cursor_size_px()}
    return game.active_skin.elements[el].metrics * (cursor_size_px() / cursor_metrics.x)
}

CURSOR_EXPAND_FACTOR :: 1.3
CURSOR_EXPAND_ANIM_S :: 0.1

cursor_expand: Transition

cursor_expand_update :: proc() {
    pressed := button_is_down(mouse.buttons[.LEFT]) || button_is_down(mouse.buttons[.RIGHT])
    if game.mode == .PLAY {
        pressed = pressed || controller_key_down(1) || controller_key_down(2)
    }
    transition_update(&cursor_expand, pressed && game.active_skin.cursor_expand, CURSOR_EXPAND_ANIM_S)
}

// note(isak): 
// small trail: one part every SPACING_S, faded over LENGTH_S
// long trail (with cursormiddle.png): long additive trail of parts interpolated
// along the cursor's motion at a fixed pixel pitch, faded over SMOOTH_LENGTH_S
CURSOR_TRAIL_LENGTH_S        :: 0.17
CURSOR_TRAIL_SPACING_S       :: 0.015
CURSOR_TRAIL_SMOOTH_LENGTH_S :: 0.5
CURSOR_TRAIL_SMOOTH_DIV      :: 4.0
CURSOR_TRAIL_MAX_PARTS       :: 2048

Cursor_Trail_Part :: struct {
    pos: vec2,
    expires_at_s: f64,
}

Cursor_Trail :: struct {
    parts: [CURSOR_TRAIL_MAX_PARTS]Cursor_Trail_Part,
    head, count: int,
}

cursor_trails: [2]Cursor_Trail

cursor_trail_newest :: proc(trail: ^Cursor_Trail) -> ^Cursor_Trail_Part {
    return &trail.parts[(trail.head + trail.count - 1) %% CURSOR_TRAIL_MAX_PARTS]
}

cursor_trail_push :: proc(trail: ^Cursor_Trail, part: Cursor_Trail_Part) {
    if trail.count == CURSOR_TRAIL_MAX_PARTS {
        trail.head = (trail.head + 1) %% CURSOR_TRAIL_MAX_PARTS
        trail.count -= 1
    }
    trail.parts[(trail.head + trail.count) %% CURSOR_TRAIL_MAX_PARTS] = part
    trail.count += 1
}

cursor_trail_add_spaced :: proc(trail: ^Cursor_Trail, pos: vec2, now: f64) {
    if trail.count > 0 {
        newest := cursor_trail_newest(trail)
        spawned_at := newest.expires_at_s - CURSOR_TRAIL_LENGTH_S
        if now <= spawned_at + CURSOR_TRAIL_SPACING_S do return
        if newest.pos == pos {
            newest.expires_at_s = now + CURSOR_TRAIL_LENGTH_S
            return
        }
    }
    cursor_trail_push(trail, {pos, now + CURSOR_TRAIL_LENGTH_S})
}

// note(isak): fills the gap since the last part with evenly pitched interpolated parts, their expiry
// lerped across the same span so the ribbon fades uniformly along its length
cursor_trail_add_smooth :: proc(trail: ^Cursor_Trail, pos: vec2, trail_width: f32, now: f64) {
    expires := now + CURSOR_TRAIL_SMOOTH_LENGTH_S
    if trail.count == 0 {
        cursor_trail_push(trail, {pos, expires})
        return
    }

    newest := cursor_trail_newest(trail)
    prev_pos := newest.pos
    prev_expires := newest.expires_at_s

    pitch := trail_width / CURSOR_TRAIL_SMOOTH_DIV
    delta := pos - prev_pos
    dist := linalg.length(delta)
    part_count := int(dist / pitch)
    if part_count <= 0 do return

    step := (delta / dist) * pitch
    time_step := (expires - prev_expires) / f64(part_count)
    start := max(0, part_count - CURSOR_TRAIL_MAX_PARTS / 2)
    for i in start..<part_count {
        cursor_trail_push(trail, {
            prev_pos + step * f32(i + 1),
            prev_expires + time_step * f64(i + 1),
        })
    }
}

// note(isak): parts drawn oldest-first behind the cursor. the smooth ribbon is additive, so its dense
// overlaps sum into a glow rather than muddying; the unsmooth trail stays straight alpha.
cursor_trail_draw :: proc(trail: ^Cursor_Trail, pos: vec2) {
    if window.skin_textures[.CURSOR_TRAIL].tex_id == 0 do return
    now := time_s_since_beginning_of_program()

    size := cursor_companion_size_px(.CURSOR_TRAIL)
    smooth := window.skin_textures[.CURSOR_MIDDLE].tex_id != 0

    if smooth {
        cursor_trail_add_smooth(trail, pos, size.x, now)
    } else {
        cursor_trail_add_spaced(trail, pos, now)
    }

    // note(isak): leave one expired part to anchor the next smooth interpolation from where the cursor was
    for trail.count > 1 && trail.parts[trail.head].expires_at_s <= now {
        trail.head = (trail.head + 1) %% CURSOR_TRAIL_MAX_PARTS
        trail.count -= 1
    }

    length := CURSOR_TRAIL_SMOOTH_LENGTH_S if smooth else CURSOR_TRAIL_LENGTH_S
    if smooth {
        r_bind_pipeline({ pipeline = builtin_pipeline_slot(.QUAD_ADDITIVE) })
    }

    for i in 0..<trail.count {
        part := trail.parts[(trail.head + i) %% CURSOR_TRAIL_MAX_PARTS]
        alpha := f32(clamp((part.expires_at_s - now) / length, 0, 1))
        if alpha <= 0 do continue
        r_draw_layout_rect(&window.renderer.quad_geometry,
            {part.pos.x, part.pos.y, size.x, size.y}, .CENTER,
            with_alpha(color_white, alpha), skin_texture(.CURSOR_TRAIL))
    }

    if smooth {
        r_bind_pipeline({ pipeline = builtin_pipeline_slot(.QUAD) })
    }
}


//////////////////////////////////////////////////////
// note(isak): playfield math

// note(isak): builds game.playfield_transform from playfield_offset_osupx, playfield_scale,
// and playfield_rotation_rad. maps osupx -> NDC with full affine support (translate, scale, rotate). 
// the inverse correctly maps window pixels back to osupx without extra adjustment.
playfield_build_transform :: proc "contextless" () -> Transform {
    effective_scale       := PLAYFIELD_BASE_sCALE * game.beatmap.playfield_scale
    effective_translation := PLAYFIELD_BASE_TRANSLATION_OSUPX + game.beatmap.playfield_translation_osupx

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

    anchor_px := vec2{cx, cy} + k * (game.beatmap.playfield_rotation_anchor_osupx - PLAYFIELD_SIZE_OSUPX * 0.5)
    rotate_about_anchor := mat3_affine(anchor_px, 1, game.beatmap.playfield_rotation_rad) * mat3{
        1, 0, -anchor_px.x,
        0, 1, -anchor_px.y,
        0, 0,  1,
    }
    px_from_osupx := mat3_affine({cx, cy}, k, 0) * t_center

    return mat3_to_transform(ndc_from_px * rotate_about_anchor * px_from_osupx)
}

screenspace_to_playfield_osupx :: proc(pos: vec2) -> vec2 {
    return transform_point_space(pos,
        transform_to_mat3(window.screenspace_transform),
        transform_to_mat3(game.playfield_transform)
    )
}

playfield_osupx_to_screenspace :: proc(pos: vec2) -> vec2 {
    return transform_point_space(pos,
        transform_to_mat3(game.playfield_transform),
        transform_to_mat3(window.screenspace_transform)
    )
}

// note(isak): the window's four corners mapped back through the playfield transform, as an
// axis-aligned osupx cover (conservative under rotation). used to clip slider body bakes to
// what the camera can currently show
playfield_visible_osupx_bounds :: proc() -> Rect {
    lo := screenspace_to_playfield_osupx({0, 0})
    hi := lo
    corners := [3]vec2{{window.rect.w, 0}, {0, window.rect.h}, {window.rect.w, window.rect.h}}
    for corner in corners {
        p := screenspace_to_playfield_osupx(corner)
        lo = {min(lo.x, p.x), min(lo.y, p.y)}
        hi = {max(hi.x, p.x), max(hi.y, p.y)}
    }
    return Rect{lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// note(isak): the uniform pixels-per-osupx factor of the playfield transform (no rotation/translation).
// for converting sizes/extents between the two spaces; positions should round-trip the full transform.
playfield_px_per_osupx :: proc "contextless" () -> f32 {
    return PLAYFIELD_BASE_sCALE * game.beatmap.playfield_scale * window.rect.h / PLAYFIELD_SIZE_OSUPX
}

//////////////////////////////////////////////////////
// note(isak): input

Rebindable_Input_Key :: enum {
    NONE,
    K1,
    K2,
}

rebindable_input_key_names := [Rebindable_Input_Key]string {
    .NONE = "",
    .K1 = "Primary",
    .K2 = "Secondary",
}


//////////////////////////////////////////////////////
// note(isak): managed game sound API

// note(isak): expires_at_ms is absolute music time, 0 = no expiry
game_sound_play :: proc(
    s: ^Sample, loop: bool = false, volume: f32 = 1.0, category: Sound_Category = .HITSOUND, expires_at_ms: f64 = 0
) -> (result: slotmap.Handle) {
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
    stored, _ := slotmap.get(&game.sounds, handle)
    sound_play(stored, loop = loop, volume = volume, category = category)

    if expires_at_ms != 0 {
        base := cast(^Base_Sound)stored
        base.expires_at_ms = expires_at_ms
        sb.append(&game.expiring_sounds, handle)
    }
    return handle
}

game_sound_stop :: proc(handle: slotmap.Handle) {
    if handle == {} do return
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

game_sound_renew_expiry :: proc(handle: slotmap.Handle, expires_at_ms: f64) {
    if handle == {} do return
    sound, ok := slotmap.get(&game.sounds, handle)
    if ok {
        base := cast(^Base_Sound)sound
        base.expires_at_ms = expires_at_ms
    }
}

game_sounds_process_expiry :: proc() {
    music_time := beatmap_music_time_ms(&game.beatmap)
    for handle in game.expiring_sounds.current {
        sound, ok := slotmap.get(&game.sounds, handle)
        if !ok do continue

        base := cast(^Base_Sound)sound
        expired := base.expires_at_ms != 0 && music_time > base.expires_at_ms
        if expired || sound_is_finished(sound) {
            game_sound_stop(handle)
            continue
        }
        sb.append_next(&game.expiring_sounds, handle)
    }
    sb.swap(&game.expiring_sounds)
}

game_sounds_clear :: proc() {
    for &s in game.sounds.values {
        sound_destroy(&s)
    }
    slotmap.destroy(&game.sounds)
    free_all(memory.allocators[.SOUND])
    slotmap.init(&game.sounds, allocator = memory.allocators[.SOUND], capacity = 128)
    _ = slotmap.insert(&game.sounds, null_sound)

    sb.init(&game.expiring_sounds, capacity = 64, allocator = memory.allocators[.SOUND])

    slider_sounds_clear_loop_handles()
}
