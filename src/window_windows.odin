#+build windows
package notosu

import "base:runtime"
import "core:sys/windows"

import sdl "vendor:sdl3"

_platform_dpi_init :: proc() {
    windows.SetProcessDPIAware()
}

platform_file_dialog_open_osu :: proc(alloc: runtime.Allocator) -> (result: string, success: bool) {
    filepath_buffer: [windows.MAX_PATH]u16 

    filter_utf8 := ".osu Files (*.osu)\x00*.osu\x00All Files (*.*)\x00*.*\x00\x00"
    filter_buffer: [windows.MAX_PATH]u16 
    filter_w := windows.utf8_to_utf16_buf(filter_buffer[:], filter_utf8)

    openfilename := windows.OPENFILENAMEW {
        Flags = windows.OFN_PATHMUSTEXIST | windows.OFN_FILEMUSTEXIST | windows.OFN_EXPLORER,
        lStructSize = size_of(windows.OPENFILENAMEW),
        lpstrFilter = cstring16(raw_data(filter_w)),
        nFilterIndex = 1,
        lpstrFile = cstring16(raw_data(filepath_buffer[:])),
        nMaxFile = windows.MAX_PATH,
        lpstrTitle = "Select an external .osu map file to open"
    }
    
    if windows.GetOpenFileNameW(&openfilename) {
        err: runtime.Allocator_Error
        result, err = windows.wstring_to_utf8_alloc(openfilename.lpstrFile, int(openfilename.nMaxFile), alloc)
        assert(err == .None)
        success = true
    }
    return result, success
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
