#+build windows
package inso

import "base:intrinsics"
import "core:log"
import "core:sync"
import "core:sys/windows"
import sdl "vendor:sdl3"


// note(isak): raw input (WM_INPUT) is delivered to the thread that created the registered target
// window. the main thread only pumps messages once per render frame, which quantizes every input
// timestamp to the frame - so this thread owns a message-only window, registers raw mouse+keyboard
// against it, and stamps each event with QPC on arrival. the thread sleeps in GetMessageW between
// events; a 1000hz mouse wakes it 1000 times a second, a keyboard once per key transition.
//
// the thread only produces timestamped events into a double buffer - all game state is applied on
// the game thread at drain time, so everything downstream stays single-threaded.

INPUT_THREAD_EVENT_CAPACITY :: 2048

input_thread: struct {
    handle: windows.HANDLE,
    qpc_frequency: i64,

    mutex: sync.Mutex,
    buffers: [2][INPUT_THREAD_EVENT_CAPACITY]Input_Event,
    write_buffer: int,
    write_count: int,
    dropped_events: int,

    device_change_pending: bool, // note(isak): atomics; written by the input thread, consumed at drain
    startup_error: u32,
    raw_window: uintptr, // the message-only hwnd owning our registrations; set once by the thread
}

// event timestamps and the walk's "now" come from the same clock, so offsets stay comparable
input_tsc_now :: proc "contextless" () -> (result: i64) {
    windows.QueryPerformanceCounter(cast(^windows.LARGE_INTEGER)&result)
    return
}

input_tsc_frequency :: proc() -> i64 {
    return input_thread.qpc_frequency
}

// note(isak): RIDEV_NOHOTKEYS turns off win32k's own win key hotkey handling (the start menu)
// while one of our windows is foreground. this acts a layer above the LL keyboard hook and covers
// the case the hook provably cannot see on this machine: a win key pressed while raw mouse input
// is streaming (see the winkey investigation). re-registering the same usage updates the flags in
// place. returns false until the input thread's window exists - callers should retry
input_thread_set_win_hotkeys_disabled :: proc(disabled: bool) -> bool {
    hwnd := windows.HWND(intrinsics.atomic_load_explicit(&input_thread.raw_window, .Acquire))
    if hwnd == nil do return false

    rid: windows.RAWINPUTDEVICE
    rid.usUsagePage = windows.HID_USAGE_PAGE_GENERIC
    rid.usUsage = windows.HID_USAGE_GENERIC_KEYBOARD
    rid.dwFlags = windows.RIDEV_INPUTSINK
    if disabled do rid.dwFlags |= windows.RIDEV_NOHOTKEYS
    rid.hwndTarget = hwnd

    if windows.RegisterRawInputDevices(&rid, 1, size_of(windows.RAWINPUTDEVICE)) == windows.FALSE {
        log.errorf("re-registering keyboard raw input for hotkey suppression failed! win32 error: %d", windows.GetLastError())
        return false
    }
    return true
}

input_thread_start :: proc() -> bool {
    windows.QueryPerformanceFrequency(cast(^windows.LARGE_INTEGER)&input_thread.qpc_frequency)

    input_thread.handle = windows.CreateThread(nil, 0, _input_thread_proc, nil, 0, nil)
    if input_thread.handle == nil {
        log.errorf("creating the raw input thread failed! win32 error: %d", windows.GetLastError())
        return false
    }
    // note(isak): floor for when mmcss is unavailable; the thread proc registers itself with
    // mmcss above the boosted main thread so nothing of ours can delay the QPC stamp
    windows.SetThreadPriority(input_thread.handle, windows.THREAD_PRIORITY_HIGHEST)
    return true
}

// note(isak): swaps the double buffer and returns every event received since the last drain, in arrival order.
// the returned slice is valid until the next drain. call once per frame from the game thread.
input_thread_drain :: proc() -> []Input_Event {
    if err := intrinsics.atomic_exchange_explicit(&input_thread.startup_error, 0, .Relaxed); err != 0 {
        log.errorf("raw input thread setup failed! win32 error: %d", err)
    }
    if intrinsics.atomic_exchange_explicit(&input_thread.device_change_pending, false, .Relaxed) {
        input_refresh_mouse_devices()
    }

    sync.mutex_lock(&input_thread.mutex)
    read_buffer := input_thread.write_buffer
    count := input_thread.write_count
    dropped := input_thread.dropped_events
    input_thread.write_buffer = 1 - read_buffer
    input_thread.write_count = 0
    input_thread.dropped_events = 0
    sync.mutex_unlock(&input_thread.mutex)

    if dropped > 0 {
        log.warnf("raw input queue overflowed, %d events dropped", dropped)
    }
    return input_thread.buffers[read_buffer][:count]
}

// note(isak): applies the drained events to the frame-level mouse/rebinding state. gameplay
// judgement consumes the same slice per-event with timestamps in process_hittesting_event_walk -
// this is only the end-of-frame state for ui and everything else
input_thread_apply_events :: proc(events: []Input_Event) {
    for &event in events {
        if event.kind != .MOUSE do continue

        switch app.mouse_input_mode {
        case .RAW_DOUBLE_MOUSE_INPUT:
            target: ^Mouse
            if event.device == mouse.device_handle {
                target = &mouse
            } else if event.device == mouse_secondary.device_handle {
                target = &mouse_secondary
            } else {
                continue
            }
            apply_raw_mouse_event(target, &event)

        case .RAW_SINGLE_MOUSE_INPUT:
            // note(isak): any physical mouse will move the primary cursor, so no handle filtering here
            apply_raw_mouse_event(&mouse, &event)

        case .REBINDING_MOUSE_PRIMARY, .REBINDING_MOUSE_SECONDARY:
            if event.button_flags & INPUT_M1_DOWN != 0 {
                id: Mouse_ID = app.mouse_input_mode == .REBINDING_MOUSE_PRIMARY ? .PRIMARY : .SECONDARY
                mouse_rebind(id, event.device)
                app.mouse_input_mode = .SDL_INPUT
            }

        case .SDL_INPUT: // note(isak): leave to main game loop
        }
    }
}

apply_raw_mouse_event :: proc(target: ^Mouse, event: ^Input_Event) {
    target.pos = raw_cursor_integrate(target.pos, event)

    flags := event.button_flags
    if flags & INPUT_M1_DOWN != 0 do target.buttons[.LEFT].is_down   = true
    if flags & INPUT_M1_UP   != 0 do target.buttons[.LEFT].is_down   = false
    if flags & INPUT_M2_DOWN != 0 do target.buttons[.RIGHT].is_down  = true
    if flags & INPUT_M2_UP   != 0 do target.buttons[.RIGHT].is_down  = false
    if flags & INPUT_M3_DOWN != 0 do target.buttons[.MIDDLE].is_down = true
    if flags & INPUT_M3_UP   != 0 do target.buttons[.MIDDLE].is_down = false
}


_input_thread_proc :: proc "system" (param: rawptr) -> windows.DWORD {
    class_name := windows.LPCWSTR(windows.L("inso_raw_input"))

    wc: windows.WNDCLASSW
    wc.lpfnWndProc = _input_thread_wndproc
    wc.hInstance = windows.HINSTANCE(windows.GetModuleHandleW(nil))
    wc.lpszClassName = class_name
    if windows.RegisterClassW(&wc) == 0 {
        intrinsics.atomic_store_explicit(&input_thread.startup_error, windows.GetLastError(), .Relaxed)
        return 1
    }

    hwnd := windows.CreateWindowExW(0, class_name, nil, 0, 0, 0, 0, 0, windows.HWND_MESSAGE, nil, wc.hInstance, nil)
    if hwnd == nil {
        intrinsics.atomic_store_explicit(&input_thread.startup_error, windows.GetLastError(), .Relaxed)
        return 1
    }

    // note(isak): INPUTSINK delivers input regardless of focus (gated at the consumer), DEVNOTIFY
    // gives us WM_INPUT_DEVICE_CHANGE for unplug/replug. NOLEGACY must stay off - it would suppress
    // the normal mouse/keyboard messages sdl and imgui live on
    rid: [2]windows.RAWINPUTDEVICE
    rid[0].usUsagePage = windows.HID_USAGE_PAGE_GENERIC
    rid[0].usUsage = windows.HID_USAGE_GENERIC_MOUSE
    rid[0].dwFlags = windows.RIDEV_INPUTSINK | windows.RIDEV_DEVNOTIFY
    rid[0].hwndTarget = hwnd
    rid[1].usUsagePage = windows.HID_USAGE_PAGE_GENERIC
    rid[1].usUsage = windows.HID_USAGE_GENERIC_KEYBOARD
    rid[1].dwFlags = windows.RIDEV_INPUTSINK
    rid[1].hwndTarget = hwnd

    if windows.RegisterRawInputDevices(&rid[0], 2, size_of(windows.RAWINPUTDEVICE)) == windows.FALSE {
        intrinsics.atomic_store_explicit(&input_thread.startup_error, windows.GetLastError(), .Relaxed)
        return 1
    }
    intrinsics.atomic_store_explicit(&input_thread.raw_window, uintptr(hwnd), .Release)

    // note(isak): Sleep(1) below needs 1ms timer resolution to actually pace at ~1khz
    windows.timeBeginPeriod(1)

    // mmcss registration is per-thread and must run here. CRITICAL sits above the main thread's
    // AVRT_PRIORITY_HIGH in the same "Games" class, keeping the QPC stamp ahead of a busy frame
    mmcss_index: windows.DWORD
    if mmcss := AvSetMmThreadCharacteristicsW(windows.L("Games"), &mmcss_index); mmcss != nil {
        AvSetMmThreadPriority(mmcss, AVRT_PRIORITY_CRITICAL)
    }

    // the pump has two gears. idle/low-rate: block in GetMessageW and read each event's data
    // directly - zero cpu while nothing moves, exact per-event QPC stamps. hot stream (8khz mice):
    // after the waking event, drain the whole backlog with GetRawInputBuffer at a ~1ms pace until
    // the stream goes quiet. buffered reads also remove the drained events' WM_INPUT messages from
    // the queue, and GetMessageW dequeues the waking event's data with it, so the two read paths
    // never see the same event twice. batched events share one QPC stamp (error <= the pace tick)
    msg: windows.MSG
    for windows.GetMessageW(&msg, nil, 0, 0) > 0 {
        _input_thread_handle_message(&msg)
        if msg.message != windows.WM_INPUT do continue

        for _input_thread_drain_raw_input_buffer() > 0 {
            // non-input messages would starve while we pace, pump them between drains
            pending: windows.MSG
            for windows.PeekMessageW(&pending, nil, 0, 0, windows.PM_REMOVE) != windows.FALSE {
                _input_thread_handle_message(&pending)
            }
            windows.Sleep(1)
        }
    }
    return 0
}

// note(isak): every message ends at DefWindowProc, WM_INPUT included: win32 keeps the raw data
// behind each WM_INPUT alive until the default handler retires it, so a pump that reads the data
// and swallows the message leaks that data for the lifetime of the process
_input_thread_handle_message :: proc "system" (msg: ^windows.MSG) {
    switch msg.message {
    case windows.WM_INPUT:
        _input_thread_on_wm_input(msg.lParam)
    case windows.WM_INPUT_DEVICE_CHANGE:
        intrinsics.atomic_store_explicit(&input_thread.device_change_pending, true, .Relaxed)
    }
    windows.DispatchMessageW(msg)
}

// reads everything queued right now, in bulk. returns the number of events consumed
_input_thread_drain_raw_input_buffer :: proc "system" () -> (total: int) {
    // 8-byte aligned scratch; a mouse event is 48 bytes on x64, so ~85 events per read
    buffer: [512]u64

    for {
        size := windows.UINT(size_of(buffer))
        count := windows.GetRawInputBuffer(cast(windows.PRAWINPUT)&buffer[0], &size, size_of(windows.RAWINPUTHEADER))
        if count == 0 || count == ~windows.UINT(0) do break

        qpc := input_tsc_now()

        raw := cast(^windows.RAWINPUT)&buffer[0]
        for _ in 0..<count {
            _input_thread_queue_raw_event(raw, qpc)
            // buffered reads bypass the message pump, so they retire through DefRawInputProc
            // instead of DefWindowProc - same bookkeeping, same leak if it never happens
            entry := cast(windows.PRAWINPUT)raw
            windows.DefRawInputProc(&entry, 1, size_of(windows.RAWINPUTHEADER))
            // NEXTRAWINPUTBLOCK: entries are variable-size, each aligned to pointer size
            raw = cast(^windows.RAWINPUT)((uintptr(raw) + uintptr(raw.header.dwSize) + 7) & ~uintptr(7))
        }
        total += int(count)
    }
    return
}

// the pump reads WM_INPUT before dispatching it, so by the time anything arrives here it has
// already been queued and only needs retiring
_input_thread_wndproc :: proc "system" (
    hwnd: windows.HWND, msg: windows.UINT, wparam: windows.WPARAM, lparam: windows.LPARAM
) -> windows.LRESULT {
    return windows.DefWindowProcW(hwnd, msg, wparam, lparam)
}

_input_thread_on_wm_input :: proc "system" (lparam: windows.LPARAM) {
    // note(isak): mouse and keyboard raw input always fits in RAWINPUT (only HID devices can
    // exceed it, and we don't register for those), so copy in one call instead of probing the
    // size first. returns -1 if the buffer were ever too small
    raw: windows.RAWINPUT
    size := windows.UINT(size_of(windows.RAWINPUT))
    copied := windows.GetRawInputData(windows.HRAWINPUT(lparam), windows.RID_INPUT, &raw, &size, size_of(windows.RAWINPUTHEADER))
    if copied == ~windows.UINT(0) do return

    _input_thread_queue_raw_event(&raw, input_tsc_now())
}

_input_thread_queue_raw_event :: proc "system" (raw: ^windows.RAWINPUT, tsc: i64) {
    event: Input_Event
    event.tsc = tsc
    event.device = raw.header.hDevice

    switch raw.header.dwType {
    case windows.RIM_TYPEMOUSE:
        m := &raw.data.mouse
        event.kind = .MOUSE
        event.motion_x = i32(m.lLastX)
        event.motion_y = i32(m.lLastY)
        event.button_flags = u16(m.usButtonFlags)
        event.absolute_motion = m.usFlags & windows.MOUSE_MOVE_ABSOLUTE != 0

    case windows.RIM_TYPEKEYBOARD:
        k := &raw.data.keyboard
        // note(isak): VKey 255 marks fake keys (keyboard overrun, the E0 2A ghost shift that
        // accompanies print screen, ...) - never real key transitions
        if k.VKey == 0xFF do return
        event.kind = .KEY
        event.scancode = raw_key_to_sdl_scancode(k.MakeCode, k.Flags)
        event.key_is_down = k.Flags & windows.RI_KEY_BREAK == 0
        if event.scancode == .UNKNOWN do return

    case:
        return
    }

    sync.mutex_lock(&input_thread.mutex)
    defer sync.mutex_unlock(&input_thread.mutex)

    write := &input_thread.buffers[input_thread.write_buffer]

    // note(isak): pure motion coalesces into the previous event when nothing happened in between,
    // so sustained movement occupies one queue slot per button/key transition instead of one per
    // device report - an 8khz mouse can no longer overflow the queue during a main thread hitch.
    // transitions are never merged, and integrated position at each transition stays exact
    if event.kind == .MOUSE && event.button_flags == 0 && input_thread.write_count > 0 {
        last := &write[input_thread.write_count - 1]
        if last.kind == .MOUSE && last.button_flags == 0 &&
           last.device == event.device && last.absolute_motion == event.absolute_motion {
            if event.absolute_motion {
                last^ = event
            } else {
                last.motion_x += event.motion_x
                last.motion_y += event.motion_y
                last.tsc = event.tsc
            }
            return
        }
    }

    if input_thread.write_count < INPUT_THREAD_EVENT_CAPACITY {
        write[input_thread.write_count] = event
        input_thread.write_count += 1
    } else {
        input_thread.dropped_events += 1
    }
}


// note(isak): raw keyboard reports ps/2 scancode set 1 make codes; sdl scancodes are usb hid usages.
// the base table covers the unprefixed set, E0-prefixed keys (navigation cluster, right-side
// modifiers, keypad enter/divide) are handled separately, E1 only ever prefixes pause
@(rodata)
_raw_scancode_base_table := [0x59]sdl.Scancode {
    0x01 = .ESCAPE,
    0x02 = ._1, 0x03 = ._2, 0x04 = ._3, 0x05 = ._4, 0x06 = ._5,
    0x07 = ._6, 0x08 = ._7, 0x09 = ._8, 0x0A = ._9, 0x0B = ._0,
    0x0C = .MINUS, 0x0D = .EQUALS, 0x0E = .BACKSPACE, 0x0F = .TAB,
    0x10 = .Q, 0x11 = .W, 0x12 = .E, 0x13 = .R, 0x14 = .T,
    0x15 = .Y, 0x16 = .U, 0x17 = .I, 0x18 = .O, 0x19 = .P,
    0x1A = .LEFTBRACKET, 0x1B = .RIGHTBRACKET, 0x1C = .RETURN, 0x1D = .LCTRL,
    0x1E = .A, 0x1F = .S, 0x20 = .D, 0x21 = .F, 0x22 = .G,
    0x23 = .H, 0x24 = .J, 0x25 = .K, 0x26 = .L,
    0x27 = .SEMICOLON, 0x28 = .APOSTROPHE, 0x29 = .GRAVE, 0x2A = .LSHIFT, 0x2B = .BACKSLASH,
    0x2C = .Z, 0x2D = .X, 0x2E = .C, 0x2F = .V, 0x30 = .B, 0x31 = .N, 0x32 = .M,
    0x33 = .COMMA, 0x34 = .PERIOD, 0x35 = .SLASH, 0x36 = .RSHIFT,
    0x37 = .KP_MULTIPLY, 0x38 = .LALT, 0x39 = .SPACE, 0x3A = .CAPSLOCK,
    0x3B = .F1, 0x3C = .F2, 0x3D = .F3, 0x3E = .F4, 0x3F = .F5,
    0x40 = .F6, 0x41 = .F7, 0x42 = .F8, 0x43 = .F9, 0x44 = .F10,
    0x45 = .NUMLOCKCLEAR, 0x46 = .SCROLLLOCK,
    0x47 = .KP_7, 0x48 = .KP_8, 0x49 = .KP_9, 0x4A = .KP_MINUS,
    0x4B = .KP_4, 0x4C = .KP_5, 0x4D = .KP_6, 0x4E = .KP_PLUS,
    0x4F = .KP_1, 0x50 = .KP_2, 0x51 = .KP_3, 0x52 = .KP_0, 0x53 = .KP_PERIOD,
    0x56 = .NONUSBACKSLASH, 0x57 = .F11, 0x58 = .F12,
}

raw_key_to_sdl_scancode :: proc "contextless" (makecode: u16, flags: u16) -> sdl.Scancode {
    if flags & windows.RI_KEY_E1 != 0 do return .PAUSE

    if flags & windows.RI_KEY_E0 != 0 {
        switch makecode {
        case 0x1C: return .KP_ENTER
        case 0x1D: return .RCTRL
        case 0x35: return .KP_DIVIDE
        case 0x37: return .PRINTSCREEN
        case 0x38: return .RALT
        case 0x46: return .PAUSE // ctrl+break
        case 0x47: return .HOME
        case 0x48: return .UP
        case 0x49: return .PAGEUP
        case 0x4B: return .LEFT
        case 0x4D: return .RIGHT
        case 0x4F: return .END
        case 0x50: return .DOWN
        case 0x51: return .PAGEDOWN
        case 0x52: return .INSERT
        case 0x53: return .DELETE
        case 0x5B: return .LGUI
        case 0x5C: return .RGUI
        case 0x5D: return .APPLICATION
        }
        return .UNKNOWN
    }

    if int(makecode) >= len(_raw_scancode_base_table) do return .UNKNOWN
    return _raw_scancode_base_table[makecode]
}
