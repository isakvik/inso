package notosu

import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import "core:container/queue"
import "core:log"
import "core:strings"


Beatmap :: struct {
    // -- game data fields
    
    music: Sound,
    music_time_ms: f64, // note(isak): for game logic, don't refer to this directly, use beatmap_time_ms() instead
    music_time_uninterpolated_ms: f64,
    length_ms: f64,
    start_time_ms: f64,
    
    current_timing_point_index_uninherited: int,
    current_timing_point_index_inherited: int,
    current_beat: int,
    
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

beatmap_on_init :: proc(beatmap: ^Beatmap) {
    beatmap^ = {}
    beatmap_load(beatmap)
    
    // map logic init
    
    beatmap.circle_radius_osupx = convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    beatmap.preempt_ms = convert_approach_rate_to_preempt_ms(game.active_map.diff_approach_rate)
    beatmap.timing_windows = convert_overall_difficulty_to_timing_window(game.active_map.diff_overall_difficulty)
    
    beatmap.length_ms = sound_get_length_ms(&beatmap.music)
    beatmap.start_time_ms = -beatmap.preempt_ms
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
    
    //-- @temp
    // todo(isak): opinionated drawable pushing; needs to be rewritten to take scriptable objects and skin metrics
    // into account
    write_default_drawables_from_map(game.active_map)
    bg_handle := test_bg_drawable(game.active_map.bg_filename, "wave")
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
        }
    } else {
        // note(isak): map play time is determined by the sound library (and whether we were able to play music or not), 
        // but song time interpolation is required because BASS reports play position in buffer size granularity
        beatmap.music_time_ms = beatmap_music_position_interpolated_ms(&game.beatmap)
    }
    
    has_new_timing_point := beatmap_update_current_timing_section(beatmap)
    
    if lua_cares_about_event(.ON_UPDATE) {
        lua_beatmap_on_update(beatmap.music_time_ms)
    }
    if has_new_timing_point && lua_cares_about_event(.ON_TIMING_CHANGE) {
        beatmap_check_timing_change(beatmap)
    }
    if lua_cares_about_event(.ON_BEAT) {
        beatmap_check_new_beat(beatmap)
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
    beatmap.music, ok = sound_stream_init(game.active_map.audio_filepath)
    if ok {
        sound_play(&beatmap.music, start_paused = true, loop = true)
    } else {
        log.error("tried to open map sound file, but failed:", game.active_map.audio_filepath)
    }
    
    lua_create_beatmap_script_context(game.active_notosu_map.lua_entry_point)
}

beatmap_reload :: proc(beatmap: ^Beatmap, keep_song_position: bool = false) {
    music_time_before_load, time_before_load_ms: f64
    if keep_song_position {
        if game.beatmap.music_time_ms < 0 {
            music_time_before_load = game.beatmap.music_time_ms
        } else {
            music_time_before_load = sound_get_position_ms(&game.beatmap.music)
        }
        time_before_load_ms = current_time_ms()
    } 
    
    beatmap_on_destroy(beatmap)
    
    game.mode = .PLAY
    beatmap.visible_hitobject_state = {}
    
    game.active_mapset = mapset_free_and_reload(game.active_mapset)
    game.active_map = &game.active_mapset.osu_map
    game.active_notosu_map = &game.active_mapset.notosu_map
    beatmap_on_init(beatmap)
    
    if keep_song_position {
        if !game.paused do music_time_before_load += current_time_ms() - time_before_load_ms
        beatmap_seek(beatmap, music_time_before_load)        
        if !game.paused do sound_resume(&game.beatmap.music)
    }
}

beatmap_seek :: proc(beatmap: ^Beatmap, pos: f64) {
    game.beatmap.music_time_ms = beatmap_game_time_to_music_time(beatmap, pos)
    sound_set_position_ms(&game.beatmap.music, pos)
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
    
    //fmt.println("song_time", song_time)
    //fmt.println("  result", result)
    //fmt.println("  delta", result - song_time)
    
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

beatmap_check_timing_change :: proc(beatmap: ^Beatmap) {
    timing_point := &game.active_map.timing_points[beatmap.current_timing_point_index_uninherited]
    game_time_ms := beatmap_music_time_ms(beatmap)
    beat := timing_point.starts_at_beat + int((game_time_ms - timing_point.time) / timing_point.beat_length)
    
    bpm := 60000 / max(timing_point.beat_length, 1)
    lua_beatmap_on_timing_change(beat, bpm)
}
