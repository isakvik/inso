package inso

import sdl "vendor:sdl3"


// note(isak): walks this frame's raw input events in arrival order and judges every controller
// press at its own timestamp, instead of collapsing the frame into available_presses. motion
// events re-integrate the primary cursor alongside, so each press is hit-tested at the position
// the cursor actually had when it happened - not where it ended up at frame end.
//
// raw keyboard reports autorepeat makes and INPUTSINK delivers input while unfocused, so
// game.input.raw_held tracks physical state through everything while presses only fire on real
// down-edges in a focused window
process_hittesting_event_walk :: proc(visible_hobjs: []Hitobject, map_time_now: f64) {
    tsc_now := input_tsc_now()
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
            press_time = min(map_time_now, map_time_now - f64(tsc_now - event.tsc) * tsc_to_ms * f64(game.time_rate))
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

            // mirrors apply_raw_mouse_event so the integrated position matches frame-end mouse.pos
            if raw_cursor && window.mouse_inside && !event.absolute_motion {
                cursor_screen.x += f32(event.motion_x) * game.user_config.cursor_sensitivity
                cursor_screen.y += f32(event.motion_y) * game.user_config.cursor_sensitivity
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
                if m1_press do resolve_press(visible_hobjs, press_time, cursor)
                if m2_press do resolve_press(visible_hobjs, press_time, cursor)
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
                resolve_press(visible_hobjs, press_time, cursor)
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
