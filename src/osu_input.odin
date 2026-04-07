package notosu

import sdl "vendor:sdl3"


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
        return button_is_down(game.input.k1) || game.input.mouse_keys_enabled && button_is_down(game.input.m1)
    } else {
        return button_is_down(game.input.k2) || game.input.mouse_keys_enabled && button_is_down(game.input.m2)
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
