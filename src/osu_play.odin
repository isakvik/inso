package notosu



Beatmap :: struct {
    music: Sound,
    music_time_ms: f64,
    
    hit_objects: []Hit_Object,
    visible_hit_object_state: Visibility_State,

    slider_paths: []Slider_Path,
    length_ms: f64,
    start_time_ms: f64,

    preempt_ms: f64,
    circle_radius_osupx: f32,
}


get_music_position_interpolated_ms :: proc() -> (result: f64) {
    
    real_time := time_since_beginning_of_program()
    
    song_time := sound_get_position_ms(&game.beatmap.music)
    
    return song_time
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
