package notosu

import "core:fmt"
import "core:sys/windows"


win32_print_error :: proc() {
    if windows.GetLastError() > 0 {
        fmt.printfln("win32 error: {}", windows.GetLastError())
    }
}


NOTIFY_BUFFER_SIZE :: 16 * 1024
Win32_File_Notify_Info :: windows.FILE_NOTIFY_INFORMATION

Win32_Directory_Watch :: struct {
    initialized: bool,
    overlapped: windows.OVERLAPPED,
    notify_buffer: [NOTIFY_BUFFER_SIZE]u8,
    notify_bytes_written: u32,
    notify_read_offset: u32,
    
    iocp_handle: windows.HANDLE,
    dir_handle: windows.HANDLE,
    path: string
}

win32_init_directory_watch :: proc(path: string) -> Win32_Directory_Watch {
    result := Win32_Directory_Watch{
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

win32_get_directory_changes :: proc(watch_dir: ^Win32_Directory_Watch) {
    assert(watch_dir.initialized, "watch dir hasn't been initialized")

    using windows
    completion_key: ULONG_PTR
    lpOverlapped: LPOVERLAPPED
    has_result := GetQueuedCompletionStatus(
        watch_dir.iocp_handle,
        &watch_dir.notify_bytes_written,
        &completion_key,
        &lpOverlapped,
        0
    )

    if has_result {
        win32_start_directory_change_io(watch_dir)
    } else {
        watch_dir.notify_bytes_written = 0
    }

    if (GetLastError() == WAIT_TIMEOUT) {
        SetLastError(0)
    } else {
        win32_print_error()
    }
}

win32_start_directory_change_io :: proc(watch: ^Win32_Directory_Watch) {
    assert(watch.initialized, "watch dir hasn't been initialized")

    using windows
    ReadDirectoryChangesW(
        watch.dir_handle,
        &watch.notify_buffer,
        NOTIFY_BUFFER_SIZE,
        true, // watch subtree
        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
        FILE_NOTIFY_CHANGE_CREATION | FILE_NOTIFY_CHANGE_LAST_WRITE,
        nil,
        &watch.overlapped,
        nil
    )
    win32_print_error()
}

// returns a pointer to the next notify object, plus the given filename length in characters (not bytes)
win32_watch_get_next_notify :: proc(watch: ^Win32_Directory_Watch, filename_buf: ^[windows.MAX_PATH]u16) -> (^Win32_File_Notify_Info, u32) {
    
    assert(watch.notify_read_offset < NOTIFY_BUFFER_SIZE, "pointer arithmetic error!")
    
    // note(isak): might be the only way to do pointer arithmetic... thanks microsoft for requiring this
    notify_at := rawptr(uintptr(&watch.notify_buffer) + uintptr(watch.notify_read_offset))
    notify := (^Win32_File_Notify_Info)(notify_at)

    if notify.file_name_length > 0 {
        filename_cs16 := ([^]u16)(&notify.file_name)
        filename_str_len := notify.file_name_length / size_of(windows.wchar_t)

        for i in 0 ..< filename_str_len {
            filename_buf[i] = filename_cs16[i]
        }
        filename_buf[filename_str_len] = 0

        watch.notify_read_offset += notify.next_entry_offset
        return notify, filename_str_len
    }
    return notify, 0
}
