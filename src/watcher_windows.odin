#+build windows
package notosu

import "core:log"
import "core:sys/windows"

NOTIFY_BUFFER_SIZE :: 16 * 1024

Directory_Watch :: struct {
    initialized: bool,
    overlapped: windows.OVERLAPPED,
    notify_buf: [NOTIFY_BUFFER_SIZE]u8,
    buf_len: u32,
    buf_offset: u32,
    iocp_handle: windows.HANDLE,
    dir_handle: windows.HANDLE,
    filename_scratch: [windows.MAX_PATH]u8,
    path: string,
}

directory_watch_init :: proc(path: string) -> Directory_Watch {
    result := Directory_Watch{ path = path }

    result.dir_handle = windows.CreateFileW(
        windows.utf8_to_wstring(path),
        windows.FILE_LIST_DIRECTORY,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        nil,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
        nil,
    )
    if result.dir_handle == windows.INVALID_HANDLE_VALUE {
        log.error("directory_watch_init: invalid path:", path)
        return result
    }

    result.iocp_handle = windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, 0, 1)
    windows.CreateIoCompletionPort(result.dir_handle, result.iocp_handle, 0, 1)
    result.initialized = true
    _directory_watch_start_io(&result)
    return result
}

directory_watch_close :: proc(watch: ^Directory_Watch) {
    if !watch.initialized do return
    windows.CloseHandle(watch.dir_handle)
    windows.CloseHandle(watch.iocp_handle)
    watch.initialized = false
}

directory_watch_poll :: proc(watch: ^Directory_Watch) {
    if !watch.initialized do return
    completion_key: windows.ULONG_PTR
    overlapped: windows.LPOVERLAPPED
    has_result := windows.GetQueuedCompletionStatus(
        watch.iocp_handle, &watch.buf_len, &completion_key, &overlapped, 0,
    )
    if has_result {
        watch.buf_offset = 0
        _directory_watch_start_io(watch)
    } else {
        watch.buf_len = 0
    }
    if windows.GetLastError() == windows.WAIT_TIMEOUT {
        windows.SetLastError(0)
    }
}

directory_watch_next_file :: proc(watch: ^Directory_Watch) -> (filename: string, ok: bool) {
    if watch.buf_len == 0 do return "", false

    notify_at := rawptr(uintptr(&watch.notify_buf) + uintptr(watch.buf_offset))
    notify    := (^windows.FILE_NOTIFY_INFORMATION)(notify_at)

    if notify.file_name_length > 0 && notify.file_name_length < windows.MAX_PATH * size_of(windows.wchar_t) {
        wname := ([^]u16)(&notify.file_name)
        name_len := notify.file_name_length / size_of(windows.wchar_t)
        for i in 0..<name_len {
            watch.filename_scratch[i] = u8(wname[i])
        }
        if notify.next_entry_offset != 0 {
            watch.buf_offset += notify.next_entry_offset
        } else {
            watch.buf_len = 0
        }
        return string(watch.filename_scratch[:name_len]), true
    }

    watch.buf_len = 0
    return "", false
}

_directory_watch_start_io :: proc(watch: ^Directory_Watch) {
    windows.ReadDirectoryChangesW(
        watch.dir_handle,
        &watch.notify_buf,
        NOTIFY_BUFFER_SIZE,
        true,
        windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME |
        windows.FILE_NOTIFY_CHANGE_CREATION  | windows.FILE_NOTIFY_CHANGE_LAST_WRITE,
        nil,
        &watch.overlapped,
        nil,
    )
}
