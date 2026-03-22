package notosu

import "core:thread"
import "core:math/linalg"
import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import "core:container/queue"
import "core:fmt"
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
    circle_radius_osupx: f32,
    
    // -- gfx data fields
    
    // todo(isak): if drawables are added sequentially, this allows for an acceleration structure where 
    // we keep track of the timespan of active drawables and thus don't have to iterate the entire set
    persistent_gfx: rb.Ring_Buffer(Drawable_Handle),
    
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
    game_clear_sounds()

    beatmap^ = { map_reference = map_reference }
    beatmap_load(beatmap)
    
    // map logic init
    
    beatmap.circle_radius_osupx = convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    beatmap.preempt_ms = convert_approach_rate_to_preempt_ms(game.active_map.diff_approach_rate)
    beatmap.timing_windows = convert_overall_difficulty_to_timing_window(game.active_map.diff_overall_difficulty)
    
    beatmap.length_ms = sound_get_length_ms(&beatmap.music)
    beatmap.start_time_ms = beatmap_game_time_to_music_time(beatmap, -beatmap.preempt_ms)
    beatmap.music_time_ms = beatmap.start_time_ms
    
    beatmap.hitobjects = game.active_map.hitobjects
    beatmap.slider_paths = game.active_map.slider_paths
    
    queue.init(&beatmap.judgements, 8192, memory.allocators[.JUDGEMENTS])
    queue.append(&beatmap.judgements, null_judgement)
    sb.init(&beatmap.expiring_hitobjects, 256, memory.allocators[.MAPSET])
    
    // map graphics init
    
    beatmap.next_drawable_id = 1
    queue.init(&beatmap.elements, 1024, memory.allocators[.MAPSET])
    queue.append(&beatmap.elements, null_element)
    queue.init(&beatmap.animations, 1024, memory.allocators[.MAPSET])

    write_default_elements(&beatmap.elements, &beatmap.animations)
    
    rb.init(&beatmap.persistent_gfx, 8192, memory.allocators[.DRAWABLES])
    beatmap.persistent_gfx.len = cap(beatmap.persistent_gfx.data)
    
    sb.init(&beatmap.gameplay_expiring_gfx, 8192, memory.allocators[.DRAWABLES])
    sb.init(&beatmap.map_expiring_gfx, 8192, memory.allocators[.DRAWABLES])
    slotmap.init(&beatmap.drawables, 8192, memory.allocators[.DRAWABLES])
    _ = slotmap.insert(&beatmap.drawables, null_drawable)
    
    //-- @temp @beta
    // todo(isak): opinionated drawable pushing; needs to be rewritten to take scriptable objects and skin metrics
    // into account
    TEST_write_default_drawables_from_map(game.active_map)
    bg_handle := TEST_bg_drawable(game.active_map.bg_filename, "wave")
    //--
    
    if lua_cares_about_event(.ON_INIT) {
        lua_call_beatmap_func("on_init")
    }
}

beatmap_on_update :: proc(beatmap: ^Beatmap) {
    if sound_is_finished(&beatmap.music) {
        beatmap_reload(beatmap)
        sound_set_position_ms(&beatmap.music, 0)
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
    
    rb.destroy(&beatmap.persistent_gfx)
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
        sound_play(&beatmap.music, start_paused = true, loop = true)
    } else {
        log.error("tried to open map sound file, but failed:", game.active_map.audio_filepath)
    }
    
    if game.active_notosu_map.lua_entry_point != "" {
        lua_create_beatmap_script_context(game.active_notosu_map.lua_entry_point)
    }
}

beatmap_reload :: proc(beatmap: ^Beatmap, keep_song_position: bool = false) {
    music_time_before_load, engine_time_before_load: f64
    if keep_song_position {
        music_time_before_load = game.beatmap.music_time_ms
        engine_time_before_load = current_time_ms()
    } 
    
    beatmap_on_destroy(beatmap)
    
    mapset_path := mapset_free(game.active_mapset)
    ok: bool
    game.active_mapset, ok = mapset_open_for_editing(beatmap.map_reference.folder_path, beatmap.map_reference.osu_filename)
    assert(ok)
    
    game.active_map = &game.active_mapset.osu_map
    game.active_notosu_map = &game.active_mapset.notosu_map
    beatmap_on_init(beatmap.map_reference, beatmap)
    sound_set_speed(&game.beatmap.music, game.time_rate)
    
    if keep_song_position {
        if music_time_before_load >= 0 {
            beatmap_seek(beatmap, music_time_before_load)        
        } else {
            game.beatmap.music_time_ms = music_time_before_load
        }
        
        if !game.paused {
            sound_resume(&game.beatmap.music)
        } 
    }
}

osu_switch_map :: proc(ref: Map_Reference) {
    beatmap_on_destroy(&game.beatmap)
    cleanup_textures_for_rendering()

    mapset_path := mapset_free(game.active_mapset)
    ok: bool
    game.active_map_ref = ref
    for r, i in app.map_references {
        if r.folder_path == ref.folder_path && r.osu_filename == ref.osu_filename {
            window.map_dropdown.selected = i
            break
        }
    }
    game.active_mapset, ok = mapset_open_for_editing(ref.folder_path, ref.osu_filename)
    assert(ok)
    
    game.active_map = &game.active_mapset.osu_map
    game.active_notosu_map = &game.active_mapset.notosu_map

    prepare_textures_for_rendering()
    beatmap_on_init(ref, &game.beatmap)
}

beatmap_seek :: proc(beatmap: ^Beatmap, pos: f64) {
    sound_set_position_ms(&game.beatmap.music, pos)
    beatmap.music_time_ms = beatmap_music_position_interpolated_ms(beatmap)
}

beatmap_music_time_ms :: proc(beatmap: ^Beatmap) -> f64 {
    return beatmap.music_time_ms + game.universal_offset_ms // + beatmap.local_offset_ms
}

beatmap_game_time_to_music_time :: proc(beatmap: ^Beatmap, game_time: f64) -> f64 {
    return game_time - game.universal_offset_ms // - beatmap.local_offset_ms
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
        case .MISS: el_type = .JUDGEMENT_MISS
        case .OK:   el_type = .JUDGEMENT_OK
        case .GOOD: el_type = .JUDGEMENT_GOOD
        case .MARVELOUS:    el_type = .JUDGEMENT_MARVELOUS
        case .SLIDER_SMALL_SCOREPOINT:  el_type = .LIGHTING
        case .SLIDER_LARGE_SCOREPOINT:  el_type = .LIGHTING

        case .NONE, .COMBO_BREAK, .IGNORED_HIT:
            return
        }

        pos := hitobject_pos(hobj)
        if hobj.type == .SLIDER {
            path := &game.beatmap.slider_paths[hobj.slider_path_index]
            pos = path.pos if hobj.slider_state.path_travel_count % 2 == 0 else path.end_pos
        }

        //--@temp do the osu thing w metrics instead of spinny square
        drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
            flags = {.ACTIVE},
            element = builtin_element_slot(el_type),
            layer = .HITOBJECTS,
            pos = pos,
            size = game.beatmap.circle_radius_osupx,
            anchor = .CENTER,
            color = color_white,
            
            angle_vel = 360.0,
            
            start_time_ms = judgement.time,
            end_time_ms = judgement.time + 600
        })
        //--
        fmt.println("judgement", fmt.enum_value_to_string(judgement.result))
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
            expired = hitcircle_process(hobj, map_time)
        }
        
        if !expired {
            sb.append_next(expiring_hitobjects, hobj_index)
        }
    }
    sb.swap(expiring_hitobjects)
}

hitcircle_process :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    end_time := hitobject_visible_end_time(hobj)
    if end_time < map_time {
        judgement_new(hobj, .MISS, end_time - hobj.end_time_ms)
        judgement_new_drawable(hobj)
        hobj.flags &~= {.VISIBLE}
        hobj.flags |= {.EXPIRED}
        expired = true
    }
    return expired
}   

slider_process :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    state := &hobj.slider_state

    // note(isak): one-time head miss check once the miss window has passed without a click
    if !state.head_checked && map_time > hobj.start_time_ms + game.beatmap.timing_windows.miss {
        state.head_checked = true
    }

    if map_time >= hobj.start_time_ms {
        slider_update(hobj, map_time)
    }

    if map_time > hobj.end_time_ms {
        slider_expire(hobj)
        expired = true
    }
    return expired
}


slider_ball_pos_at :: proc(hobj: ^Hitobject, map_time: f64) -> vec2 {
    path := &game.beatmap.slider_paths[hobj.slider_path_index]

    duration := hobj.end_time_ms - hobj.start_time_ms
    elapsed  := clamp(map_time - hobj.start_time_ms, 0, duration)

    // t_passes goes from 0 to slider_repeats over the full duration
    repeat_count := hobj.slider_state.path_travel_count
    t_passes  := (elapsed / duration) * f64(repeat_count)
    pass_idx  := min(int(t_passes), repeat_count - 1)
    pass_frac := t_passes - f64(pass_idx)

    // even passes go forward (0->1), odd passes go backward (1->0)
    t_on_path := pass_frac if pass_idx % 2 == 0 else 1.0 - pass_frac

    return linalg.lerp(path.pos, path.end_pos, vec2{f32(t_on_path), f32(t_on_path)})
}


SLIDER_FOLLOW_CIRCLE_RADIUS_MULT :: 2.4

slider_update :: proc(hobj: ^Hitobject, map_time: f64) {
    slider := &hobj.slider_state

    // todo(isak):
    // - tracking must take (valid) key presses into account
    // - tracking must take into account the 36ms magic ending 
    // - create tick judgements (and revise the num_ticks_hit or whatever part of judgement)
    // - draw slider ticks and repeats
    
    ball_pos      := slider_ball_pos_at(hobj, map_time)
    follow_radius := game.beatmap.circle_radius_osupx * SLIDER_FOLLOW_CIRCLE_RADIUS_MULT

    // note(isak): if the head was hit and the ball is still within follow circle distance of the head, 
    // tracking activates regardless of cursor position. this is a contingency in the case of a late edgehit, 
    // which we handle the same way as lazer by not activating if the sliderball has moved the distance of the radius.
    
    // TODO(isak): this needs to be tested
    
    was_tracking  := slider.tracking
    head_snap     := slider.head_hit && point_in_circle(hobj.pos, ball_pos, follow_radius)
    slider.tracking = point_in_circle(game.input.mouse_pos, ball_pos, follow_radius) || head_snap

    timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
    sample_set   := Skin_Sample_Set(timing_point.sample_set)

    if slider.tracking && !was_tracking {
        slider.slide_sound = 
            game_play_sound(&game.active_skin.hitsounds[sample_set][.SLIDERSLIDE], loop = true, volume = 0.5)
    } else if !slider.tracking && was_tracking {
        game_stop_sound(slider.slide_sound)
        slider.slide_sound = {}
    }

    slider_time_at := (map_time - hobj.start_time_ms) - f64(slider.hit_repeats_count) * slider.duration_ms
    if slider_time_at >= slider.duration_ms && slider.hit_repeats_count < (slider.path_travel_count - 1) {
        slider.hit_repeats_count += 1
        if slider.tracking {
            judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
            slider.hit_judgement_count += 1
            sample_play(&game.active_skin.hitsounds[sample_set][.HITNORMAL])
        }
    }

    // this tick stuff is broken
    for slider.next_expected_judgement_at_ms <= map_time && slider.next_expected_judgement_at_ms < hobj.end_time_ms {
        if slider.tracking {
            judgement_new(hobj, .SLIDER_SMALL_SCOREPOINT, 0)
            slider.hit_judgement_count += 1
            sample_play(&game.active_skin.hitsounds[sample_set][.SLIDERTICK])
        }
        slider.next_expected_judgement_at_ms += slider.tick_interval_ms
    }
}

slider_expire :: proc(hobj: ^Hitobject) {
    
    slider := &hobj.slider_state
    log.info("slider expired", slider.slide_sound.generation, slider.slide_sound.index)

    if slider.tracking {
        judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
        slider.hit_judgement_count += 1
    }

    game_stop_sound(slider.slide_sound)
    slider.slide_sound = {}

    all_hit := slider.hit_judgement_count + (1 if slider.head_hit else 0)
    total   := max(slider.tick_count + slider.path_travel_count + 1, 1) // include tail

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
    hobj.flags &~= {.VISIBLE}
    hobj.flags |= {.EXPIRED}
}
