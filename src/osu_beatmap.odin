package inso

import "core:container/queue"
import "core:log"
import "core:math/linalg"
import "core:strings"

import sb "swap_buffer"
import "slotmap"


Beatmap :: struct {
    // -- game data fields
    
    map_reference: Map_Reference,
    
    music: Sound,
    music_time_ms: f64, // note(isak): for game logic, don't refer to this directly, use beatmap_time_ms() instead
    music_time_uninterpolated_ms: f64,
    length_ms: f64,
    start_time_ms: f64,
    
    current_timing_point_index_uninherited: int,
    current_timing_point_index_inherited: int,
    current_beat: int,
    current_kiai: bool,
    
    last_music_position_interpolation_check_time: f64,
    music_time_interpolating: bool,

    // note(isak): on_fixed_update + scheduled events step on this, decoupled from render framerate,
    // so forward catch-up and backward replay are deterministic
    fixed_update_dt_ms: f64,
    last_fixed_tick_ms: f64,

    // note(isak): editor auto-hit tracks the previous frame's time so it only hits objects whose start
    // crossed on the current frame; seeks snap it to the landing time so jumped-over objects are skipped.
    auto_last_hit_time_ms: f64,
    
    hitobjects: []Hitobject,
    slider_paths: []Slider_Path,
    score: Score_State,
    
    judgements: queue.Queue(Judgement),
    expiring_hitobjects: sb.Swap_Buffer(int), // note(isak): keeps track of visible objects until their expiry
    
    timing_windows: Timing_Window,
    
    visible_hitobject_state: Visibility_State,
    preempt_ms: f64,
    max_preempt_ms: f64, // note(isak): max of preempt_ms and all custom per-object preempts; used as iterator lookahead
    circle_radius_osupx: f32,
    
    playfield_translation_osupx: vec2,
    playfield_scale: f32,
    playfield_rotation_rad: f32,
    playfield_rotation_anchor_osupx: vec2,

    followpoint_connections: [dynamic]Followpoint_Connection,
    followpoint_cursor: int, // note(isak): first connection not yet expired, reset on seeking backwards

    phase_transitions: sb.Swap_Buffer(Phase_Transition),

    // -- gfx data fields

    bg_handle: Drawable_Handle,

    gameplay_expiring_gfx: sb.Swap_Buffer(Drawable_Handle),
    // note(isak): judgements live in their own buffer drawn after gameplay_expiring_gfx, so they
    // always stack above the hit pop animation regardless of same-frame insertion order
    judgement_expiring_gfx: sb.Swap_Buffer(Drawable_Handle),
    map_expiring_gfx: sb.Swap_Buffer(Drawable_Handle),

    drawables: slotmap.Slotmap(Drawable),
    next_drawable_id: int, // note(isak): rolling drawable id sequence
    
    // note(isak): drawables refer to an element, which in turn refer to a set of animations that determine
    // the final quad. the given element of an drawable can be overridden mid-map by scripts for effects
    elements: queue.Queue(Element),
    animations: queue.Queue(Animation),
    animation_lists: queue.Queue(Animation_List),
}

beatmap_on_init :: proc(map_reference: Map_Reference, beatmap: ^Beatmap, kept_music: Sound = nil) {
    beatmap^ = { map_reference = map_reference }
    _beatmap_allocate_internals(beatmap, kept_music)

    if game.active_inso_map.double_mouse {
        ok := mouse_enable_double_mouse_mode()
        if !ok {
            game.active_inso_map.double_mouse = false
        } else {
            game.input.mouse_keys_enabled = true
            notify_warn("mouse keys enabled" if game.input.mouse_keys_enabled else "mouse keys disabled")
        }
    }
    
    // map logic init

    for setting in Difficulty_Setting {
        map_difficulty_defaults[setting] = map_difficulty_setting(game.active_map, setting)^
    }
    mods_apply_to_map()

    beatmap.circle_radius_osupx = convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    beatmap.timing_windows = convert_overall_difficulty_to_timing_window(game.active_map.diff_overall_difficulty)
    beatmap.preempt_ms = convert_approach_rate_to_preempt_ms(game.active_map.diff_approach_rate)
    beatmap.max_preempt_ms = beatmap.preempt_ms

    beatmap_write_slider_instances(game.active_map)
    beatmap_apply_note_stacking(game.active_map, beatmap.preempt_ms, beatmap.circle_radius_osupx)
    
    beatmap.length_ms = sound_get_length_ms(&beatmap.music)
    beatmap.start_time_ms = min(beatmap_game_time_to_music_time(beatmap, -beatmap.preempt_ms), -500)
    beatmap.music_time_ms = beatmap.start_time_ms
    beatmap.auto_last_hit_time_ms = beatmap_music_time_ms(beatmap)

    fixed_update_rate_hz := game.active_inso_map.fixed_update_rate_hz
    if fixed_update_rate_hz <= 0 do fixed_update_rate_hz = 120
    beatmap.fixed_update_dt_ms = 1000.0 / fixed_update_rate_hz
    beatmap.last_fixed_tick_ms = beatmap_music_time_ms(beatmap)
    
    beatmap.hitobjects = game.active_map.hitobjects
    beatmap.slider_paths = game.active_map.slider_paths

    beatmap.playfield_scale = 1.0
    beatmap.playfield_translation_osupx = {}
    beatmap.playfield_rotation_rad = 0
    beatmap.playfield_rotation_anchor_osupx = {256, 192}

    // note(isak): rebuild eagerly - the script's on_init converts through this transform
    // (set_pos_px et al), and the lazy rebuild in osu_on_update comes too late for it
    game.playfield_transform = playfield_build_transform()
    game.playfield_dirty_transform = false

    for setting in Difficulty_Setting {
        difficulty_adjust_settings[setting] = map_difficulty_setting(game.active_map, setting)^
    }
    
    // map graphics init
    
    create_default_elements(&beatmap.elements, &beatmap.animations, &beatmap.animation_lists)
    mods_apply_to_graphics()

    beatmap.bg_handle = create_bg_drawable(game.active_map.bg_filename, game.active_inso_map.bg_pipeline_name)
    bg_dim_apply(game.user_config.bg_dim)

    if lua_cares_about_event(.ON_INIT) {
        lua_beatmap.in_init = true
        lua_call_beatmap_func(lua_beatmap_event_names[.ON_INIT])
        lua_beatmap.in_init = false
    }

    beatmap.followpoint_connections = make([dynamic]Followpoint_Connection, 0, len(beatmap.hitobjects), memory.allocators[.MAP_DATA])
    build_followpoint_connections(beatmap)
}

beatmap_on_update :: proc(beatmap: ^Beatmap) {
    if sound_is_finished(&beatmap.music) && game.mode != .PLAY {
        beatmap_open(beatmap.map_reference)
    }
    
    if beatmap.music_time_ms < 0 {
        beatmap.music_time_ms += game.dt * f64(game.paused ? 0 : game.time_rate)
        
        if beatmap.music_time_ms >= 0 {
            sound_resume(&beatmap.music)
            sound_set_position_ms(&beatmap.music, 0)
            
            beatmap.music_time_ms = beatmap_music_position_interpolated_ms(beatmap)
        } else {
            sound_pause(&beatmap.music)
        }
    } else if game.mode == .PLAY && sound_is_finished(&beatmap.music) && !beatmap.score.completed {
        beatmap.music_time_ms += game.dt * f64(game.paused ? 0 : game.time_rate)
    } else {
        // note(isak): map play time is determined by the sound library (and whether we were able to play music or not),
        // but song time interpolation is required because BASS reports play position in buffer size granularity
        beatmap.music_time_ms = beatmap_music_position_interpolated_ms(&game.beatmap)
    }
    
    has_new_timing_point := beatmap_update_current_timing_section(beatmap)

    if lua_cares_about_event(.ON_FIXED_UPDATE) {
        // note(isak): we only use the fixed clock update simulation if the lua script calls for it
        beatmap_advance_fixed_clock(beatmap)
    } else {
        // if not, we call scheduled events at full resolution
        lua_drain_scheduled_events(beatmap_music_time_ms(beatmap))
    }
    
    if lua_cares_about_event(.ON_UPDATE) {
        lua_beatmap_on_update(beatmap_music_time_ms(beatmap))
    }
    if has_new_timing_point && lua_cares_about_event(.ON_TIMING_CHANGE) {
        beatmap_check_timing_change(beatmap)
    }
    if lua_cares_about_event(.ON_BEAT) {
        beatmap_check_new_beat(beatmap)
    }
    if lua_cares_about_event(.ON_KIAI_CHANGE) {
        beatmap_check_kiai_change(beatmap)
    }
}

// note(isak): steps the fixed-rate simulation clock up to the current playhead, dispatching on_fixed_update and
// draining scheduled events on each whole tick rather than once per render frame
beatmap_advance_fixed_clock :: proc(beatmap: ^Beatmap) {
    dt := beatmap.fixed_update_dt_ms
    if dt <= 0 do return

    render_music_time_ms := beatmap.music_time_ms
    
    target_ms := beatmap_music_time_ms(beatmap)
    cares := lua_cares_about_event(.ON_FIXED_UPDATE)
    if !cares && len(lua_beatmap.scheduled_events) == 0 {
        beatmap.last_fixed_tick_ms = max(beatmap.last_fixed_tick_ms, target_ms)
        return
    }
    
    defer beatmap.music_time_ms = render_music_time_ms

    offset_ms := f64(game.user_config.universal_offset_ms)
    // note(isak): guard against freezing
    remaining_ticks := 1 << 20
    for beatmap.last_fixed_tick_ms + dt <= target_ms {
        beatmap.last_fixed_tick_ms += dt

        // note(isak): we overwrite music time for any lua side calls that read it
        beatmap.music_time_ms = beatmap.last_fixed_tick_ms - offset_ms
        lua_drain_scheduled_events(beatmap.last_fixed_tick_ms)
        if cares do lua_beatmap_on_fixed_update(beatmap.last_fixed_tick_ms)

        remaining_ticks -= 1
        if remaining_ticks == 0 {
            beatmap.last_fixed_tick_ms = target_ms
            break
        }
    }
}

beatmap_rewind_timeline :: proc(beatmap: ^Beatmap) {
    now_ms := beatmap_music_time_ms(beatmap)
    lua_rearm_scheduled_events(now_ms)
    beatmap.last_fixed_tick_ms = now_ms
}

// note(isak): the music stream deliberately survives teardown - beatmap_open owns its lifetime
// so an unchanged audio file can keep streaming across reloads
beatmap_on_destroy :: proc(beatmap: ^Beatmap) {
    lua_cleanup()
    game_sounds_clear()

    for &hobj in beatmap.hitobjects {
        hobj.gfx_handles = {}
        hobj.gfx_handles_backing = {}
        hobj.slider_state.gfx.ticks = {}
    }
    
    delete(beatmap.followpoint_connections)
    sb.destroy(&beatmap.phase_transitions)
    sb.destroy(&beatmap.map_expiring_gfx)
    sb.destroy(&beatmap.gameplay_expiring_gfx)
    sb.destroy(&beatmap.judgement_expiring_gfx)
    sb.destroy(&beatmap.expiring_hitobjects)
    slotmap.destroy(&beatmap.drawables)
    queue.destroy(&beatmap.judgements)
}

beatmap_open :: proc(ref: Map_Reference, keep_position: bool = false, reload_assets: bool = false) {
    ref, keep_position := ref, keep_position
    load_start := time_s_since_beginning_of_program()

    music_time_before_load: f64
    if keep_position {
        music_time_before_load = game.beatmap.music_time_ms
    }

    fast_reload_path := game.beatmap_active && !reload_assets &&
        ref.folder_path == game.beatmap.map_reference.folder_path &&
        ref.osu_filename == game.beatmap.map_reference.osu_filename

    music := game.beatmap.music
    old_audio_filepath: string
    if game.beatmap_active {
        old_audio_filepath = strings.clone(game.active_map.audio_filepath, context.temp_allocator)
        beatmap_on_destroy(&game.beatmap)
    }

    if fast_reload_path {
        // note(isak): in case fast reload fails, we try again with a complete reload
        fast_reload_path = mapset_reload_map_data(game.active_mapset)
    }
    if !fast_reload_path {
        if game.beatmap_active {
            cleanup_textures_for_rendering()
            mapset_free(game.active_mapset)
            game.beatmap_active = false
        }

        fallback_refs := [?]Map_Reference{
            ref,
            game.beatmap.map_reference,
            len(app.map_references) > 0 ? app.map_references[0] : Map_Reference{},
        }
        opened: bool
        try_loop: for try_ref, i in fallback_refs {
            if try_ref.folder_path == "" do continue
            for earlier_ref in fallback_refs[:i] {
                if try_ref == earlier_ref do continue try_loop
            }

            game.active_mapset, opened = mapset_open_for_editing(try_ref.folder_path, try_ref.osu_filename)
            if opened {
                keep_position &&= try_ref == ref
                ref = try_ref
                break
            }
            notify_error("beatmap: couldn't open '%s%s'", try_ref.folder_path, try_ref.osu_filename)
            mapset_free(game.active_mapset)
        }
        if !opened {
            log.panic("beatmap_open :: no loadable beatmap found")
        }
        game.active_map = &game.active_mapset.osu_map
        game.active_inso_map = &game.active_mapset.inso_map

        prepare_textures_for_rendering()

        if game.active_inso_map.use_backbuffer {
            fbo_clear(&window.framebuffers[.BACKBUFFER])
        }
    }

    if old_audio_filepath != {} && game.active_map.audio_filepath != old_audio_filepath {
        sound_destroy(&music)
        music = nil
    }

    beatmap_on_init(ref, &game.beatmap, music)
    sound_set_speed(&game.beatmap.music, game.time_rate)
    game.beatmap_active = true
    window.transparent = false

    notify_info("%sloaded beatmap in %.3vs", "re" if fast_reload_path else "", time_s_since_beginning_of_program() - load_start)

    if keep_position {
        if music_time_before_load >= 0 {
            beatmap_seek(&game.beatmap, music_time_before_load)
        } else {
            game.beatmap.music_time_ms = music_time_before_load
        }
        if !game.paused {
            sound_resume(&game.beatmap.music)
        }
    }
    
    // --@temp waiting on menu mode ui
    for r, i in app.map_references {
        if r.folder_path == ref.folder_path && r.osu_filename == ref.osu_filename {
            app.map_dropdown.selected = i
            break
        }
    }
    // --
}

_beatmap_allocate_internals :: proc(beatmap: ^Beatmap, kept_music: Sound = nil) {
    if kept_music != nil {
        beatmap.music = kept_music
        sound_pause(&beatmap.music)
        sound_set_position_ms(&beatmap.music, 0)
    } else {
        ok: bool
        beatmap.music, ok = sound_stream_init(game.active_map.audio_filepath, prescan = true)
        if ok {
            sound_play(&beatmap.music, start_paused = true, loop = true, category = .MUSIC)
        } else {
            log.error("tried to open map sound file, but failed:", game.active_map.audio_filepath)
        }
    }

    if game.active_inso_map.lua_entry_point != "" {
        lua_create_beatmap_script_context(game.active_inso_map.lua_entry_point)
    }
    
    beatmap.next_drawable_id = 1
    queue.init(&beatmap.elements, 1024, memory.allocators[.MAP_DATA])
    queue.append(&beatmap.elements, null_element)
    queue.init(&beatmap.animations, 1024, memory.allocators[.MAP_DATA])
    queue.init(&beatmap.animation_lists, 256, memory.allocators[.MAP_DATA])
    queue.append(&beatmap.animation_lists, Animation_List{})
    
    sb.init(&beatmap.phase_transitions, 256, memory.allocators[.DRAWABLES])

    sb.init(&beatmap.gameplay_expiring_gfx, 8192, memory.allocators[.DRAWABLES])
    sb.init(&beatmap.judgement_expiring_gfx, 1024, memory.allocators[.DRAWABLES])
    sb.init(&beatmap.map_expiring_gfx, 8192, memory.allocators[.DRAWABLES])
    slotmap.init(&beatmap.drawables, 8192, memory.allocators[.DRAWABLES])
    _ = slotmap.insert(&beatmap.drawables, null_drawable)
    
    queue.init(&beatmap.judgements, 8192, memory.allocators[.JUDGEMENTS])
    queue.append(&beatmap.judgements, null_judgement)
    hit_error_bar_reset(&game.hit_error_bar)
    sb.init(&beatmap.expiring_hitobjects, 256, memory.allocators[.MAP_DATA])
}

beatmap_seek :: proc(beatmap: ^Beatmap, pos: f64) {
    sound_set_position_ms(&game.beatmap.music, pos)
    beatmap.music_time_ms = beatmap_music_position_interpolated_ms(beatmap)
    beatmap.auto_last_hit_time_ms = beatmap_music_time_ms(beatmap)
}

// note(isak): rewinds the time-based visibility/expiry state. useful for seeking.
// the visible-set window, the expiring lists and pending phase transitions are dropped, gameplay effect gfx
// are freed, and every touched object has its transient state reset.
beatmap_reset_object_state :: proc(beatmap: ^Beatmap) {
    beatmap.visible_hitobject_state = {}
    sb.reset(&beatmap.expiring_hitobjects)
    sb.reset(&beatmap.phase_transitions)

    for handle in beatmap.gameplay_expiring_gfx.current {
        slotmap.remove(&beatmap.drawables, handle)
    }
    sb.reset(&beatmap.gameplay_expiring_gfx)

    for handle in beatmap.judgement_expiring_gfx.current {
        slotmap.remove(&beatmap.drawables, handle)
    }
    sb.reset(&beatmap.judgement_expiring_gfx)

    // note(isak): followpoints are immediate-mode (no drawables to rewind), but the forward-only cursor
    // must rewind to the start so it can re-scan toward the seek target
    beatmap.followpoint_cursor = 0

    for &hobj in beatmap.hitobjects {
        if hobj.phase != .NONE || hobj.flags & {.VISIBLE, .HIT, .EXPIRED} != {} {
            hitobject_reset_transient(&hobj)
        }
    }

    // note(isak): every judgement_index was just zeroed, so the old entries are unreachable -
    // truncate back to the null sentinel and re-judge from scratch
    queue.clear(&beatmap.judgements)
    queue.append(&beatmap.judgements, null_judgement)
    beatmap.score = {}
}

beatmap_music_time_ms :: proc(beatmap: ^Beatmap) -> f64 {
    return beatmap.music_time_ms + f64(game.user_config.universal_offset_ms) // + beatmap.local_offset_ms
}

beatmap_game_time_to_music_time :: proc(beatmap: ^Beatmap, game_time: f64) -> f64 {
    return game_time - f64(game.user_config.universal_offset_ms) // - beatmap.local_offset_ms
}


// note(isak): the audio library reports play position in buffer-sized steps, so we extrapolate a smooth
// playhead from the frame clock and let the reported position pull it back into line.
// ported from InterpolatingFramedClock in lazer, thanks peppy

MUSIC_TIME_DRIFT_HALF_LIFE_MS :: 50.0

// note(isak): two 60fps frames. past this the extrapolation is worse than the raw reading
MUSIC_TIME_ALLOWABLE_ERROR_MS :: 1000.0 / 60 * 2

beatmap_music_position_interpolated_ms :: proc(beatmap: ^Beatmap) -> (result: f64) {
    // note(isak): no output device right now (see audio_handle_device_change); position queries
    // report 0, so freeze time instead. recovery lands in the allowable-error branch below
    if !audio.ready {
        return beatmap.music_time_ms
    }

    last_time := beatmap.music_time_ms
    real_time := game.frame_clock_s
    song_time := sound_get_position_ms(&beatmap.music)

    elapsed_ms := (real_time - beatmap.last_music_position_interpolation_check_time) * 1000
    song_elapsed_ms := song_time - beatmap.music_time_uninterpolated_ms

    defer {
        beatmap.music_time_uninterpolated_ms = song_time
        beatmap.last_music_position_interpolation_check_time = real_time
    }

    if !sound_is_playing(&beatmap.music) {
        // note(isak): hold the extrapolated playhead while stopped, so pausing doesn't snap back to the
        // reported position. a seek moves the source even while stopped, and that we do follow
        if song_elapsed_ms == 0 {
            return last_time
        }
        beatmap.music_time_interpolating = false
        return song_time
    }

    time_rate := f64(game.time_rate)

    if beatmap.music_time_interpolating {
        result = damp_continuously(last_time + elapsed_ms * time_rate, song_time,
            MUSIC_TIME_DRIFT_HALF_LIFE_MS, elapsed_ms)

        if abs(song_time - result) > MUSIC_TIME_ALLOWABLE_ERROR_MS * time_rate {
            result = song_time
            beatmap.music_time_interpolating = false
        }
    } else {
        // note(isak): the frame the source starts or lands a seek reports a position there's nothing to
        // extrapolate from yet, so take it as-is and only resume once it's moving again
        result = song_time
        beatmap.music_time_interpolating = song_elapsed_ms != 0
    }

    // note(isak): prevent a backwards seek when syncing to the reported position
    if song_elapsed_ms >= 0 {
        result = max(last_time, result)
    }

    return result
}

// note(isak): scans from the cached earliest visible object to the earliest unstarted object.
// assumes the start times of objects are sorted, but doesn't require end times to be.
// a pathological case might be a 2B element that stretches from the beginning of the map to the end,
// which would result in a slice that contains up to every object in the map
beatmap_get_visible_hitobjects :: proc(beatmap: ^Beatmap, map_time: f64) -> (result: []Hitobject) {
    state := &beatmap.visible_hitobject_state
    updated_from_index := state.earliest_i

    hitobjects := game.beatmap.hitobjects
    if len(hitobjects) > 0 {
        looking_for_finished_objects := true
        count_until_next_unstarted_hobj: int
        includes_final_index := 1

        for &hobj, i in hitobjects[state.earliest_i:] {
            count_until_next_unstarted_hobj = i
            if map_time < hitobject_visible_start_time(&hobj) {
                includes_final_index = 0
                break
            }
            if looking_for_finished_objects {
                if hitobject_visible_end_time(&hobj) < map_time {
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

// note(isak): the cached visible range widened to cover the endpoints of every active followpoint
// connection
// todo(isak): @speed - scans every connection each call, same as the followpoint render pass.
beatmap_visible_incl_followpoints_bounds :: proc(beatmap: ^Beatmap, map_time: f64) -> (lo, hi: int) {
    state := beatmap.visible_hitobject_state
    lo, hi = state.earliest_i, state.latest_i

    for i in followpoint_first_active(beatmap, map_time)..<len(beatmap.followpoint_connections) {
        conn := beatmap.followpoint_connections[i]
        if conn.visible_start_time_ms > map_time do break
        lo = min(lo, conn.from_index)
        hi = max(hi, conn.to_index + 1)
    }

    lo = max(lo, 0)
    hi = min(hi, len(beatmap.hitobjects))
    return
}

beatmap_play :: proc(beatmap: ^Beatmap, keep_position: bool) {
    game.mode = .PLAY
    beatmap_open(beatmap.map_reference, keep_position)
    beatmap_pause(beatmap, false)
}

beatmap_pause :: proc(beatmap: ^Beatmap, pause: bool) {
    if game.paused != pause {
        if pause {
            sound_pause(&beatmap.music)
        } else {
            sound_resume(&beatmap.music)
        }
        game.paused = pause
        
        if lua_cares_about_event(.ON_PAUSE_CHANGE) {
            lua_beatmap_on_pause_change(pause)
        }
    }
}

beatmap_update_current_timing_section :: proc(beatmap: ^Beatmap) -> (bpm_changed: bool) {
    for timing_point in game.active_map.timing_points[beatmap.current_timing_point_index_inherited:] {
        if beatmap_music_time_ms(beatmap) < timing_point.time {
            break
        }
        if timing_point.type == .UNINHERITED {
            bpm_changed = beatmap.current_timing_point_index_uninherited != beatmap.current_timing_point_index_inherited
            beatmap.current_timing_point_index_uninherited = beatmap.current_timing_point_index_inherited
        }
        beatmap.current_timing_point_index_inherited += 1
    }
    // todo(isak): in a funny way, this causes eventual consistency for greenlines even when seeking backwards
    // but it seems strange to rely on it. redlines don't work, though
    beatmap.current_timing_point_index_inherited = max(beatmap.current_timing_point_index_inherited - 1, 0)
    return bpm_changed
}

beatmap_check_new_beat :: proc(beatmap: ^Beatmap) {
    timing_point := &game.active_map.timing_points[beatmap.current_timing_point_index_uninherited]
    game_time_ms := beatmap_music_time_ms(beatmap)
    if game_time_ms >= timing_point.time {
        beat := timing_point.starts_at_beat + 
            max(0, int((game_time_ms - timing_point.time) / timing_point.beat_length))
        if beat != beatmap.current_beat {
            lua_beatmap_on_beat(beat)
        }
        beatmap.current_beat = beat
    }
}

beatmap_check_kiai_change :: proc(beatmap: ^Beatmap) {
    kiai := game.active_map.timing_points[beatmap.current_timing_point_index_inherited].kiai
    if kiai != beatmap.current_kiai {
        beatmap.current_kiai = kiai
        lua_beatmap_on_kiai_change(kiai)
    }
}

beatmap_check_timing_change :: proc(beatmap: ^Beatmap) {
    timing_point := &game.active_map.timing_points[beatmap.current_timing_point_index_uninherited]
    game_time_ms := beatmap_music_time_ms(beatmap)
    beat := timing_point.starts_at_beat + int((game_time_ms - timing_point.time) / timing_point.beat_length)
    
    bpm := 60000 / max(timing_point.beat_length, 1)
    lua_beatmap_on_timing_change(beat, bpm)
}


beatmap_write_slider_instances :: proc(osu_map: ^Osu_Map) {
    for &path in osu_map.slider_paths {
        path.instance_count, path.first_instance_at =
            write_instances_from_path(&window.renderer.slider_instances, &path)
    }
}

OSU_STACK_DISTANCE_OSUPX :: f32(3)

/*
    note(isak): stable's note stacking, as ported in lazer's OsuBeatmapProcessor.applyStacking.
    runs at beatmap init after mods and slider instance baking (it needs the flipped positions
    and the baked slider endpoints), and before anything reads positions.

    todo(isak): instead of baking, we can probably expose stacking direction and distance to lua
    for some extra fun
*/
beatmap_apply_note_stacking :: proc(osu_map: ^Osu_Map, preempt_ms: f64, radius_osupx: f32) {
    hitobjects := osu_map.hitobjects
    if len(hitobjects) < 2 do return

    // note(isak): leniency 0 is not an early-out - stable still stacks exactly-simultaneous
    // coincident objects (2B maps), since the break below only fires on a positive time gap
    stack_threshold_ms := preempt_ms * osu_map.stack_leniency

    // for sliders, stacking compares against where the tail rests after all spans
    stack_end_pos :: proc(osu_map: ^Osu_Map, hobj: ^Hitobject) -> vec2 {
        if hobj.type != .SLIDER do return hobj.pos
        path := &osu_map.slider_paths[hobj.slider_path_index]
        return path.end_pos if hobj.slider_state.path_travel_count % 2 == 1 else path.pos
    }

    // note(isak): resolve stack counts for all hitobjects
    for i := len(hitobjects) - 1; i > 0; i -= 1 {
        hobj_i := &hitobjects[i]
        if hobj_i.stack_count != 0 || hobj_i.type == .SPINNER do continue

        n := i
        switch hobj_i.type {
        case .CIRCLE:
            for n -= 1; n >= 0; n -= 1 {
                hobj_n := &hitobjects[n]
                if hobj_n.type == .SPINNER do continue
                if hobj_i.start_time_ms - hobj_n.end_time_ms > stack_threshold_ms do break

                // a circle chain landing on a slider tail stacks under it instead; the chain
                // built so far is shifted down and the slider restarts as a new stack base
                if hobj_n.type == .SLIDER &&
                   linalg.distance(stack_end_pos(osu_map, hobj_n), hobj_i.pos) < OSU_STACK_DISTANCE_OSUPX {
                    offset := hobj_i.stack_count - hobj_n.stack_count + 1
                    for j in n + 1 ..= i {
                        hobj_j := &hitobjects[j]
                        if linalg.distance(stack_end_pos(osu_map, hobj_n), hobj_j.pos) < OSU_STACK_DISTANCE_OSUPX {
                            hobj_j.stack_count -= offset
                        }
                    }
                    break
                }

                if linalg.distance(hobj_n.pos, hobj_i.pos) < OSU_STACK_DISTANCE_OSUPX {
                    hobj_n.stack_count = hobj_i.stack_count + 1
                    hobj_i = hobj_n
                }
            }
        case .SLIDER:
            for n -= 1; n >= 0; n -= 1 {
                hobj_n := &hitobjects[n]
                if hobj_n.type == .SPINNER do continue
                if hobj_i.start_time_ms - hobj_n.start_time_ms > stack_threshold_ms do break

                if linalg.distance(stack_end_pos(osu_map, hobj_n), hobj_i.pos) < OSU_STACK_DISTANCE_OSUPX {
                    hobj_n.stack_count = hobj_i.stack_count + 1
                    hobj_i = hobj_n
                }
            }
        case .SPINNER, .NONE:
        }
    }

    // note(isak): bake stack position into every hitobject
    offset_per_stack := radius_osupx / 10
    for &hobj in hitobjects {
        if hobj.stack_count == 0 do continue
        offset := vec2{-offset_per_stack, -offset_per_stack} * f32(hobj.stack_count)

        hobj.pos += offset
        if hobj.type != .SLIDER do continue

        path := &osu_map.slider_paths[hobj.slider_path_index]
        path.pos        += offset
        path.end_pos    += offset
        path.bounds_min += offset
        path.bounds_max += offset
        for &node in path.nodes {
            node += offset
        }
        instances := window.renderer.slider_instances.data[path.first_instance_at:][:path.instance_count]
        for &instance_pos in instances {
            instance_pos += offset
        }
    }
}
