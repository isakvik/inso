#+build !windows
package notosu

import "base:runtime"

_platform_dpi_init :: proc() {}

_platform_install_modal_loop_guard :: proc() {}

platform_file_dialog_open_osu :: proc(alloc: runtime.Allocator) -> (result: string, success: bool) {
    return
}
