package notosu

import "core:fmt"
import "core:log"
import "core:mem"
import os "core:os"
import "core:sys/windows"
import "core:path/filepath"

import sdl "vendor:sdl3"

Map_Reference :: struct {
    folder_path:  string,
    osu_filename: string, // note(isak): which .osu file to load within the folder
    hash: u64,
}

app: struct {
    base_dir: string,
    logger: log.Logger,

    debug_display_frame_profiler:  bool,
    debug_display_memory_profiler: bool,
    debug_display_fontatlas:       bool, // todo(isak): never written to
    debug_display_slider_bounds:   bool,
    debug_display_textures:        bool,
    debug_display_game_cursor:     bool,

    map_references:      [dynamic]Map_Reference,
    map_reference_names: [dynamic]cstring, // note(isak): parallel for imgui

    external_map_open: bool,
    
    skin_references:      [dynamic]string,
    skin_reference_names: [dynamic]cstring, // note(isak): parallel for imgui
    
    ui_enabled: bool,
    ui_wants_mouse: bool,
    map_dropdown: Imgui_Dropdown,
    skin_dropdown: Imgui_Dropdown,
    offset_window_open: bool,

    mouse_input_mode: Mouse_Input_Mode,
    input_device_hwids: []string,
    input_device_handles: []Mouse_Handle,
}

app_init :: proc() {
    err: os.Error
    app.base_dir, err = os.get_working_directory(context.allocator)
    if err != os.General_Error.None {
        log.panic("couldn't fetch working directory:", err)
    }

    if "build" == filepath.base(app.base_dir) {
        app.base_dir = filepath.dir(app.base_dir)
        os.set_working_directory(app.base_dir)
    }

    // note(isak): logger is created after the working-dir fixup so a file logger lands in the app root
    app.logger = logging_create_logger()
}

app_cleanup :: proc() {
    logging_destroy_logger(app.logger)
}

//////////////////////////////////////////////////////
// note(isak): input api

Mouse_Input_Mode :: enum {
    SDL_INPUT,
    DOUBLE_MOUSE_INPUT,
    SINGLE_MOUSE_INPUT,
    REBINDING_MOUSE_PRIMARY,
    REBINDING_MOUSE_SECONDARY,
}

Mouse_Button :: enum {
    LEFT,
    RIGHT,
    MIDDLE,
}

Button_State :: struct {
    is_down, was_down: bool
}

Mouse_ID :: enum {
    PRIMARY,
    SECONDARY,
}

Mouse :: struct {
    device_handle: Mouse_Handle,
    pos: vec2,
    buttons: [Mouse_Button]Button_State,
    last_click_position: [Mouse_Button]vec2,
    
    is_rebinding: bool,
}

mouse: Mouse
mouse_secondary: Mouse

mice: [Mouse_ID]^Mouse

mouse_init :: proc() {
    mice[.PRIMARY] = &mouse
    mice[.SECONDARY] = &mouse_secondary
 
    when ODIN_OS == .Windows {
        raw_input_enable()
        raw_input_register_sdl_hook()

        app.input_device_hwids, app.input_device_handles = input_enumerate_mouse_devices(memory.allocators[.GLOBAL])
    }
}

mouse_get_position_relative_to_window :: proc() -> (result: vec2) {
    xi, yi: i32
    mouse_flags := sdl.GetGlobalMouseState(&result.x, &result.y)
    sdl.GetWindowPosition(window.handle, &xi, &yi)

    return {result.x - f32(xi), result.y - f32(yi)}
}

mouse_rebind :: proc(id: Mouse_ID, handle: Mouse_Handle) {
    mice[id].device_handle = handle
    mice[id].is_rebinding = false

    handle_hwid: string
    for device_handle, i in app.input_device_handles {
        if handle == device_handle {
            handle_hwid = app.input_device_hwids[i]
            break
        }
    }

    when ODIN_OS == .Windows {
        if handle_hwid == {} {
            handle_hwid = get_hwid_for_mouse_handle(handle, memory.allocators[.GLOBAL])
        }
    }

    if handle_hwid == {} {
        log.errorf("device handle %p could not be resolved to a hwid, rebind failed", handle)
        return
    }

    switch(id) {
    case .PRIMARY:   game.user_config.primary_mouse_hwid = handle_hwid
    case .SECONDARY: game.user_config.secondary_mouse_hwid = handle_hwid
    }
}

mouse_enable_double_mouse_mode :: proc() -> bool {
    if mice[.PRIMARY].device_handle == {} {
        notify_error("device handle for primary mouse does not exist - cannot enable special mouse mode!")
        return false
    }
    
    app.mouse_input_mode = .DOUBLE_MOUSE_INPUT
    for &mouse in mice {
        mouse.pos = mouse_get_position_relative_to_window()
    }
    return true
}

// note(isak): single mouse mode drives the primary cursor from raw input regardless of which physical
// mouse sends it, so no device handle needs to be bound
mouse_enable_single_mouse_mode :: proc() {
    app.mouse_input_mode = .SINGLE_MOUSE_INPUT
    mouse.pos = mouse_get_position_relative_to_window()
}

mouse_disable_raw_input_mode :: proc() {
    app.mouse_input_mode = .SDL_INPUT
}


Keyboard_State :: #sparse [sdl.Scancode]bool

keyboard: struct {
    buttons: ^Keyboard_State,
    buttons_prev_frame: ^Keyboard_State,

    state: [2]Keyboard_State,
    // note(isak): if there's a reason to add text input (that's not ui related), we might wanna add some locale
    // info or state related to character translation messages
}

keyboard_init :: proc() {
    keyboard.buttons = &keyboard.state[0]
    keyboard.buttons_prev_frame = &keyboard.state[1]
}

keyboard_next_frame :: proc() {
    keyboard.buttons, keyboard.buttons_prev_frame = keyboard.buttons_prev_frame, keyboard.buttons

    num_keys: i32
    sdl_state := sdl.GetKeyboardState(&num_keys)
    mem.copy(keyboard.buttons, sdl_state, len(Keyboard_State))
}

keyboard_rebind_input :: proc(event: sdl.Event, rebind: ^sdl.Scancode) {
    if (event.type == sdl.EventType.KEY_DOWN) {
        rebind^ = event.key.scancode //TODO(yokes): this doesn't work, game.input.k1_key = event.key.scancode works
        fmt.printfln("key set to {}", event.key.scancode)
    }
}

input_validate_mouse_hwid :: proc(id: Mouse_ID, hwid: string) -> bool {
    if hwid == {} do return false
    
    when ODIN_OS == .Windows {
        for name, i in app.input_device_hwids {
            if name == hwid {
                mice[id].device_handle = app.input_device_handles[i]
                log.infof("mouse %v resolved to device: %s", id, hwid)
                return true
            }
        }
        log.warnf("mouse %v hwid not found among connected devices: %s", id, hwid)
    }
    return false
}


//////////////////////////////////////////////////////
// note(isak): io api

file_size :: proc(path: string) -> (result: i64, err: os.Error) {
    f := os.open(path) or_return
	defer os.close(f)
	return os.file_size(f)
}

read_entire_file :: proc(path: string, allocator := context.allocator) -> (result: []u8, err: os.Error) {
    expected_size, size_err := file_size(path)
    if size_err != os.General_Error.None {
        return os.read_entire_file(path, allocator)
    }

    retries := 1
    if expected_size > 0 {
        retries = 8
    }

    for attempt in 0..<retries {
        result, err = os.read_entire_file(path, allocator)
        if err != os.General_Error.None {
            return result, err
        }
        if len(result) > 0 || expected_size == 0 {
            return result, err
        }
        if attempt + 1 < retries {
            sdl.Delay(1)
        }
    }
    return result, err
}

read_entire_file_to_string :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
    data, err := read_entire_file(path, allocator)
    return string(data), err
}

read_entire_file_to_cstring :: proc(path: string, allocator := context.allocator) -> (cstring, int, os.Error) {
    data, err := read_entire_file(path, allocator)
    len := len(data)
    return cstring(raw_data(data)), len, err
}
