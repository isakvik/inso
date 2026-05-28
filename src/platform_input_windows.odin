#+build windows
package notosu

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
    
    rid[0].usUsagePage = windows.HID_USAGE_PAGE_GENERIC
    rid[0].usUsage = windows.HID_USAGE_GENERIC_MOUSE
    rid[0].dwFlags = 0
    rid[0].hwndTarget = nil

    if windows.RegisterRawInputDevices(&rid[0], 1, size_of(rid)) == windows.FALSE {
        log.errorf("registering for Raw Input failed! win32 error: %d", windows.GetLastError())
    }
}

raw_input_register_sdl_hook :: proc() {
    win32_hook_odin_context = context
    sdl.SetWindowsMessageHook(_win32_message_hook, nil)
}

_win32_message_hook :: proc(userdata: rawptr, msg: ^windows.MSG) -> bool {
    context = win32_hook_odin_context

    if msg.message != windows.WM_INPUT do return true

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
        
        if m.usFlags & windows.MOUSE_MOVE_ABSOLUTE == 0 {
            target.pos.x = clamp(target.pos.x + f32(m.lLastX), 0, window.rect.w)
            target.pos.y = clamp(target.pos.y + f32(m.lLastY), 0, window.rect.h)
        }
    
        flags := m.usButtonFlags
        if flags & windows.RI_MOUSE_LEFT_BUTTON_DOWN   != 0 do target.buttons[.LEFT].is_down   = true
        if flags & windows.RI_MOUSE_LEFT_BUTTON_UP     != 0 do target.buttons[.LEFT].is_down   = false
        if flags & windows.RI_MOUSE_RIGHT_BUTTON_DOWN  != 0 do target.buttons[.RIGHT].is_down  = true
        if flags & windows.RI_MOUSE_RIGHT_BUTTON_UP    != 0 do target.buttons[.RIGHT].is_down  = false
        if flags & windows.RI_MOUSE_MIDDLE_BUTTON_DOWN != 0 do target.buttons[.MIDDLE].is_down = true
        if flags & windows.RI_MOUSE_MIDDLE_BUTTON_UP   != 0 do target.buttons[.MIDDLE].is_down = false

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

        buf_size: windows.UINT
        if windows.GetRawInputDeviceInfoW(device_list[i].hDevice, windows.RIDI_DEVICENAME, nil, &buf_size) != 0 {
            // note(isak): this can fail for more or less unimportant reasons, so we ignore it
            continue
        }
        buf := make([]windows.WCHAR, buf_size, temp_alloc)
        if windows.GetRawInputDeviceInfoW(device_list[i].hDevice, windows.RIDI_DEVICENAME, raw_data(buf), &buf_size) == ~windows.UINT(0) {
            continue
        }

        // buf_size for RIDI_DEVICENAME includes the null terminator
        raw_str, _ := windows.utf16_to_utf8(buf[:buf_size-1], temp_alloc)

        // strip \\?\ prefix and trailing #{class-guid}
        trimmed := strings.trim_prefix(raw_str, `\\?\`)
        if cut := strings.last_index(trimmed, "#{"); cut >= 0 {
            trimmed = trimmed[:cut]
        }
        str := strings.clone(trimmed, alloc)
        append(&result_names,   str)
        append(&result_handles, device_list[i].hDevice)
    }

    return result_names[:], result_handles[:]
}
