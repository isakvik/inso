#+build !windows
package notosu

// note: stub file watcher for non-windows platforms.
// hot reload is not functional here yet; all procs are no-ops.

MAX_PATH :: 4096

Win32_File_Notify_Info :: struct {
    next_entry_offset: u32,
    action:            u32,
    file_name_length:  u32,
    file_name:         u16,
}

Win32_Directory_Watch :: struct {
    initialized:          bool,
    notify_bytes_written: u32,
    notify_read_offset:   u32,
    path:                 string,
}

win32_init_directory_watch :: proc(path: string) -> Win32_Directory_Watch {
    return Win32_Directory_Watch{path = path}
}

win32_close_directory_watch :: proc(watch_dir: ^Win32_Directory_Watch) {}

win32_get_directory_changes :: proc(watch_dir: ^Win32_Directory_Watch) {}

win32_watch_get_next_notify :: proc(watch: ^Win32_Directory_Watch, filename_buf: ^[MAX_PATH]u16) -> (^Win32_File_Notify_Info, u32) {
    return nil, 0
}
