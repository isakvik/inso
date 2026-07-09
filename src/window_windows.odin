#+build windows
package inso

import "core:sys/windows"

_platform_dpi_init :: proc() {
    windows.SetProcessDPIAware()
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
