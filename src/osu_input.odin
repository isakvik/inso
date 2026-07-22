package inso

import "core:math"
import "core:strings"
import sdl "vendor:sdl3"


// note(isak): walks this frame's raw input events in arrival order and judges every controller
// press at its own timestamp.
//
// raw keyboard reports autorepeat makes and INPUTSINK delivers input while unfocused, so
// game.input.raw_held tracks physical state through everything while presses only fire on real
// down-edges in a focused window
process_hittesting_event_walk :: proc(visible_hobjs: []Hitobject, map_time_now: f64) {
    tsc_to_ms := 1000.0 / f64(input_tsc_frequency())

    raw_cursor := app.mouse_input_mode == .RAW_SINGLE_MOUSE_INPUT ||
                  app.mouse_input_mode == .RAW_DOUBLE_MOUSE_INPUT
    cursor_screen := game.input.frame_start_mouse_screen

    held := &game.input.raw_held

    for &event in game.input.frame_events {
        // note(isak): while paused the music clock is frozen, so real-time offsets from it are
        // meaningless - everything judges at the frozen now, same as the fallback path
        press_time := map_time_now
        if !game.paused {
            age_ms := f64(game.frame_clock_tsc - event.tsc) * tsc_to_ms
            press_time = map_time_now - age_ms * f64(game.time_rate)
        }

        switch event.kind {
        case .MOUSE:
            if app.mouse_input_mode == .REBINDING_MOUSE_PRIMARY ||
               app.mouse_input_mode == .REBINDING_MOUSE_SECONDARY {
                continue // the click belongs to the rebind, not gameplay
            }
            if app.mouse_input_mode == .RAW_DOUBLE_MOUSE_INPUT && event.device != mouse.device_handle {
                continue // only the primary mouse aims and presses
            }

            if raw_cursor {
                cursor_screen = raw_cursor_integrate(cursor_screen, &event)
            }

            m1_press, m2_press: bool
            if event.button_flags & INPUT_M1_DOWN != 0 && !held.m1 {
                held.m1 = true
                m1_press = game.input.mouse_keys_enabled && !held.k1
            }
            if event.button_flags & INPUT_M1_UP != 0 do held.m1 = false
            if event.button_flags & INPUT_M2_DOWN != 0 && !held.m2 {
                held.m2 = true
                m2_press = game.input.mouse_keys_enabled && !held.k2
            }
            if event.button_flags & INPUT_M2_UP != 0 do held.m2 = false

            if (m1_press || m2_press) && window.focused {
                cursor := screenspace_to_playfield_osupx(cursor_screen) if raw_cursor else game.input.mouse_pos
                if m1_press do check_controller_press(visible_hobjs, press_time, cursor)
                if m2_press do check_controller_press(visible_hobjs, press_time, cursor)
            }

        case .KEY:
            key_press: bool
            if event.scancode == game.input.keys[.K1] {
                if !event.key_is_down {
                    held.k1 = false
                } else if !held.k1 {
                    held.k1 = true
                    key_press = !(game.input.mouse_keys_enabled && held.m1)
                }
            } else if event.scancode == game.input.keys[.K2] {
                if !event.key_is_down {
                    held.k2 = false
                } else if !held.k2 {
                    held.k2 = true
                    key_press = !(game.input.mouse_keys_enabled && held.m2)
                }
            }

            if key_press && window.focused {
                cursor := screenspace_to_playfield_osupx(cursor_screen) if raw_cursor else game.input.mouse_pos
                check_controller_press(visible_hobjs, press_time, cursor)
            }
        }
    }
}

valid_controller_press :: proc() -> bool {
    return game.input.available_presses > 0
}

consume_controller_press :: proc() {
    game.input.available_presses -= 1
}

// returns whether key_num (1 or 2) was freshly pressed this frame, applying mouse_keys exclusion
controller_key_pressed :: proc(key_num: int) -> bool {
    if key_num == 1 {
        if game.input.mouse_keys_enabled {
            return button_is_pressed(game.input.k1) && !button_is_down(game.input.m1) ||
                   button_is_pressed(game.input.m1) && !button_is_down(game.input.k1)
        }
        return button_is_pressed(game.input.k1)
    } else {
        if game.input.mouse_keys_enabled {
            return button_is_pressed(game.input.k2) && !button_is_down(game.input.m2) ||
                   button_is_pressed(game.input.m2) && !button_is_down(game.input.k2)
        }
        return button_is_pressed(game.input.k2)
    }
}

// returns whether key_num (1 or 2) is currently held
controller_key_down :: proc(key_num: int) -> bool {
    if key_num == 1 {
        return button_is_down(game.input.k1) || button_is_down(game.input.m1)
    } else {
        return button_is_down(game.input.k2) || button_is_down(game.input.m2)
    }
}

// returns which key (1 or 2) was freshly pressed this frame, 0 if neither
pressed_controller_key :: proc() -> int {
    if controller_key_pressed(1) do return 1
    if controller_key_pressed(2) do return 2
    return 0
}

//////////////////////////////////////////////////////
// NOTE(yokes): in-game button input api

button_is_down :: proc "c" (button: Button_State) -> bool {
    return button.is_down
}

button_is_pressed :: proc "c" (button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

button_is_released :: proc "c" (button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

key_is_down :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code]
}

key_is_pressed :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code] && !keyboard.buttons_prev_frame[code]
}

key_is_released :: proc "c" (code: sdl.Scancode) -> bool {
    return !keyboard.buttons[code] && keyboard.buttons_prev_frame[code]
}


//////////////////////////////////////////////////////
// note(isak): per-mode input handlers

rebindable_input_key_code :: proc(key: Rebindable_Input_Key) -> cstring {
    return sdl.GetScancodeName(game.input.keys[key])
}


handle_play_input_events :: proc() {
    if key_is_pressed(.ESCAPE) && !game.tournament_client {
        game_switch_mode(.EDITOR, beatmap_music_time_ms(&game.beatmap))
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
        seek_time := 0 if key_is_down(.LSHIFT) else beatmap_music_time_ms(&game.beatmap)
        game_switch_mode(.PLAY, seek_time)
    }
    if key_is_pressed(.R) {
        beatmap_open(game.beatmap.map_reference, keep_position = true, reload_assets = !key_is_down(.LSHIFT))
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
           !f64_within(beatmap_music_time_ms(&game.beatmap), game.beatmap.hitobjects[0].start_time_ms, 3) {
            editor_seek(&game.beatmap, game.beatmap.hitobjects[0].start_time_ms)
        }
        else {
            editor_seek(&game.beatmap, game.beatmap.start_time_ms)
        }
    }

    if key_is_down(.LCTRL) {
        if key_is_pressed(.LEFT)  do editor_seek_bookmark(&game.beatmap, -1)
        if key_is_pressed(.RIGHT) do editor_seek_bookmark(&game.beatmap, +1)
        if key_is_pressed(.O)     do file_dialog_open_osu()
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
            skin_path := strings.clone(game.active_skin.path, context.temp_allocator)
            skin_rebind(skin_path)
        }
    }
}

handle_universal_input_events :: proc() {
    if key_is_pressed(.F10) {
        game.input.mouse_keys_enabled = !game.input.mouse_keys_enabled
        game.user_config.mouse_keys_enabled = game.input.mouse_keys_enabled
        notify_warn("mouse keys enabled" if game.input.mouse_keys_enabled else "mouse keys disabled")
    }
}
