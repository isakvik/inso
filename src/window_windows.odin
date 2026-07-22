#+build windows
package inso

import "core:sys/windows"
import sdl "vendor:sdl3"

foreign import _window_user32 "system:User32.lib"

@(default_calling_convention = "system")
foreign _window_user32 {
    GetWindowRect :: proc(hWnd: windows.HWND, lpRect: ^windows.RECT) -> windows.BOOL ---
    SetWindowPos  :: proc(hWnd, hWndInsertAfter: windows.HWND, X, Y, cx, cy: i32, uFlags: windows.UINT) -> windows.BOOL ---
}

_platform_dpi_init :: proc() {
    windows.SetProcessDPIAware()
}

// note(isak): the window is created SDL_WINDOW_TRANSPARENT, and end_frame already forces every
// pixel to alpha 1.0, yet DWM keeps presenting a client launched with nothing opaque drawn
// (tournament wait screen) as see-through until it recomposites the transparent surface. only a
// real WM_SIZE triggers that recomposite - SWP_FRAMECHANGED (WM_NCCALCSIZE only) does not - so we
// send an actual size change with a self-cancelling 1px SetWindowPos wobble right after the first
// swap. cx/cy are the OUTER window size, hence GetWindowRect rather than the sdl client size.
window_refresh_transparency_composition :: proc() {
    props := sdl.GetWindowProperties(window.handle)
    hwnd := windows.HWND(sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
    if hwnd == nil do return

    rect: windows.RECT
    if !GetWindowRect(hwnd, &rect) do return

    width := rect.right - rect.left
    height := rect.bottom - rect.top
    flags := u32(windows.SWP_NOMOVE | windows.SWP_NOZORDER | windows.SWP_NOACTIVATE)

    SetWindowPos(hwnd, nil, 0, 0, width + 1, height, flags)
    SetWindowPos(hwnd, nil, 0, 0, width, height, flags)
}

wstring_len :: proc(wstr: windows.wstring) -> int {
    if wstr == nil do return 0
    
    count := 0
    ptr := ([^]u16)(wstr) 
    
    for ptr[count] != 0 {
        count += 1
    }
    return count
}
