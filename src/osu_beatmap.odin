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
    
    last_music_position_interpolation_check_time: f64,
    last_accurate_music_position_set_time: f64,
    
    hit_objects: []Hit_Object,
    visible_hit_object_state: Visibility_State,

    slider_paths: []Slider_Path,
    length_ms: f64,
    start_time_ms: f64,

    preempt_ms: f64,
    circle_radius_osupx: f32,
}

beatmap_on_init :: proc() {
    // map logic init
    
    game.beatmap.circle_radius_osupx = convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    game.beatmap.preempt_ms = convert_approach_rate_to_preempt_ms(game.active_map.diff_approach_rate)
    
    game.beatmap.length_ms = sound_get_length_ms(&game.beatmap.music)
    game.beatmap.start_time_ms = -game.beatmap.preempt_ms
    game.beatmap.music_time_ms = game.beatmap.start_time_ms
    
    game.beatmap.hit_objects = game.active_map.hit_objects
    game.beatmap.slider_paths = game.active_map.slider_paths
    
    // map graphics init
    
    q.init(&game.elements, 1024, memory.allocs[.MAPSET])
    q.append(&game.elements, null_element)
    q.init(&game.animations, 1024, memory.allocs[.MAPSET])

    write_default_elements(&game.elements, &game.animations)
    
    rb.init(&game.gfx_handles, 8192, memory.allocs[.ENTITIES])
    game.gfx_handles.length = cap(game.gfx_handles.data)
    
    sb.init(&game.temp_gfx_refs, 8192)
    slotmap.init(&game.entities, 8192)
    _ = slotmap.insert(&game.entities, null_entity)
    
    // todo(isak): opinionated entity pushing; needs to be rewritten to take scriptable objects and skin metrics
    // into account
    write_default_entities_from_map(game.active_map)
}

beatmap_on_destroy :: proc() {
    sound_destroy(&game.beatmap.music)
    
    for &hobj in game.beatmap.hit_objects {
        hobj.gfx_handles = {}
    }
    
    rb.destroy(&game.gfx_handles)
    sb.destroy(&game.temp_gfx_refs)
    slotmap.destroy(&game.entities)
}

beatmap_load :: proc() {
    music_path := strings.concatenate({game.active_mapset.folder_path, "/", game.active_map.audio_filename}, context.temp_allocator)
    
    ok: bool
    game.beatmap.music, ok = sound_stream_init(music_path)
    if ok {
        sound_play(&game.beatmap.music, start_paused = true, loop = true)
    } else {
        log.error("tried to open map sound file, but failed:", music_path)
    }
}

beatmap_reload :: proc() {
    beatmap_on_destroy()
    
    game.mode = .PLAY
    game.beatmap.visible_hit_object_state = {}
    
    game.active_mapset = mapset_free_and_reload(game.active_mapset)
    game.active_map = &game.active_mapset.osu_map
    beatmap_load()
    beatmap_on_init()
}


// note(isak): this function tries to minimize the discrepancy between the audio library's reported music position and
// the running real time clock, pretty much exactly as implemented before me in McOsu.
//
// i can't help but feel like there's a simpler solution because even on a good setup it's routinely "off" by a 
// millisecond, but maybe i just don't understand the problem that deeply?
get_music_position_interpolated_ms :: proc() -> (result: f64) {
    real_time := time_s_since_beginning_of_program()
    song_time := sound_get_position_ms(&game.beatmap.music)
    
    if sound_is_playing(&game.beatmap.music) {
        
        // note(isak): thanks peppy(c) for the magic numbers
        interpolation_delta_ms := (real_time - game.beatmap.last_music_position_interpolation_check_time) * 1000 * game.time_rate
        interpolation_delta_limit: f64 = 
            (real_time - game.beatmap.last_accurate_music_position_set_time < 1.5 || game.time_rate < 1.0 ? 11 : 33)
        
        ip_pos_to_reach_ms := game.beatmap.music_time_ms + interpolation_delta_ms
        delta := ip_pos_to_reach_ms - song_time
        
        ip_pos_to_reach_ms -= delta / 8
        
        if abs(delta) > interpolation_delta_limit * 2 {
            // big time discrepancy, defer to song_time
            result = song_time
        } else if delta < -interpolation_delta_limit {
            // undershooting, try to catch up
            result = ip_pos_to_reach_ms + interpolation_delta_ms
            game.beatmap.last_accurate_music_position_set_time = real_time
        } else if delta < interpolation_delta_limit {
            // on pace
            result = ip_pos_to_reach_ms
        } else {
            // overshooting, slow down
            result = ip_pos_to_reach_ms - interpolation_delta_ms * 0.5
            game.beatmap.last_accurate_music_position_set_time = real_time
        }
        
    } else {
        // note(isak): no interpolation
        result = song_time
        game.beatmap.last_accurate_music_position_set_time = real_time
    }
    
    //fmt.println("song_time", song_time)
    //fmt.println("  result", result)
    //fmt.println("  delta", result - song_time)
    
    game.beatmap.music_time_uninterpolated_ms = song_time
    game.beatmap.last_music_position_interpolation_check_time = real_time
    
    return result
}

beatmap_pause :: proc(pause: bool) {
    if pause {
        sound_pause(&game.beatmap.music)
    } else {
        sound_resume(&game.beatmap.music)
    }
    game.paused = pause
}

handle_play_input_events :: proc() {
    if is_key_pressed(.ESCAPE) || is_key_pressed(.SPACE) {
        beatmap_pause(!game.paused)
    }
    if is_key_pressed(.F10) {
        osu_controller.mouse_keys_enabled = !osu_controller.mouse_keys_enabled
    }
    
    osu_controller.k1.is_down = keyboard.buttons[osu_controller.k1_key]
    osu_controller.k1.was_down = keyboard.buttons_prev_frame[osu_controller.k1_key]
    osu_controller.k2.is_down = keyboard.buttons[osu_controller.k2_key]
    osu_controller.k2.was_down = keyboard.buttons_prev_frame[osu_controller.k2_key]
    osu_controller.m1 = mouse.buttons[.LEFT]
    osu_controller.m2 = mouse.buttons[.RIGHT]
}

// todo(isak): game logic. needs testing
valid_key_press :: proc() -> bool {
    if osu_controller.mouse_keys_enabled {
        if is_pressed(osu_controller.k1) && !is_down(osu_controller.m1) ||
            is_pressed(osu_controller.k2) && !is_down(osu_controller.m2) {
            return true
        }
        
        return is_pressed(osu_controller.m1) && !is_down(osu_controller.k1) || 
            is_pressed(osu_controller.m2) && !is_down(osu_controller.k2)
    } else {
        return is_pressed(osu_controller.k1) || is_pressed(osu_controller.k2)
    }
}
