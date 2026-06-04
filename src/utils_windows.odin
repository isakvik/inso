#+build windows
package notosu

import "core:sys/windows"

MAX_PATH :: 260

get_free_phys_memory :: proc() -> u64 {
    stat: windows.MEMORYSTATUSEX
    stat.dwLength = size_of(windows.MEMORYSTATUSEX)
    if windows.GlobalMemoryStatusEx(&stat) {
        return stat.ullAvailPhys
    }
    return 0
}
