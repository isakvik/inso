#+build windows
package inso

import "base:intrinsics"
import "core:sys/windows"
import sdl "vendor:sdl3"

// note(isak): sdl's windows backend implements ShowOpenFolderDialog with the ancient
// SHBrowseForFolder tree picker, so we show the modern explorer-style IFileOpenDialog
// (FOS_PICKFOLDERS) ourselves. completes through the same path_buffer/completed handoff
// as _file_dialog_done_proc, so file_dialog_poll needs no windows-specific handling.
win32_folder_dialog_show :: proc() {
    props := sdl.GetWindowProperties(window.handle)
    hwnd := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)

    thread := windows.CreateThread(nil, 0, _win32_folder_dialog_thread, hwnd, 0, nil)
    if thread == nil {
        // note(isak): complete empty so file_dialog_poll still restores the window mode
        app.file_open_dialog.path_len = 0
        intrinsics.atomic_store_explicit(&app.file_open_dialog.completed, true, .Release)
        return
    }
    windows.CloseHandle(thread)
}

_win32_folder_dialog_thread :: proc "system" (owner_hwnd: rawptr) -> windows.DWORD {
    path_len := 0
    defer {
        app.file_open_dialog.path_len = path_len
        intrinsics.atomic_store_explicit(&app.file_open_dialog.completed, true, .Release)
    }

    if windows.FAILED(windows.CoInitializeEx(nil, .APARTMENTTHREADED)) do return 1
    defer windows.CoUninitialize()

    dialog: ^windows.IFileOpenDialog
    hr := windows.CoCreateInstance(windows.CLSID_FileOpenDialog, nil, windows.CLSCTX_INPROC_SERVER,
        windows.IID_IFileOpenDialog, (^windows.LPVOID)(&dialog))
    if windows.FAILED(hr) do return 1
    defer dialog->Release()

    options: windows.FILEOPENDIALOGOPTIONS
    dialog->GetOptions(&options)
    dialog->SetOptions(options | windows.FOS_PICKFOLDERS)

    if windows.FAILED(dialog->Show(windows.HWND(owner_hwnd))) {
        return 0 // cancelled
    }

    item: ^windows.IShellItem
    if windows.FAILED(dialog->GetResult(&item)) do return 1
    defer item->Release()

    wide_path: windows.LPWSTR
    if windows.FAILED(item->GetDisplayName(.FILESYSPATH, &wide_path)) do return 1
    defer windows.CoTaskMemFree(wide_path)

    // note(isak): cchWideChar = -1 converts through the terminator, so written includes it
    written := windows.WideCharToMultiByte(windows.CP_UTF8, 0, cstring16(wide_path), -1,
        windows.LPSTR(&app.file_open_dialog.path_buffer[0]),
        i32(len(app.file_open_dialog.path_buffer)), nil, nil)
    if written > 1 {
        path_len = int(written) - 1
    }
    return 0
}
