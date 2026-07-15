
#+build windows
package inso

import "core:slice"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:strings"
import "core:sys/windows"


Mouse_Handle :: windows.HANDLE

// note(isak): raw input device handles are NOT stable across unplug/replug or sleep/resume.
// re-enumerate the hwid->handle map and resolve each bound mouse from its persisted hwid
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

// note(isak): blocks the windows key during play mode, like osu, in two layers. the primary is
// RIDEV_NOHOTKEYS on our keyboard raw input registration - win32k then skips its start menu
// hotkey for our foreground windows. this matters because the LL hook below cannot see a win key
// pressed while raw mouse input is streaming (win32k quirk; the key skips the whole legacy hook
// layer yet still fires the hotkey). the hook remains as the second layer and carries
// --disable-raw-input runs, where there is no registration to hang NOHOTKEYS on.
//
// ll hook callbacks are serviced by the installing thread's message pump, and windows stalls
// keyboard delivery to the foreground app until the hook answers - installing from the game
// thread couples every keypress on the system to our frame time (~10ms message handling spikes).
// so the hook lives on a dedicated thread whose only job is pumping messages; it installs once
// on first use and stays for the process lifetime, _win32_winkey_swallow toggles the behavior
_win32_winkey_thread: windows.HANDLE
_win32_winkey_thread_failed: bool
_win32_winkey_swallow: bool
_win32_nohotkeys_applied: bool // game-thread only; retried until the input thread's window exists
_win32_winkey_hook_error: u32 // note(isak): install failure from the hook thread, logged at the next toggle

windows_key_set_disabled :: proc(disabled: bool) {
    if err := intrinsics.atomic_exchange_explicit(&_win32_winkey_hook_error, 0, .Relaxed); err != 0 {
        log.errorf("installing the windows key hook failed! win32 error: %d", err)
    }

    if _win32_nohotkeys_applied != disabled && input_thread_set_win_hotkeys_disabled(disabled) {
        _win32_nohotkeys_applied = disabled
    }

    if disabled && _win32_winkey_thread == nil {
        if _win32_winkey_thread_failed do return
        _win32_winkey_thread = windows.CreateThread(nil, 0, _win32_winkey_thread_proc, nil, 0, nil)
        if _win32_winkey_thread == nil {
            _win32_winkey_thread_failed = true
            log.errorf("creating the windows key hook thread failed! win32 error: %d", windows.GetLastError())
            return
        }
    }

    intrinsics.atomic_store_explicit(&_win32_winkey_swallow, disabled, .Relaxed)
}

_win32_winkey_thread_proc :: proc "system" (param: rawptr) -> windows.DWORD {
    hook := windows.SetWindowsHookExW(windows.WH_KEYBOARD_LL, _win32_winkey_hook_proc, nil, 0)
    if hook == nil {
        intrinsics.atomic_store_explicit(&_win32_winkey_hook_error, windows.GetLastError(), .Relaxed)
        return 1
    }

    // note(isak): GetMessageW never returns for hook dispatch (the callback runs inside it), so
    // this loop just keeps the thread responsive until process exit
    msg: windows.MSG
    for windows.GetMessageW(&msg, nil, 0, 0) > 0 {
        windows.TranslateMessage(&msg)
        windows.DispatchMessageW(&msg)
    }
    windows.UnhookWindowsHookEx(hook)
    return 0
}

_win32_winkey_hook_proc :: proc "system" (code: windows.c_int, wparam: windows.WPARAM, lparam: windows.LPARAM) -> windows.LRESULT {
    if code == windows.HC_ACTION && intrinsics.atomic_load_explicit(&_win32_winkey_swallow, .Relaxed) {
        key := cast(^windows.KBDLLHOOKSTRUCT)uintptr(lparam)
        if key.vkCode == windows.VK_LWIN || key.vkCode == windows.VK_RWIN {
            return 1
        }
    }
    return windows.CallNextHookEx(nil, code, wparam, lparam)
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
