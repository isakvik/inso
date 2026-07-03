#+build !windows
package notosu

import "base:runtime"

_platform_dpi_init :: proc() {}

platform_file_dialog_open_osu :: proc(alloc: runtime.Allocator) -> (result: string, success: bool) {
    return
}
