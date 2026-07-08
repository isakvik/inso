package notosu

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import os "core:os"
import "core:strings"
import "core:path/filepath"

import sdl "vendor:sdl3"

Map_Reference :: struct {
    folder_path:  string,
    osu_filename: string, // note(isak): which .osu file to load within the folder
    hash: u64,
    external: bool, // note(isak): opened from outside songs/; survives a songs-folder rediscovery
}

Skin_Reference :: struct {
    folder_path: string,
    external: bool, // note(isak): opened from outside skins/; survives a skins-folder rediscovery
}

app: struct {
    base_dir: string,
    logger: log.Logger,

    disable_raw_input: bool,

    debug_display_frame_graph:      bool,
    debug_display_frame_profiler:   bool,
    debug_display_memory_profiler:  bool,
    debug_display_fontatlas:        bool, // todo(isak): never written to
    debug_display_slider_bounds:    bool,
    debug_display_textures:         bool,
    debug_display_playfield_cursor: bool,

    debug_log_lua_gc: bool,

    map_references:      [dynamic]Map_Reference,
    map_reference_names: [dynamic]cstring, // note(isak): parallel for imgui

    external_map_open: bool,

    // note(isak): completed/path are written from sdl's dialog0 thread, read on the main
    // thread via file_dialog_poll. everything else is main-thread only
    file_open_dialog: struct {
        is_open: bool,
        purpose: File_Dialog_Purpose,
        restore_mode: Window_Mode,
        completed: bool,
        path_len: int,
        path_buffer: [4096]u8,
    },

    skin_references:      [dynamic]Skin_Reference,
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
    crash_stats_init()
}

app_cleanup :: proc() {
    crash_stats_cleanup()
    logging_destroy_logger(app.logger)
}

//////////////////////////////////////////////////////
// note(isak): input api

Mouse_Input_Mode :: enum {
    SDL_INPUT,
    RAW_SINGLE_MOUSE_INPUT,
    RAW_DOUBLE_MOUSE_INPUT,
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
    scroll_delta: f32, // note(isak): vertical wheel delta accumulated this frame. >0 = scroll up
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
        if !app.disable_raw_input {
            raw_input_enable()
            raw_input_register_sdl_hook()
            
            if game.user_config.raw_input_enabled {
                mouse_enable_raw_input_mode()
            }
    
            //app.input_device_hwids, app.input_device_handles = input_enumerate_mouse_devices(memory.allocators[.GLOBAL])
        }
    }
}

mouse_get_position_relative_to_window :: proc() -> (result: vec2) {
    xi, yi: i32
    _ = sdl.GetGlobalMouseState(&result.x, &result.y)
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
    if app.disable_raw_input {
        notify_error("raw input disabled for this program run - cannot enable special mouse mode!")
    }
    
    mouse_enable_raw_input_mode()
    
    if mice[.PRIMARY].device_handle == {} {
        notify_error("device handle for primary mouse does not exist - cannot enable special mouse mode!")
        return false
    }
    
    app.mouse_input_mode = .RAW_DOUBLE_MOUSE_INPUT
    for &mouse in mice {
        mouse.pos = mouse_get_position_relative_to_window()
    }
    return true
}

// note(isak): single mouse mode drives the primary cursor from raw input regardless of which physical
// mouse sends it, so no device handle needs to be bound
mouse_enable_raw_input_mode :: proc() {
    app.mouse_input_mode = .RAW_SINGLE_MOUSE_INPUT
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
    // info or state related to character translation messages here
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
    _ = new(byte, allocator)
    len := len(data)
    return cstring(raw_data(data)), len, err
}


//////////////////////////////////////////////////////
// note(isak): io dialog (async sdl dialogs)

File_Dialog_Purpose :: enum {
    OSU_MAP,
    SKIN_FOLDER,
}

// note(isak): sdl requires the filter list to stay valid until the dialog callback runs
osu_file_dialog_filters := [?]sdl.DialogFileFilter {
    { name = ".osu Files", pattern = "osu" },
    { name = "All Files",  pattern = "*" },
}

file_dialog_open_osu :: proc() {
    if _file_dialog_begin(.OSU_MAP) {
        sdl.ShowOpenFileDialog(_file_dialog_done_proc, nil, window.handle,
            raw_data(osu_file_dialog_filters[:]), i32(len(osu_file_dialog_filters)),
            nil, false)
    }
}

file_dialog_open_skin_folder :: proc() {
    if _file_dialog_begin(.SKIN_FOLDER) {
        when ODIN_OS == .Windows {
            win32_folder_dialog_show()
        } else {
            sdl.ShowOpenFolderDialog(_file_dialog_done_proc, nil, window.handle, nil, false)
        }
    }
}

_file_dialog_begin :: proc(purpose: File_Dialog_Purpose) -> bool {
    if app.file_open_dialog.is_open do return false
    app.file_open_dialog.is_open = true
    app.file_open_dialog.purpose = purpose

    app.file_open_dialog.restore_mode = window.mode
    if window.mode == .FULLSCREEN {
        window_set_mode(.BORDERLESS_FULLSCREEN)
    }
    return true
}

// note(isak): runs on sdl's dialog thread on windows
_file_dialog_done_proc :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
    path_len := 0
    if filelist != nil && filelist[0] != nil {
        path := ([^]u8)(filelist[0])
        for path_len < len(app.file_open_dialog.path_buffer) && path[path_len] != 0 {
            app.file_open_dialog.path_buffer[path_len] = path[path_len]
            path_len += 1
        }
    }
    app.file_open_dialog.path_len = path_len
    intrinsics.atomic_store_explicit(&app.file_open_dialog.completed, true, .Release)
}

file_dialog_poll :: proc() {
    if !intrinsics.atomic_load_explicit(&app.file_open_dialog.completed, .Acquire) do return
    app.file_open_dialog.completed = false
    app.file_open_dialog.is_open = false

    if app.file_open_dialog.path_len > 0 {
        // todo(isak): @leak, but pretty small
        path := strings.clone(string(app.file_open_dialog.path_buffer[:app.file_open_dialog.path_len]),
            memory.allocators[.GLOBAL])
        switch app.file_open_dialog.purpose {
        case .OSU_MAP:     open_external_map(path)
        case .SKIN_FOLDER: open_external_skin(path)
        }
    }
    if window.mode != app.file_open_dialog.restore_mode {
        window_set_mode(app.file_open_dialog.restore_mode)
    }
}
