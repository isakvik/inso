package notosu

import "core:fmt"

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

handle_play_input_events :: proc() {
    if is_key_pressed(.ESCAPE) || is_key_pressed(.SPACE) {
        game.paused = !game.paused
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
