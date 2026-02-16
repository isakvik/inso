package notosu

import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import q "core:container/queue"
import "core:log"
import "core:strings"


Beatmap :: struct {
    music: Sound,
    music_time_ms: f64,
    music_time_uninterpolated_ms: f64,
    length_ms: f64,
    start_time_ms: f64,
    
    last_music_position_interpolation_check_time: f64,
    last_accurate_music_position_set_time: f64,
    
    hit_objects: []Hit_Object,
    slider_paths: []Slider_Path,
    
    visible_hit_object_state: Visibility_State,
    preempt_ms: f64,
    circle_radius_osupx: f32,

    map_gfx_refs: []slotmap.Handle,
}

beatmap_on_init :: proc(beatmap: ^Beatmap) {
    beatmap_load(beatmap)
    
    // map logic init
    
    beatmap.circle_radius_osupx = convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    beatmap.preempt_ms = convert_approach_rate_to_preempt_ms(game.active_map.diff_approach_rate)
    
    beatmap.length_ms = sound_get_length_ms(&beatmap.music)
    beatmap.start_time_ms = -beatmap.preempt_ms
    beatmap.music_time_ms = beatmap.start_time_ms
    
    beatmap.hit_objects = game.active_map.hit_objects
    beatmap.slider_paths = game.active_map.slider_paths
    
    // map graphics init
    
    q.init(&game.elements, 1024, memory.allocs[.MAPSET])
    q.append(&game.elements, null_element)
    q.init(&game.animations, 1024, memory.allocs[.MAPSET])

    write_default_elements(&game.elements, &game.animations)
    
    rb.init(&game.gfx_handles, 8192, memory.allocs[.ENTITIES])
    game.gfx_handles.length = cap(game.gfx_handles.data)
    
    q.init(&game.map_gfx_refs, 1024, memory.allocs[.ENTITIES])
    
    sb.init(&game.temp_gfx_refs, 8192)
    slotmap.init(&game.entities, 8192)
    _ = slotmap.insert(&game.entities, null_entity)
    
    // todo(isak): opinionated entity pushing; needs to be rewritten to take scriptable objects and skin metrics
    // into account
    write_default_entities_from_map(game.active_map)
    
    bg_handle := test_bg_entity(game.active_map.bg_filename)
    q.append(&game.map_gfx_refs, bg_handle)
}

beatmap_on_update :: proc(beatmap: ^Beatmap) {
    beatmap.map_gfx_refs = game.map_gfx_refs.data[:game.map_gfx_refs.len]
    
}

beatmap_on_destroy :: proc(beatmap: ^Beatmap) {
    sound_destroy(&beatmap.music)
    
    for &hobj in beatmap.hit_objects {
        hobj.gfx_handles = {}
    }
    
    q.destroy(&game.map_gfx_refs)
    rb.destroy(&game.gfx_handles)
    sb.destroy(&game.temp_gfx_refs)
    slotmap.destroy(&game.entities)
}

beatmap_load :: proc(beatmap: ^Beatmap) {
    music_path := strings.concatenate({game.active_mapset.folder_path, "/", game.active_map.audio_filename}, context.temp_allocator)
    
    ok: bool
    beatmap.music, ok = sound_stream_init(music_path)
    if ok {
        sound_play(&beatmap.music, start_paused = true, loop = true)
    } else {
        log.error("tried to open map sound file, but failed:", music_path)
    }
}

beatmap_reload :: proc(beatmap: ^Beatmap) {
    beatmap_on_destroy(beatmap)
    
    game.mode = .PLAY
    beatmap.visible_hit_object_state = {}
    
    game.active_mapset = mapset_free_and_reload(game.active_mapset)
    game.active_map = &game.active_mapset.osu_map
    beatmap_on_init(beatmap)
}


// note(isak): this function tries to minimize the discrepancy between the audio library's reported music position and
// the running real time clock, pretty much exactly as implemented before me in McOsu.
//
// i can't help but feel like there's a simpler solution because even on a good setup it's routinely "off" by a 
// millisecond, but maybe i just don't understand the problem that deeply?
beatmap_music_position_interpolated_ms :: proc(beatmap: ^Beatmap) -> (result: f64) {
    real_time := time_s_since_beginning_of_program()
    song_time := sound_get_position_ms(&beatmap.music)
    
    if sound_is_playing(&beatmap.music) {
        
        // note(isak): thanks peppy(c) for the magic numbers
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
    if pause {
        sound_pause(&beatmap.music)
    } else {
        sound_resume(&beatmap.music)
    }
    game.paused = pause
}
