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

OSU_HITOBJECT_DIM_FACTOR :: f32(0.9)
OSU_HITOBJECT_DIM_UNTIL_MS :: f64(300)
OSU_HITOBJECT_DIM_FADE_MS :: f64(100)

NOTELOCK_SHAKE_DURATION_MS :: f64(120)
NOTELOCK_SHAKE_AMPLITUDE_OSUPX :: f32(8)
NOTELOCK_SHAKE_OSCILLATIONS :: f64(3)

// note(isak): osu!'s actual play area is 512x384 within the 512x512 osupx coordinate space,
// with a small vertical offset for the HUD
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
        keys: [Rebindable_Input_Key]sdl.Scancode,

        rebinding_key: Rebindable_Input_Key,

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
    window_resized: bool,

    paused: bool,
    time_rate: f32,
    
    // note(isak): map game view fields
    
    ui_timeline: UI_Timeline,
    hit_error_bar: Hit_Error_Bar,
    ui_scale: f32,

    // note(isak): managed sounds to be used with the game_sound_* api. we create BASS streams
    // from samples, and then BASS handles the rest - not quite sure if we can further reuse sound data
    // instead of creating multiple BASS handles, but i think it's fine.
    sounds: slotmap.Slotmap(Sound),
    expiring_sounds: sb.Swap_Buffer(slotmap.Handle),
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

    HIDE_COMBO_NUMBERS,
    HIDDEN_BY_SCRIPT,

    NO_FOLLOWPOINT_IN,  // note(isak): suppress the followpoint arriving at this object
    NO_FOLLOWPOINT_OUT, // note(isak): suppress the followpoint leaving this object

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

    timing_point_index_uninherited: int,
    timing_point_index_inherited: int,
    hitsound_timing_point_index: int, // note(isak): resolved with hitsound leniency at start_time_ms
    hitsound_flags: Hitsound_Flags,
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

// note(isak): whether the object's head can still receive a press, used in notelock calcs
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
    case .CIRCLE, .SLIDER, .SPINNER: start_time -= max(game.beatmap.max_preempt_ms, game.beatmap.timing_windows.miss)
    }
    return start_time
}

// note(isak): exact time an object enters PREEMPT and becomes hittable. gates on the object's own
// preempt, unlike the visible-window scan above which must widen by max_preempt_ms to stay monotonic.
// the miss window floors it so low-preempt objects are still hittable through their full miss window.
hitobject_activation_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    result = hobj.start_time_ms
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER, .SPINNER: result -= max(hitobject_preempt_ms(hobj), game.beatmap.timing_windows.miss)
    }
    return result
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
    if preempt > game.beatmap.max_preempt_ms {
        game.beatmap.max_preempt_ms = preempt
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
    CURSOR,
    TOP,
    PLATFORM, // note(isak): engine/debug overlays; always composited onto the real screen, on top of any post-processing
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
    
    IGNORED_HIT, // note(isak): intended for when we need a result that doesn't affect score
    COMBO_BREAK, // note(isak): intended for scripted misses
}

// todo(isak): need to handle (min_result, max_result) somehow
Judgement :: struct {
    result: Judgement_Type,
    time: f64,
}

Notosu_Map :: struct {
    lua_entry_point: string,
    bg_pipeline_name: string,
    double_mouse: bool,
    use_backbuffer: bool, // note(isak): route the whole frame into the "backbuffer" render target so a post pass can sample it
    fixed_update_rate_hz: f64, // note(isak): on_fixed_update / scheduled-event tick rate; <= 0 means the default

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
        sample_set: Skin_Sample_Set,
    
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
    bookmarks_ms: []f64, // note(isak): [Editor] Bookmarks, ascending music-time ms
}


osu_on_init :: proc() {
    game.time_rate = 1.0
    game.mode = .EDITOR

    game_sounds_clear()
    ui_init_timeline(&game.ui_timeline)

    game.input.keys = game.user_config.keys
}

osu_on_update :: proc(dt: f64) {
    game.dt = dt

    window_set_resizable(game.mode != .PLAY)

    if game.mode != .PLAY {
        updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
        if updated_systems[.OSU_FILE] || updated_systems[.NOTOSU_FILE] || updated_systems[.SCRIPTS] {
            beatmap_open(game.beatmap.map_reference, true)
        }
        if updated_systems[.SHADERS] {
            mapset_reinit_custom_shaders(game.active_mapset)
        }
    }
    
    // note(isak): game logic - map
    
    // todo(isak): this really handles a bunch of debug stuff too. fix up the modes and such
    #partial switch game.mode {
        case .PLAY:
            handle_play_input_events()

        case .EDITOR:
            handle_menu_input_events()
            handle_editor_input_events()

        case .MAIN_MENU: handle_menu_input_events()
    }
    handle_universal_input_events()
    
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

    // game render
    
    r_bind_layer_and_push_current_state(.HITOBJECTS, transform = game.playfield_transform)

    for i in followpoint_first_active(&game.beatmap, map_time)..<len(game.beatmap.followpoint_connections) {
        conn := &game.beatmap.followpoint_connections[i]
        if conn.visible_start_time_ms > map_time do break
        followpoint_emit(&game.beatmap, conn, map_time)
    }

    // note(isak): hitobjects render through render_drawable, which pushes its own state if necessary
    r_check_and_bind_layer(.HITOBJECTS)
    hitobjects_draw(visible_hobjs, map_time)
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.gameplay_expiring_gfx)
    
    r_bind_layer_and_push_current_state(.BACKGROUND, transform = game.playfield_transform)
    process_and_draw_expiring_gfx_refs(&game.beatmap.map_expiring_gfx)

    // note(isak): ui render
    // todo(isak): "screens" implementation for determining relevant UI components?
    
    r_bind_layer_and_push_current_state(.UI, 
        transform = game.playfield_transform,
        pipeline = { pipeline = builtin_pipeline_slot(.QUAD) })
    
    if game.mode == .EDITOR {
        playfield_border_draw :: proc(opacity: f32) {
            cs := game.beatmap.circle_radius_osupx
            pf_outline := Rect{
                -cs, -cs, PLAYFIELD_SIZE_OSUPX+2*cs, (PLAYFIELD_SIZE_OSUPX*3/4)+2*cs
            }
            r_draw_rect_outline(&window.renderer.quad_geometry, pf_outline, with_alpha(color_white, opacity), 2)
        }
        if game.user_config.playfield_border_opacity > 0 {
            playfield_border_draw(game.user_config.playfield_border_opacity)
        }
        
        timeline_update(&game.ui_timeline)
        render_timeline_clipspace(&game.ui_timeline)

        push_text(&window.renderer, "Edit mode",
            pos     = {window.rect.w / 2, uisc(30)},
            size    = uisc(24),
            color   = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Bottom)
    }
    if game.mode == .PLAY {
        hit_error_bar_draw_screenspace(&game.hit_error_bar)
        input_display_draw_screenspace()
    }

    if !lua_beatmap.hide_skin_cursor {
        r_bind_layer_and_push_current_state(.CURSOR, transform = window.screenspace_transform)

        cursor_trail_draw(&cursor_trails[0], mouse.pos)
        cursor_draw(mouse.pos, skin_texture(.CURSOR))
        if app.mouse_input_mode == .RAW_DOUBLE_MOUSE_INPUT {
            cursor_trail_draw(&cursor_trails[1], mouse_secondary.pos)
            cursor_draw(mouse_secondary.pos, skin_texture(.CURSOR))
        }
    }

    if game.input.rebinding_key != .NONE {
        r_check_and_bind_layer(.PLATFORM)
        r_push_transform(fullscreen_transform)
        r_draw_quad(&window.renderer.quad_geometry,
            vec2{0,0}, vec2{1,1},
            vec2{0,0}, vec2{1,1},
            with_alpha(color_black, 0.5))
            
        prompt := strings.concatenate({"Rebinding: ", rebindable_input_key_names[game.input.rebinding_key]}, context.temp_allocator)
        push_text(&window.renderer, prompt,
            pos = {window.rect.w / 2, window.rect.h / 2 - uisc(12)},
            size = uisc(16),
            color = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Middle)
        push_text(&window.renderer, "Press any key...",
            pos = {window.rect.w / 2, window.rect.h / 2 + uisc(12)},
            size = uisc(16),
            color = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Middle)
    }
}

hitobjects_draw :: proc(visible_hobjs: []Hitobject, map_time: f64) {
    // note(isak): objects overlapping in gameplay time ([start, end]) form clusters. visible_hobjs is
    // start-sorted, so clusters are contiguous runs split where an object starts after the running max
    // end time. within a cluster every object's gfx draws above every slider path (2B: heads landing
    // during a slider sit on its body); whole clusters stack by time, so a slider that ends before an
    // object begins keeps its path above that object. both strata draw earliest start on top, like osu.
    // chained overlaps merge clusters, which can lift an object's gfx above the path of a slider that
    // ended before it began - accepted approximation, the chain is concurrent through the middle object.
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
    }
}

cursor_draw :: proc(pos: vec2, tex_index: u32) {
    cursor_size := cursor_size_px()
    cursor_rect: Rect = { f32(pos.x), f32(pos.y), cursor_size, cursor_size }
    r_draw_layout_rect(&window.renderer.quad_geometry, cursor_rect, .CENTER, color_white,
        tex_index, f32(time_s_since_beginning_of_program()))
}

cursor_size_px :: proc() -> f32 {
    return 160 * (window.rect.h / 1440) * game.user_config.cursor_size_multiplier
}

// note(isak): mcosu's non-smooth trail timing (osu_cursor_trail_length / _spacing); the smooth
// interpolated variant for cursormiddle-less skins is not implemented yet
CURSOR_TRAIL_LENGTH_S  :: 0.17
CURSOR_TRAIL_SPACING_S :: 0.015
CURSOR_TRAIL_MAX_PARTS :: 32

Cursor_Trail_Part :: struct {
    pos: vec2,
    expires_at_s: f64,
}

Cursor_Trail :: struct {
    parts: [CURSOR_TRAIL_MAX_PARTS]Cursor_Trail_Part,
    head, count: int,
}

cursor_trails: [2]Cursor_Trail

// note(isak): spawns at most one part per SPACING interval; an unmoved cursor refreshes the newest
// part instead of stacking duplicates. parts fade linearly over LENGTH and are drawn oldest-first
// so fresher parts blend on top, all behind the cursor itself.
cursor_trail_draw :: proc(trail: ^Cursor_Trail, pos: vec2) {
    if window.skin_textures[.CURSOR_TRAIL].tex_id == 0 do return
    now := time_s_since_beginning_of_program()

    newest := &trail.parts[(trail.head + trail.count - 1) %% CURSOR_TRAIL_MAX_PARTS]
    spawned_at := newest.expires_at_s - CURSOR_TRAIL_LENGTH_S
    if trail.count == 0 || now > spawned_at + CURSOR_TRAIL_SPACING_S {
        if trail.count > 0 && newest.pos == pos {
            newest.expires_at_s = now + CURSOR_TRAIL_LENGTH_S
        } else {
            if trail.count == CURSOR_TRAIL_MAX_PARTS {
                trail.head = (trail.head + 1) %% CURSOR_TRAIL_MAX_PARTS
                trail.count -= 1
            }
            trail.parts[(trail.head + trail.count) %% CURSOR_TRAIL_MAX_PARTS] = {pos, now + CURSOR_TRAIL_LENGTH_S}
            trail.count += 1
        }
    }

    for trail.count > 0 && trail.parts[trail.head].expires_at_s <= now {
        trail.head = (trail.head + 1) %% CURSOR_TRAIL_MAX_PARTS
        trail.count -= 1
    }

    // note(isak): the cursor is drawn as a fixed-size square, so the trail derives its size from the
    // images' natural size ratio - a skin's small trail dot stays small relative to its cursor
    cursor_metrics := game.active_skin.elements[.CURSOR].metrics
    trail_metrics  := game.active_skin.elements[.CURSOR_TRAIL].metrics
    size := vec2{cursor_size_px(), cursor_size_px()}
    if cursor_metrics.x > 0 {
        size = trail_metrics * (cursor_size_px() / cursor_metrics.x)
    }

    for i in 0..<trail.count {
        part := trail.parts[(trail.head + i) %% CURSOR_TRAIL_MAX_PARTS]
        alpha := f32(clamp((part.expires_at_s - now) / CURSOR_TRAIL_LENGTH_S, 0, 1))
        if alpha <= 0 do continue
        r_draw_layout_rect(&window.renderer.quad_geometry,
            {part.pos.x, part.pos.y, size.x, size.y}, .CENTER,
            with_alpha(color_white, alpha), skin_texture(.CURSOR_TRAIL))
    }
}


//////////////////////////////////////////////////////
// note(isak): playfield math

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

// note(isak): the uniform pixels-per-osupx factor of the playfield transform (no rotation/translation).
// for converting sizes/extents between the two spaces; positions should round-trip the full transform.
playfield_px_per_osupx :: proc "contextless" () -> f32 {
    return playfield_base_scale * game.beatmap.playfield_scale * window.rect.h / PLAYFIELD_SIZE_OSUPX
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

rebindable_input_key_code :: proc(key: Rebindable_Input_Key) -> cstring {
    return sdl.GetScancodeName(game.input.keys[key])
}


handle_play_input_events :: proc() {
    if key_is_pressed(.ESCAPE) {
        game.mode = .EDITOR
        beatmap_open(game.beatmap.map_reference, true)
        beatmap_pause(&game.beatmap, true)
    }
    
    if key_is_pressed(.KP_PLUS) {
        game.user_config.universal_offset_ms += key_is_down(.LSHIFT) ? 1 : 5
    }
    if key_is_pressed(.KP_MINUS) {
        game.user_config.universal_offset_ms -= key_is_down(.LSHIFT) ? 1 : 5
    }
    
    if key_is_pressed(.PAGEUP) {
        game.time_rate *= 1.5
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    if key_is_pressed(.PAGEDOWN) {
        game.time_rate /= 1.5
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    
    game.input.k1.is_down = keyboard.buttons[game.input.keys[.K1]]
    game.input.k1.was_down = keyboard.buttons_prev_frame[game.input.keys[.K1]]
    game.input.k2.is_down = keyboard.buttons[game.input.keys[.K2]]
    game.input.k2.was_down = keyboard.buttons_prev_frame[game.input.keys[.K2]]
    if game.input.mouse_keys_enabled {
        game.input.m1 = mouse.buttons[.LEFT]
        game.input.m2 = mouse.buttons[.RIGHT]
    }
    
    old_mouse_pos := game.input.mouse_pos
    game.input.mouse_pos = screenspace_to_playfield_osupx(vec2{mouse.pos.x, mouse.pos.y})
    
    if lua_cares_about_event(.ON_CURSOR_MOVED) && game.input.mouse_pos != old_mouse_pos {
        lua_beatmap_on_cursor_moved(game.input.mouse_pos)
    }

    if app.mouse_input_mode == .RAW_DOUBLE_MOUSE_INPUT {
        game.input.mouse_secondary_pos = screenspace_to_playfield_osupx(vec2{mouse_secondary.pos.x, mouse_secondary.pos.y})
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

EDITOR_BEAT_DIVISOR :: 4

handle_editor_input_events :: proc() {
    if key_is_pressed(.ESCAPE) || key_is_pressed(.SPACE) {
        beatmap_pause(&game.beatmap, !game.paused)
    }
    if key_is_pressed(.F5) && !key_is_down(.LCTRL) {
        beatmap_play(&game.beatmap, !key_is_down(.LSHIFT))
    }
    if key_is_pressed(.R) {
        beatmap_open(game.beatmap.map_reference, !key_is_down(.LSHIFT))
    }
    
    if key_is_pressed(.HOME) {
        game.time_rate = 1
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    if key_is_pressed(.PAGEUP) {
        game.time_rate *= 1.5
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    if key_is_pressed(.PAGEDOWN) {
        game.time_rate /= 1.5
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    
    if key_is_pressed(.Z) {
        if len(game.beatmap.hitobjects) > 0 && 
           !f64_within(game.beatmap.music_time_ms, game.beatmap.hitobjects[0].start_time_ms, 3) {
            editor_seek(&game.beatmap, game.beatmap.hitobjects[0].start_time_ms)
        }
        else {
            editor_seek(&game.beatmap, game.beatmap.start_time_ms)
        }
    }

    if key_is_down(.LCTRL) {
        if key_is_pressed(.LEFT)  do editor_seek_bookmark(&game.beatmap, -1)
        if key_is_pressed(.RIGHT) do editor_seek_bookmark(&game.beatmap, +1)
    }

    if !app.ui_wants_mouse {
        steps := -int(math.round(mouse.scroll_delta)) // scroll up (>0) seeks backward
        if !key_is_down(.LCTRL) {
            if key_is_pressed(.LEFT)  do steps -= 1
            if key_is_pressed(.RIGHT) do steps += 1
        }

        if steps != 0 do editor_scrub_steps(&game.beatmap, steps)
    }
    
    game.input.mouse_pos = screenspace_to_playfield_osupx(vec2{mouse.pos.x, mouse.pos.y})
}

handle_menu_input_events :: proc() {
    if key_is_pressed(.S) {
        if key_is_down(.LCTRL) && key_is_down(.LSHIFT) && key_is_down(.LALT) {
            skin_reload(game.active_skin)
        }
    }
}

handle_universal_input_events :: proc() {
    if key_is_pressed(.F10) {
        game.input.mouse_keys_enabled = !game.input.mouse_keys_enabled
        notify_warn("mouse keys enabled" if game.input.mouse_keys_enabled else "mouse keys disabled")
    }
}



//////////////////////////////////////////////////////
// note(isak): managed game sound API

game_sound_play :: proc(
    s: ^Sample, loop: bool = false, volume: f32 = 1.0, category: Sound_Category = .HITSOUND, expires_at: f64 = math.F64_MAX
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
    sound_play(&sound, loop = loop, volume = volume, category = category)

    if expires_at != math.F64_MAX {
        base := cast(^Base_Sound)&sound
        base.expires_at_ms = beatmap_music_time_ms(&game.beatmap) + expires_at
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
    vmem.arena_free_all(&memory.arenas[.SOUND])
    slotmap.init(&game.sounds, allocator = memory.allocators[.SOUND], capacity = 128)
    _ = slotmap.insert(&game.sounds, null_sound)

    sb.init(&game.expiring_sounds, capacity = 64, allocator = memory.allocators[.SOUND])

    slider_sounds_clear_loop_handles()
}
