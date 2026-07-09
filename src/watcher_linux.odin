#+build linux
package inso

import "core:log"
import "core:strings"
import "core:sys/linux"

INOTIFY_BUF_SIZE :: 4096

Directory_Watch :: struct {
    initialized: bool,
    inotify_fd: linux.Fd,
    wd: linux.Wd,
    buf: [INOTIFY_BUF_SIZE]u8,
    buf_len: int,
    buf_offset: int,
    path: string,
}

directory_watch_init :: proc(path: string) -> Directory_Watch {
    result := Directory_Watch{ path = path }

    fd, err := linux.inotify_init1({ .NONBLOCK })
    if err != .NONE {
        log.error("inotify_init1 failed:", err)
        return result
    }

    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    wd, err2 := linux.inotify_add_watch(fd, path_cstr, { .CLOSE_WRITE, .MOVED_TO, .CREATE })
    if err2 != .NONE {
        log.error("inotify_add_watch failed:", path, err2)
        linux.close(fd)
        return result
    }

    result.inotify_fd  = fd
    result.wd          = wd
    result.initialized = true
    return result
}

directory_watch_close :: proc(watch: ^Directory_Watch) {
    if !watch.initialized do return
    linux.inotify_rm_watch(watch.inotify_fd, watch.wd)
    linux.close(watch.inotify_fd)
    watch.initialized = false
}

directory_watch_poll :: proc(watch: ^Directory_Watch) {
    if !watch.initialized do return
    n, err := linux.read(watch.inotify_fd, watch.buf[:])
    watch.buf_offset = 0
    watch.buf_len    = n if err == .NONE else 0
}

directory_watch_next_file :: proc(watch: ^Directory_Watch) -> (filename: string, ok: bool) {
    event_base_size :: size_of(linux.Inotify_Event)
    for watch.buf_offset + event_base_size <= watch.buf_len {
        ev := (^linux.Inotify_Event)(rawptr(&watch.buf[watch.buf_offset]))
        watch.buf_offset += event_base_size + int(ev.len)
        if ev.len > 0 {
            name_ptr := rawptr(uintptr(rawptr(ev)) + size_of(linux.Inotify_Event))
            return string(cstring(name_ptr)), true
        }
    }
    return "", false
}
