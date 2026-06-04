#+build windows
package notosu

import "core:slice"
import "base:runtime"
import "core:log"
import "core:strings"
import "core:sys/windows"
import sdl "vendor:sdl3"


win32_hook_odin_context:  runtime.Context

Mouse_Handle :: windows.HANDLE

// note(isak): you CANNOT disable this once it has been enabled
raw_input_enable :: proc() {
    rid: [1]windows.RAWINPUTDEVICE

    props := sdl.GetWindowProperties(window.handle)
    hwnd := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)

    rid[0].usUsagePage = windows.HID_USAGE_PAGE_GENERIC
    rid[0].usUsage = windows.HID_USAGE_GENERIC_MOUSE
    rid[0].dwFlags = windows.RIDEV_INPUTSINK | windows.RIDEV_DEVNOTIFY
    rid[0].hwndTarget = windows.HWND(hwnd)

    if windows.RegisterRawInputDevices(&rid[0], 1, size_of(rid)) == windows.FALSE {
        log.errorf("registering for Raw Input failed! win32 error: %d", windows.GetLastError())
    }
}

raw_input_register_sdl_hook :: proc() {
    win32_hook_odin_context = context
    sdl.SetWindowsMessageHook(_win32_message_hook, nil)
}

// note(isak): raw input device handles are NOT stable across unplug/replug or sleep/resume - windows
// hands the same physical device a fresh handle. re-enumerate the hwid->handle map and re-resolve each
// bound mouse from its persisted hwid so the hot path keeps matching the right device.
input_refresh_mouse_devices :: proc() {
    app.input_device_hwids, app.input_device_handles = input_enumerate_mouse_devices(memory.allocators[.GLOBAL])

    bound_hwids := [Mouse_ID]string {
        .PRIMARY   = game.user_config.primary_mouse_hwid,
        .SECONDARY = game.user_config.secondary_mouse_hwid,
    }
    for id in Mouse_ID {
        if !input_validate_mouse_hwid(id, bound_hwids[id]) {
            mice[id].device_handle = {}
        }
    }
}

hook_call_count: int
wm_input_count: int

_win32_message_hook :: proc(userdata: rawptr, msg: ^windows.MSG) -> bool {
    hook_call_count += 1
    if msg.message == windows.WM_INPUT do wm_input_count += 1

    if msg.message == windows.WM_INPUT_DEVICE_CHANGE {
        context = win32_hook_odin_context
        input_refresh_mouse_devices()
        return true
    }

    if msg.message != windows.WM_INPUT do return true

    context = win32_hook_odin_context

    size: windows.UINT
    windows.GetRawInputData(windows.HRAWINPUT(msg.lParam), windows.RID_INPUT, nil, &size, size_of(windows.RAWINPUTHEADER))
    if size == 0 || size > size_of(windows.RAWINPUT) do return true

    raw: windows.RAWINPUT
    windows.GetRawInputData(windows.HRAWINPUT(msg.lParam), windows.RID_INPUT, &raw, &size, size_of(windows.RAWINPUTHEADER))

    if raw.header.dwType != windows.RIM_TYPEMOUSE do return true

    m := &raw.data.mouse

    switch app.mouse_input_mode {
    case .DOUBLE_MOUSE_INPUT:
        target: ^Mouse
        if raw.header.hDevice == mouse.device_handle {
            target = &mouse
        } else if raw.header.hDevice == mouse_secondary.device_handle {
            target = &mouse_secondary
        } else {
            return true
        }
        apply_raw_mouse_update(target, m)

    case .SINGLE_MOUSE_INPUT:
        // note(isak): any physical mouse drives the primary cursor, so no handle filtering here
        apply_raw_mouse_update(&mouse, m)

    case .REBINDING_MOUSE_PRIMARY:
        if m.usButtonFlags & windows.RI_MOUSE_LEFT_BUTTON_DOWN != 0 {
            mouse_rebind(.PRIMARY, raw.header.hDevice)
            app.mouse_input_mode = .SDL_INPUT
        }

    case .REBINDING_MOUSE_SECONDARY:
        if m.usButtonFlags & windows.RI_MOUSE_LEFT_BUTTON_DOWN != 0 {
            mouse_rebind(.SECONDARY, raw.header.hDevice)
            app.mouse_input_mode = .SDL_INPUT
        }
    
    case .SDL_INPUT: break
    }

    return true
}

apply_raw_mouse_update :: proc(target: ^Mouse, m: ^windows.RAWMOUSE) {
    if window.mouse_inside && m.usFlags & windows.MOUSE_MOVE_ABSOLUTE == 0 {
        target.pos.x += f32(m.lLastX) * game.user_config.cursor_sensitivity
        target.pos.y += f32(m.lLastY) * game.user_config.cursor_sensitivity
    }

    flags := m.usButtonFlags
    if flags & windows.RI_MOUSE_LEFT_BUTTON_DOWN   != 0 do target.buttons[.LEFT].is_down   = true
    if flags & windows.RI_MOUSE_LEFT_BUTTON_UP     != 0 do target.buttons[.LEFT].is_down   = false
    if flags & windows.RI_MOUSE_RIGHT_BUTTON_DOWN  != 0 do target.buttons[.RIGHT].is_down  = true
    if flags & windows.RI_MOUSE_RIGHT_BUTTON_UP    != 0 do target.buttons[.RIGHT].is_down  = false
    if flags & windows.RI_MOUSE_MIDDLE_BUTTON_DOWN != 0 do target.buttons[.MIDDLE].is_down = true
    if flags & windows.RI_MOUSE_MIDDLE_BUTTON_UP   != 0 do target.buttons[.MIDDLE].is_down = false
}


input_enumerate_mouse_devices :: proc(
    alloc: runtime.Allocator = context.allocator,
    temp_alloc: runtime.Allocator = context.temp_allocator
) -> (names: []string, handles: []windows.HANDLE) {
    device_count: windows.UINT
    if windows.GetRawInputDeviceList(nil, &device_count, size_of(windows.RAWINPUTDEVICELIST)) != 0 {
        log.errorf("enumerating raw input devices failed! win32 error: %d", windows.GetLastError())
        return nil, nil
    }

    device_list := make([]windows.RAWINPUTDEVICELIST, device_count, temp_alloc)

    if windows.GetRawInputDeviceList(raw_data(device_list), &device_count, size_of(windows.RAWINPUTDEVICELIST)) == ~windows.UINT(0) {
        log.errorf("enumerating raw input devices failed! win32 error: %d", windows.GetLastError())
        return nil, nil
    }

    result_names   := make([dynamic]string,          0, device_count, alloc)
    result_handles := make([dynamic]windows.HANDLE,  0, device_count, alloc)
    for i in 0..<device_count {
        if device_list[i].dwType != windows.RIM_TYPEMOUSE do continue

        str := get_hwid_for_mouse_handle(device_list[i].hDevice, alloc)
        if len(str) > 0 {
            append(&result_names, str)
            append(&result_handles, device_list[i].hDevice)
        }
    }

    return result_names[:], result_handles[:]
}

get_hwid_for_mouse_handle :: proc(handle: windows.HANDLE, alloc: runtime.Allocator) -> string {
    buf_size: windows.UINT
    if windows.GetRawInputDeviceInfoW(handle, windows.RIDI_DEVICENAME, nil, &buf_size) != 0 {
        log.errorf("getting raw input device info failed! handle %p, win32 error: %d", handle, windows.GetLastError())
        return {}
    }
    
    // note(isak): buffers must be aligned to windows.UINT boundaries, so we call make() with those
    buf_size_in_uints := (buf_size * size_of(windows.WCHAR)) / size_of(windows.UINT)
    buf_internal := make([]windows.UINT, buf_size_in_uints, alloc)
    buf := slice.from_ptr(raw_data(transmute([]windows.WCHAR)buf_internal), int(buf_size))
    
    if windows.GetRawInputDeviceInfoW(handle, windows.RIDI_DEVICENAME, raw_data(buf), &buf_size) == ~windows.UINT(0) {
        log.errorf("getting raw input device info failed! handle %p, win32 error: %d", handle, windows.GetLastError())
        return {}
    }

    // buf_size for RIDI_DEVICENAME includes the null terminator
    raw_str, _ := windows.utf16_to_utf8(buf[:buf_size-1], alloc)

    // strip \\?\ prefix and trailing #{class-guid}
    trimmed := strings.trim_prefix(raw_str, `\\?\`)
    if cut := strings.last_index(trimmed, "#{"); cut >= 0 {
        trimmed = trimmed[:cut]
    }
    return strings.clone(trimmed, alloc)
}
