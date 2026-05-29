package notosu

import "core:thread"
import "core:math/linalg"
import sb "swap_buffer"
import "slotmap"

import "core:container/queue"
import "core:fmt"
import "core:math"
import "core:log"
import "core:strings"


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
    last_accurate_music_position_set_time: f64,
    
    hitobjects: []Hitobject,
    slider_paths: []Slider_Path,
    
    judgements: queue.Queue(Judgement),
    expiring_hitobjects: sb.Swap_Buffer(int), // note(isak): keeps track of objects that have been visible at some point
    
    timing_windows: Timing_Window,
    
    visible_hitobject_state: Visibility_State,
    preempt_ms: f64,
    max_preempt_ms: f64, // note(isak): max of preempt_ms and all custom per-object preempts; used as iterator lookahead
    circle_radius_osupx: f32,
    
    playfield_translation_osupx: vec2,
    playfield_scale: f32,
    playfield_rotation_rad: f32,

    deferred_activations: [dynamic]Deferred_Activation,
    
    phase_transitions: sb.Swap_Buffer(Phase_Transition),

    // -- gfx data fields

    gameplay_expiring_gfx: sb.Swap_Buffer(Drawable_Handle),
    map_expiring_gfx: sb.Swap_Buffer(Drawable_Handle),
    
    drawables: slotmap.Slotmap(Drawable),
    next_drawable_id: int, // note(isak): rolling drawable id sequence
    
    // note(isak): drawables refer to an element, which in turn refer to a set of animations that determine
    // the final quad. the given element of an drawable can be overridden mid-map by scripts for effects
    elements: queue.Queue(Element),
    animations: queue.Queue(Animation),
}

beatmap_on_init :: proc(map_reference: Map_Reference, beatmap: ^Beatmap) {
    game_sounds_clear()

    beatmap^ = { map_reference = map_reference }
    beatmap_load(beatmap)

    if game.active_notosu_map.double_mouse {
        ok := mouse_enable_double_mouse_mode()
        if !ok {
            game.active_notosu_map.double_mouse = false
        }
    } else {
        mouse_disable_double_mouse_mode()
    }
    
    // map logic init
    
    beatmap.circle_radius_osupx = convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    beatmap.preempt_ms = convert_approach_rate_to_preempt_ms(game.active_map.diff_approach_rate)
    beatmap.timing_windows = convert_overall_difficulty_to_timing_window(game.active_map.diff_overall_difficulty)
    
    beatmap.length_ms = sound_get_length_ms(&beatmap.music)
    beatmap.start_time_ms = beatmap_game_time_to_music_time(beatmap, -beatmap.preempt_ms)
    beatmap.music_time_ms = beatmap.start_time_ms
    
    beatmap.hitobjects = game.active_map.hitobjects
    beatmap.slider_paths = game.active_map.slider_paths

    beatmap.playfield_scale = 1.0
    beatmap.playfield_translation_osupx = {}
    beatmap.playfield_rotation_rad = 0
    game.playfield_dirty_transform = true
    
    queue.init(&beatmap.judgements, 8192, memory.allocators[.JUDGEMENTS])
    queue.append(&beatmap.judgements, null_judgement)
    sb.init(&beatmap.expiring_hitobjects, 256, memory.allocators[.MAPSET])
    
    // map graphics init
    
    beatmap.next_drawable_id = 1
    queue.init(&beatmap.elements, 1024, memory.allocators[.MAPSET])
    queue.append(&beatmap.elements, null_element)
    queue.init(&beatmap.animations, 1024, memory.allocators[.MAPSET])

    create_default_elements(&beatmap.elements, &beatmap.animations)
    
    sb.init(&beatmap.phase_transitions, 256, memory.allocators[.DRAWABLES])

    sb.init(&beatmap.gameplay_expiring_gfx, 8192, memory.allocators[.DRAWABLES])
    sb.init(&beatmap.map_expiring_gfx, 8192, memory.allocators[.DRAWABLES])
    slotmap.init(&beatmap.drawables, 8192, memory.allocators[.DRAWABLES])
    _ = slotmap.insert(&beatmap.drawables, null_drawable)

    bg_handle := TEST_bg_drawable(game.active_map.bg_filename, game.active_notosu_map.bg_pipeline_name)
    
    if lua_cares_about_event(.ON_INIT) {
        lua_call_beatmap_func("on_init")
    }

    // note(isak): deferred activation list for objects with custom preempt (set by lua at init time).
    // these bypass the normal visible set iterator since per-object preempt breaks visibility ordering
    build_deferred_activations(beatmap)
}

beatmap_on_update :: proc(beatmap: ^Beatmap) {
    if sound_is_finished(&beatmap.music) {
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
    } else {
        // note(isak): map play time is determined by the sound library (and whether we were able to play music or not), 
        // but song time interpolation is required because BASS reports play position in buffer size granularity
        beatmap.music_time_ms = beatmap_music_position_interpolated_ms(&game.beatmap)
    }
    
    has_new_timing_point := beatmap_update_current_timing_section(beatmap)
    
    lua_drain_scheduled_events(beatmap_music_time_ms(beatmap))
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

beatmap_on_destroy :: proc(beatmap: ^Beatmap) {
    lua_cleanup()
    sound_destroy(&beatmap.music)
    
    for &hobj in beatmap.hitobjects {
        hobj.gfx_handles = {}
    }
    
    delete(beatmap.deferred_activations)
    sb.destroy(&beatmap.phase_transitions)
    sb.destroy(&beatmap.map_expiring_gfx)
    sb.destroy(&beatmap.gameplay_expiring_gfx)
    sb.destroy(&beatmap.expiring_hitobjects)
    slotmap.destroy(&beatmap.drawables)
    queue.destroy(&beatmap.judgements)
}

beatmap_load :: proc(beatmap: ^Beatmap) {
    ok: bool
    beatmap.music, ok = sound_stream_init(game.active_map.audio_filepath, prescan = true)
    if ok {
        sound_play(&beatmap.music, start_paused = true, loop = true, category = .MUSIC)
    } else {
        log.error("tried to open map sound file, but failed:", game.active_map.audio_filepath)
    }
    
    if game.active_notosu_map.lua_entry_point != "" {
        lua_create_beatmap_script_context(game.active_notosu_map.lua_entry_point)
    }
}

beatmap_open :: proc(ref: Map_Reference, keep_position: bool = false) {
    load_start := time_s_since_beginning_of_program()

    music_time_before_load: f64
    if keep_position {
        music_time_before_load = game.beatmap.music_time_ms
    }

    if game.beatmap_active {
        cleanup_textures_for_rendering()
        beatmap_on_destroy(&game.beatmap)
        mapset_free(game.active_mapset)
    }

    ok: bool
    game.active_mapset, ok = mapset_open_for_editing(ref.folder_path, ref.osu_filename)
    assert(ok)
    game.active_map = &game.active_mapset.osu_map
    game.active_notosu_map = &game.active_mapset.notosu_map

    prepare_textures_for_rendering()
    beatmap_on_init(ref, &game.beatmap)
    sound_set_speed(&game.beatmap.music, game.time_rate)
    game.beatmap_active = true

    notify_info("loaded beatmap in %.3vs", time_s_since_beginning_of_program() - load_start)

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

beatmap_seek :: proc(beatmap: ^Beatmap, pos: f64) {
    sound_set_position_ms(&game.beatmap.music, pos)
    beatmap.music_time_ms = beatmap_music_position_interpolated_ms(beatmap)
}

beatmap_music_time_ms :: proc(beatmap: ^Beatmap) -> f64 {
    return beatmap.music_time_ms + f64(game.user_config.universal_offset_ms) // + beatmap.local_offset_ms
}

beatmap_game_time_to_music_time :: proc(beatmap: ^Beatmap, game_time: f64) -> f64 {
    return game_time - f64(game.user_config.universal_offset_ms) // - beatmap.local_offset_ms
}


// note(isak): this function tries to minimize the discrepancy between the audio library's reported music position and
// the running real time clock, pretty much exactly as implemented before me in McOsu. 
// (it's not as much interpolation as it is a dynamic extrapolation of music time based on real time...)
//
// i can't help but feel like there's a simpler solution because even on a good setup it's routinely "off" by a 
// millisecond, but maybe i just don't understand the problem that deeply?
beatmap_music_position_interpolated_ms :: proc(beatmap: ^Beatmap) -> (result: f64) {
    real_time := time_s_since_beginning_of_program()
    song_time := sound_get_position_ms(&beatmap.music)
    
    if sound_is_playing(&beatmap.music) {
        
        // note(isak): thanks peppy(tm) for the magic numbers
        time_rate := f64(game.time_rate)
        interpolation_delta_ms := (real_time - beatmap.last_music_position_interpolation_check_time) * 1000 * time_rate
        interpolation_delta_limit: f64 = 
            (real_time - beatmap.last_accurate_music_position_set_time < 1.5 || game.time_rate < 1.0 ? 11 : 33)
        
        ip_pos_to_reach_ms := beatmap.music_time_ms + interpolation_delta_ms
        delta := ip_pos_to_reach_ms - song_time
        
        ip_pos_to_reach_ms -= delta / 8
        
        if abs(delta) > interpolation_delta_limit * 2 {
            // big time discrepancy, defer to song_time
            result = song_time
            
        } else if delta < -interpolation_delta_limit {
            // undershooting, try to catch up
            result = ip_pos_to_reach_ms + interpolation_delta_ms
            beatmap.last_accurate_music_position_set_time = real_time
        } else if delta < interpolation_delta_limit {
            // on pace
            result = ip_pos_to_reach_ms
        } else {
            // overshooting, slow down
            result = ip_pos_to_reach_ms - interpolation_delta_ms * 0.5
            beatmap.last_accurate_music_position_set_time = real_time
        }
        
    } else {
        // note(isak): no interpolation
        result = song_time
        beatmap.last_accurate_music_position_set_time = real_time
    }
    
    beatmap.music_time_uninterpolated_ms = song_time
    beatmap.last_music_position_interpolation_check_time = real_time
    
    return result
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


judgement_new :: proc(hobj: ^Hitobject, type: Judgement_Type, time_error_ms: f64) {
    time := beatmap_music_time_ms(&game.beatmap)
    hobj.judgement_index = int(game.beatmap.judgements.len)
    queue.append(&game.beatmap.judgements, Judgement{ type, time })
    
    if lua_cares_about_event(.ON_JUDGEMENT) {
        lua_beatmap_on_judgement(hobj.index, type, time_error_ms)
    }
}

judgement_new_drawable :: proc(hobj: ^Hitobject) {
    if hobj.judgement_index > 0 {
        judgement := queue.get(&game.beatmap.judgements, hobj.judgement_index)

        el_type: Element_Type
        switch judgement.result {
        case .MISS:      el_type = .JUDGEMENT_MISS
        case .OK:        el_type = .JUDGEMENT_OK
        case .GOOD:      el_type = .JUDGEMENT_GOOD
        case .MARVELOUS: el_type = .JUDGEMENT_MARVELOUS
        case .SLIDER_SMALL_SCOREPOINT:  el_type = .LIGHTING
        case .SLIDER_LARGE_SCOREPOINT:  el_type = .LIGHTING

        case .NONE, .COMBO_BREAK, .IGNORED_HIT, .SLIDER_SCOREPOINT_MISS:
            return
        }

        pos := hitobject_pos(hobj)
        if hobj.type == .SLIDER {
            path := &game.beatmap.slider_paths[hobj.slider_path_index]
            pos = path.pos if hobj.slider_state.path_travel_count % 2 == 0 else path.end_pos
        }

        cs := hitobject_radius_osupx(hobj)
        element_scale := (cs * 2) / game.active_skin.elements[.HITCIRCLE].metrics
        skin_el := skin_element_for_type_table[el_type]
        
        vel := judgement.result == .MISS ? vec2{0, 10} : vec2{0, 0}
        
        drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
            flags         = {.ACTIVE},
            element       = builtin_element_slot(el_type),
            layer         = .HITOBJECTS,
            pos           = pos,
            size          = element_scale * game.active_skin.elements[skin_el].metrics,
            anchor        = .CENTER,
            color         = color_white,
            
            vel           = vel,
            
            start_time_ms = judgement.time,
            end_time_ms   = judgement.time + 600,
        })
    }
    
}

build_deferred_activations :: proc(beatmap: ^Beatmap) {
    max_preempt := beatmap.preempt_ms
    count := 0
    for &hobj in beatmap.hitobjects {
        if hobj.custom_preempt_ms != 0 {
            count += 1
            if hobj.custom_preempt_ms > max_preempt do max_preempt = hobj.custom_preempt_ms
        }
    }
    beatmap.max_preempt_ms = max_preempt

    beatmap.deferred_activations = make([dynamic]Deferred_Activation, 0, count, memory.allocators[.MAPSET])
    for &hobj in beatmap.hitobjects {
        if hobj.custom_preempt_ms != 0 {
            append(&beatmap.deferred_activations, Deferred_Activation{hobj.index, hobj.start_time_ms - hobj.custom_preempt_ms})
            hobj.deferred_activation_index = len(beatmap.deferred_activations) // index+1
        }
    }
}

process_expiring_hitobjects :: proc(expiring_hitobjects: ^sb.Swap_Buffer(int)) {
    map_time := beatmap_music_time_ms(&game.beatmap)

    for hobj_index in expiring_hitobjects.current {
        hobj := &game.beatmap.hitobjects[hobj_index]

        if .EXPIRED in hobj.flags do continue
        
        expired: bool
        #partial switch hobj.type {
        case .SLIDER:
            expired = slider_process(hobj, map_time)
        case:
            expired = hitcircle_process_expiry(hobj, map_time)
        }
        
        if !expired {
            sb.append_next(expiring_hitobjects, hobj_index)
        }
    }
    sb.swap(expiring_hitobjects)
}

hitcircle_process_expiry :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    end_time := hobj.end_time_ms + game.beatmap.timing_windows.ok
    if end_time < map_time {
        judgement_new(hobj, .MISS, end_time - hobj.end_time_ms)
        judgement_new_drawable(hobj)
        hitobject_emit_phase_transition(hobj, .MISS)
        hobj.flags &~= {.VISIBLE}
        hobj.flags |= {.EXPIRED}
        expired = true
    }
    return expired
}


//////////////////////////////////////////////////////
// note(isak): slider logic core

SLIDER_FOLLOW_CIRCLE_RADIUS_MULT :: 2.4
SLIDER_TICK_AT_SLIDEREND_CHECK_LENIENCY_MS :: 3
SLIDER_END_LENIENCY_MS :: 36

slider_snake_factor :: proc(hobj: ^Hitobject) -> f64 {
    preempt_ms := hitobject_preempt_ms(hobj)
    snake_duration_ms := preempt_ms * (1.0/3.0)
    time_into_preempt  := beatmap_music_time_ms(&game.beatmap) - hobj.start_time_ms + preempt_ms
    return clamp(time_into_preempt / snake_duration_ms, 0, 1)
}

slider_process :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    slider := &hobj.slider_state

    // note(isak): one-time head miss check once the miss window has passed without a click
    if .HEAD_HIT in slider.flags ||
        map_time > hobj.start_time_ms + game.beatmap.timing_windows.miss {
        slider.flags |= {.HEAD_CHECKED}
    }

    if map_time >= hobj.start_time_ms {
        slider_update(hobj, map_time)
    }

    // note(isak): we gotta process results (and the contingency) before we let the slider expire
    if .HEAD_CHECKED in slider.flags && map_time > hobj.end_time_ms {
        slider_expire(hobj)
        expired = true
    }
    return expired
}

// note(isak): slider head click is recorded, final judgement is deferred to slider_expire
slider_on_click :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state
    slider.flags |= {.HEAD_HIT, .HEAD_CHECKED}
    slider.down_key = pressed_controller_key()
    
    timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
    sample_set := Skin_Sample_Set(timing_point.sample_set)
    if slider.slide_sound == {} {
        slider.slide_sound = 
            game_sound_play(&game.active_skin.hitsounds[sample_set][.SLIDERSLIDE], loop = true, volume = 0.5)
    }
}


slider_path_pos_at :: proc(hobj: ^Hitobject, map_time: f64) -> vec2 {
    path := &game.beatmap.slider_paths[hobj.slider_path_index]

    return calculate_curve_from_time(hobj, map_time, path)
}

slider_update :: proc(hobj: ^Hitobject, map_time: f64) {
    slider := &hobj.slider_state

    ball_pos      := slider_path_pos_at(hobj, map_time)
    follow_radius := hitobject_radius_osupx(hobj) * SLIDER_FOLLOW_CIRCLE_RADIUS_MULT

    // note(isak): if a specific key hit the head, the opposite key being freshly pressed frees tracking to any key
    if slider.down_key != 0 && controller_key_pressed(slider.down_key == 1 ? 2 : 1) {
        slider.down_key = 0
    }

    key_held := slider.down_key == 0 \
        ? controller_key_down(1) || controller_key_down(2) \
        : controller_key_down(slider.down_key)

    was_tracking  := .TRACKING in slider.flags
    is_tracking := point_in_circle(game.input.mouse_pos, ball_pos, follow_radius) && key_held
    if is_tracking do slider.flags |= {.TRACKING}
    else do slider.flags &= ~{.TRACKING}

    if is_tracking && map_time >= hobj.end_time_ms - SLIDER_END_LENIENCY_MS {
        slider.flags |= {.END_TRACKED}
    }

    timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
    sample_set := Skin_Sample_Set(timing_point.sample_set)
    slider_time_at := (map_time - hobj.start_time_ms)

    // note(isak): "contingency" check in the case of a late hit where ticks/repeats have passed before the end of the
    // timing window. we store them and process them in order once the timing window has passed.
    // handle the same way as lazer by not activating if the sliderball has moved the distance of the radius.
    if .HEAD_CHECKED in slider.flags && slider.contingency_window_scorepoint_count > 0 {
        if .HEAD_HIT in slider.flags {
            has_repeat: bool
            for i in 0..<slider.contingency_window_scorepoint_count {
                is_repeat := slider.contingency_window_scorepoints & {i} > {}
                judgement_new(hobj, is_repeat ? .SLIDER_LARGE_SCOREPOINT : .SLIDER_SMALL_SCOREPOINT, 0)
                slider.hit_judgement_count += 1
                has_repeat = has_repeat || is_repeat
            }
            sample_play(&game.active_skin.hitsounds[sample_set][has_repeat ? .HITNORMAL : .SLIDERTICK])
        } else {
            for i in 0..<slider.contingency_window_scorepoint_count {
                judgement_new(hobj, .SLIDER_SCOREPOINT_MISS, 0)
            }
        }
        slider.contingency_window_scorepoint_count = 0
        slider.contingency_window_scorepoints = {}
    }
    
    
    slider_has_next_path_judgement :: proc(hobj: ^Hitobject) -> bool {
        slider := &hobj.slider_state
        return slider.checked_repeats_count < slider.path_travel_count - 1 || 
            slider.checked_path_ticks_count < slider.tick_count
    }
    
    slider_is_path_judgement_due :: proc(hobj: ^Hitobject, map_time: f64) -> bool {
        slider := &hobj.slider_state
        slider_time_at := (map_time - hobj.start_time_ms)
        if slider_time_at >= f64(slider.checked_repeats_count + 1) * slider.duration_ms {
            return true
        }
        
        heading_back := slider.checked_repeats_count % 2 == 1
        first_tick_time := heading_back ? slider.duration_ms - slider.tick_interval_ms * f64(slider.tick_count) : slider.tick_interval_ms
        slider_path_time_at := slider_time_at - f64(slider.checked_repeats_count) * slider.duration_ms
        if slider_path_time_at >= first_tick_time + f64(slider.checked_path_ticks_count) * slider.tick_interval_ms {
            return true
        }
        return false
    }
    
    // note(isak): we process hit ticks in this loop, essentially "consuming" time by incrementing the checked counters
    // so that we can hit multiple ticks in the same frame if we're tracking. order of processing is important!
    for slider_has_next_path_judgement(hobj) && slider_is_path_judgement_due(hobj, map_time) {
        heading_back := slider.checked_repeats_count % 2 == 1
        first_tick_time := heading_back ? slider.duration_ms - slider.tick_interval_ms * f64(slider.tick_count) : slider.tick_interval_ms
        slider_path_time_at := slider_time_at - f64(slider.checked_repeats_count) * slider.duration_ms

        for slider.checked_path_ticks_count < slider.tick_count && slider_path_time_at >= first_tick_time + f64(slider.checked_path_ticks_count) * slider.tick_interval_ms {
            slider.checked_path_ticks_count += 1
            
            if is_tracking && .HEAD_CHECKED in slider.flags {
                judgement_new(hobj, .SLIDER_SMALL_SCOREPOINT, 0)
                slider.hit_judgement_count += 1
                // todo(isak): hitsound volume!!!!
                sample_play(&game.active_skin.hitsounds[sample_set][.SLIDERTICK])
            } else if .HEAD_CHECKED not_in slider.flags {
                if slider.contingency_window_scorepoint_count >= 64 {
                    // note(isak): what kind of insane tick rate would even trigger this?
                    log.warn("contingency window included more than 64 scorepoints!", slider.contingency_window_scorepoint_count)
                }
                slider.contingency_window_scorepoint_count += 1
            } else {
                judgement_new(hobj, .SLIDER_SCOREPOINT_MISS, 0)
            }
        }
        
        if slider_path_time_at >= slider.duration_ms && slider.checked_repeats_count < (slider.path_travel_count - 1) {
            slider.checked_repeats_count += 1
            slider.checked_path_ticks_count = 0
            
            if is_tracking && .HEAD_CHECKED in slider.flags  {
                judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
                slider.hit_judgement_count += 1
                // todo(isak): hitsound volume!! repeat hitsounds need to be parsed!!!
                sample_play(&game.active_skin.hitsounds[sample_set][.HITNORMAL])
            } else if .HEAD_CHECKED not_in slider.flags {
                if slider.contingency_window_scorepoint_count >= 64 {
                    log.warn("contingency window included more than 64 scorepoints!", slider.contingency_window_scorepoint_count)
                } else {
                    slider.contingency_window_scorepoints |= {slider.contingency_window_scorepoint_count}
                }
                slider.contingency_window_scorepoint_count += 1
            } else {
                judgement_new(hobj, .SLIDER_SCOREPOINT_MISS, 0)
            }
        }
    }
    
    if .HEAD_CHECKED in slider.flags && slider.slide_sound == {} && is_tracking && !was_tracking {
        // todo(isak): hitsound volume!! sliderwhistle!!
        slider.slide_sound = 
            game_sound_play(&game.active_skin.hitsounds[sample_set][.SLIDERSLIDE], loop = true, volume = 0.5)
    } else if !is_tracking && slider.slide_sound != {} {
        game_sound_stop(slider.slide_sound)
        slider.slide_sound = {}
    }
}

slider_expire :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state

    if .END_TRACKED in slider.flags {
        // todo(isak): hitsound volume!! end hitsounds need to be parsed!!!
        timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
        sample_set := Skin_Sample_Set(timing_point.sample_set)
        sample_play(&game.active_skin.hitsounds[sample_set][.HITNORMAL])
        judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
        slider.hit_judgement_count += 1
    }

    game_sound_stop(slider.slide_sound)
    slider.slide_sound = {}

    all_hit := slider.hit_judgement_count + (.HEAD_HIT in slider.flags ? 1 : 0)

    total_tick_count := slider.tick_count * slider.path_travel_count
    total   := max(total_tick_count + slider.path_travel_count + 1, 1) // include tail

    result: Judgement_Type
    ratio := f64(all_hit) / f64(total)
    switch {
    case ratio >= 1.0: result = .MARVELOUS
    case ratio >= 0.5: result = .GOOD
    case ratio > 0:    result = .OK
    case:              result = .MISS
    }

    judgement_new(hobj, result, 0)
    judgement_new_drawable(hobj)
    hitobject_emit_phase_transition(hobj, result == .MISS ? .MISS : .HIT)
    hobj.flags &~= {.VISIBLE}
    hobj.flags |= {.EXPIRED}
}
