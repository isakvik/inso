package notosu

import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import q "core:container/queue"
import "core:log"
import "core:strings"


Beatmap :: struct {
    // -- game data fields
    
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
    elements: q.Queue(Element),
    animations: q.Queue(Animation),
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
    
    beatmap.next_drawable_id = 1
    q.init(&beatmap.elements, 1024, memory.allocators[.MAPSET])
    q.append(&beatmap.elements, null_element)
    q.init(&beatmap.animations, 1024, memory.allocators[.MAPSET])

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
    
    lua_beatmap_on_init()
}

beatmap_on_update :: proc(beatmap: ^Beatmap) {
    if sound_is_finished(&game.beatmap.music) {
        beatmap_reload(&game.beatmap)
        sound_set_position_ms(&game.beatmap.music, 0)
    }
    
    if game.beatmap.music_time_ms < 0 {
        game.beatmap.music_time_ms += game.dt * f64(game.paused ? 0 : game.time_rate)
        
        if game.beatmap.music_time_ms >= 0 {
            sound_resume(&game.beatmap.music)
            sound_set_position_ms(&game.beatmap.music, 0)
            
            game.beatmap.music_time_ms = beatmap_music_position_interpolated_ms(&game.beatmap)
        }
    } else {
        // note(isak): map play time is determined by the sound library (and whether we were able to play music or not), 
        // but song time interpolation is required because BASS reports play position in buffer size granularity
        game.beatmap.music_time_ms = beatmap_music_position_interpolated_ms(&game.beatmap)
    }
    
    lua_beatmap_on_update(game.beatmap.music_time_ms)
}

beatmap_on_destroy :: proc(beatmap: ^Beatmap) {
    lua_cleanup()
    sound_destroy(&beatmap.music)
    
    for &hobj in beatmap.hit_objects {
        hobj.gfx_handles = {}
    }
    
    rb.destroy(&beatmap.persistent_gfx)
    sb.destroy(&beatmap.gameplay_expiring_gfx)
    slotmap.destroy(&beatmap.drawables)
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

beatmap_reload :: proc(beatmap: ^Beatmap) {
    beatmap_on_destroy(beatmap)
    
    game.mode = .PLAY
    beatmap.visible_hit_object_state = {}
    
    game.active_mapset = mapset_free_and_reload(game.active_mapset)
    game.active_map = &game.active_mapset.osu_map
    game.active_notosu_map = &game.active_mapset.notosu_map
    beatmap_on_init(beatmap)
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
    if pause {
        sound_pause(&beatmap.music)
    } else {
        sound_resume(&beatmap.music)
    }
    game.paused = pause
}
