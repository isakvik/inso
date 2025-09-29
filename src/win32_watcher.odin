package notosu

import "core:fmt"
import "core:sys/windows"


win32_print_error :: proc() {
    if windows.GetLastError() > 0 {
        fmt.printfln("win32 error: {}", windows.GetLastError())
    }
}


MAX_FILE_CHANGE_NOTIFICATIONS :: 128
NOTIFY_BUFFER_SIZE :: size_of(windows.FILE_NOTIFY_INFORMATION) * MAX_FILE_CHANGE_NOTIFICATIONS

win32_file_notify_info :: windows.FILE_NOTIFY_INFORMATION

win32_directory_notify_info :: struct {
    initialized: bool,
    overlapped: windows.OVERLAPPED,
    notify_buffer: [NOTIFY_BUFFER_SIZE]u8,
    watch_bytes_written: u32,
    
    iocp_handle: windows.HANDLE,
    dir_handle: windows.HANDLE,
    path: string
}

win32_init_directory_watch :: proc(path: string) -> win32_directory_notify_info {
    result := win32_directory_notify_info{
        path = path
    }

    result.dir_handle = windows.CreateFileW(
        windows.utf8_to_wstring(path),
        windows.FILE_LIST_DIRECTORY,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        nil,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
        nil    
    )

    if result.dir_handle == windows.INVALID_HANDLE_VALUE {
        fmt.printfln("win32_init_directory_watch: invalid path '{}'", path)
        return result
    }

    result.iocp_handle = windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, 0, 1)
    windows.CreateIoCompletionPort(result.dir_handle, result.iocp_handle, 0, 1)

    // note(isak): this will allocate some buffer within Windows, and initializes the directory
    //             for watching of changes

    result.initialized = true
    win32_start_directory_change_io(&result)
    return result
}

win32_get_directory_changes :: proc(watch_dir: ^win32_directory_notify_info) {
    assert(watch_dir.initialized, "watch dir hasn't been initialized")

    using windows
    completion_key: ULONG_PTR
    lpOverlapped: LPOVERLAPPED
    has_result := GetQueuedCompletionStatus(
        watch_dir.iocp_handle,
        &watch_dir.watch_bytes_written,
        &completion_key,
        &lpOverlapped,
        0
    )

    if has_result {
        win32_start_directory_change_io(watch_dir)
    } else {
        watch_dir.watch_bytes_written = 0
    }

    if (GetLastError() == WAIT_TIMEOUT) {
        SetLastError(0)
    } else {
        win32_print_error()
    }
}

win32_start_directory_change_io :: proc(watch_dir: ^win32_directory_notify_info) {
    assert(watch_dir.initialized, "watch dir hasn't been initialized")

    using windows
    ReadDirectoryChangesW(
        watch_dir.dir_handle,
        &watch_dir.notify_buffer,
        NOTIFY_BUFFER_SIZE,
        true, // watch subtree
        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
        FILE_NOTIFY_CHANGE_CREATION | FILE_NOTIFY_CHANGE_LAST_WRITE,
        nil,
        &watch_dir.overlapped,
        nil
    )
    
    win32_print_error()
}
