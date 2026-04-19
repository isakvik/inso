#+build windows
package notosu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import win "core:sys/windows"

foreign import _dbghelp     "system:Dbghelp.lib"
foreign import _kernel32ext "system:Kernel32.lib"

// -------------------------------------------------------
// extra kernel32 bindings not in core:sys/windows

@(default_calling_convention = "system")
foreign _kernel32ext {
    WaitForDebugEvent :: proc(
        lpDebugEvent:    ^Debug_Event,
        dwMilliseconds:  win.DWORD,
    ) -> win.BOOL ---

    ContinueDebugEvent :: proc(
        dwProcessId:      win.DWORD,
        dwThreadId:       win.DWORD,
        dwContinueStatus: win.DWORD,
    ) -> win.BOOL ---

    GetLocalTime :: proc(lpSystemTime: ^win.SYSTEMTIME) ---
}

// -------------------------------------------------------
// extra dbghelp bindings not in core:sys/windows

@(default_calling_convention = "system")
foreign _dbghelp {
    StackWalk64 :: proc(
        MachineType:                win.DWORD,
        hProcess:                   win.HANDLE,
        hThread:                    win.HANDLE,
        StackFrame:                 ^Stack_Frame64,
        ContextRecord:              win.PVOID,
        ReadMemoryRoutine:          Pread_Process_Memory_Routine64,
        FunctionTableAccessRoutine: Pfunction_Table_Access_Routine64,
        GetModuleBaseRoutine:       Pget_Module_Base_Routine64,
        TranslateAddress:           Ptranslate_Address_Routine64,
    ) -> win.BOOL ---

    SymFunctionTableAccess64 :: proc(hProcess: win.HANDLE, AddrBase: win.DWORD64) -> win.PVOID ---
    SymGetModuleBase64       :: proc(hProcess: win.HANDLE, dwAddr:   win.DWORD64) -> win.DWORD64 ---
}

// -------------------------------------------------------
// debug event types

EXCEPTION_DEBUG_EVENT      :: 1
CREATE_THREAD_DEBUG_EVENT  :: 2
CREATE_PROCESS_DEBUG_EVENT :: 3
EXIT_THREAD_DEBUG_EVENT    :: 4
EXIT_PROCESS_DEBUG_EVENT   :: 5
LOAD_DLL_DEBUG_EVENT       :: 6
UNLOAD_DLL_DEBUG_EVENT     :: 7
OUTPUT_DEBUG_STRING_EVENT  :: 8
RIP_EVENT                  :: 9

DBG_CONTINUE              :: win.DWORD(0x0001_0002)
DBG_EXCEPTION_NOT_HANDLED :: win.DWORD(0x8001_0001)

Exception_Debug_Info :: struct {
    ExceptionRecord: win.EXCEPTION_RECORD,
    dwFirstChance:   win.DWORD,
}

Create_Thread_Debug_Info :: struct {
    hThread:           win.HANDLE,
    lpThreadLocalBase: win.LPVOID,
    lpStartAddress:    rawptr,
}

Create_Process_Debug_Info :: struct {
    hFile:                 win.HANDLE,
    hProcess:              win.HANDLE,
    hThread:               win.HANDLE,
    lpBaseOfImage:         win.LPVOID,
    dwDebugInfoFileOffset: win.DWORD,
    nDebugInfoSize:        win.DWORD,
    lpThreadLocalBase:     win.LPVOID,
    lpStartAddress:        rawptr,
    lpImageName:           win.LPVOID,
    fUnicode:              win.WORD,
}

Exit_Process_Debug_Info :: struct { dwExitCode: win.DWORD }
Exit_Thread_Debug_Info  :: struct { dwExitCode: win.DWORD }

Load_Dll_Debug_Info :: struct {
    hFile:                 win.HANDLE,
    lpBaseOfDll:           win.LPVOID,
    dwDebugInfoFileOffset: win.DWORD,
    nDebugInfoSize:        win.DWORD,
    lpImageName:           win.LPVOID,
    fUnicode:              win.WORD,
}

Unload_Dll_Debug_Info       :: struct { lpBaseOfDll: win.LPVOID }
Output_Debug_String_Info    :: struct { lpDebugStringData: win.LPVOID, fUnicode: win.WORD, nDebugStringLength: win.WORD }
Rip_Info                    :: struct { dwError: win.DWORD, dwType: win.DWORD }

Debug_Event :: struct {
    dwDebugEventCode: win.DWORD,
    dwProcessId:      win.DWORD,
    dwThreadId:       win.DWORD,
    u: struct #raw_union {
        Exception:     Exception_Debug_Info,
        CreateThread:  Create_Thread_Debug_Info,
        CreateProcess: Create_Process_Debug_Info,
        ExitThread:    Exit_Thread_Debug_Info,
        ExitProcess:   Exit_Process_Debug_Info,
        LoadDll:       Load_Dll_Debug_Info,
        UnloadDll:     Unload_Dll_Debug_Info,
        DebugString:   Output_Debug_String_Info,
        RipInfo:       Rip_Info,
    },
}

// -------------------------------------------------------
// stack walking types

CONTEXT_AMD64           :: win.DWORD(0x0010_0000)
CONTEXT_CONTROL         :: CONTEXT_AMD64 | 0x0000_0001
CONTEXT_INTEGER         :: CONTEXT_AMD64 | 0x0000_0002
CONTEXT_FLOATING_POINT  :: CONTEXT_AMD64 | 0x0000_0008
CONTEXT_FULL            :: CONTEXT_CONTROL | CONTEXT_INTEGER | CONTEXT_FLOATING_POINT

IMAGE_FILE_MACHINE_AMD64 :: win.DWORD(0x8664)

Address_Mode :: enum win.DWORD {
    AddrMode1616 = 0,
    AddrMode1632 = 1,
    AddrModeReal = 2,
    AddrModeFlat = 3,
}

Address64 :: struct {
    Offset:  win.DWORD64,
    Segment: win.WORD,
    Mode:    Address_Mode,
}

Kdhelp64 :: struct {
    Thread:                         win.DWORD64,
    ThCallbackStack:                win.DWORD,
    ThCallbackBStore:               win.DWORD,
    NextCallback:                   win.DWORD,
    FramePointer:                   win.DWORD,
    KiCallUserMode:                 win.DWORD64,
    KeUserCallbackDispatcher:       win.DWORD64,
    SystemRangeStart:               win.DWORD64,
    KiUserExceptionDispatcher:      win.DWORD64,
    StackBase:                      win.DWORD64,
    StackLimit:                     win.DWORD64,
    BuildVersion:                   win.DWORD,
    RetpolineStubFunctionTableSize: win.DWORD,
    RetpolineStubFunctionTable:     win.DWORD64,
    RetpolineStubOffset:            win.DWORD,
    RetpolineStubSize:              win.DWORD,
    Reserved0:                      [2]win.DWORD64,
}

Stack_Frame64 :: struct {
    AddrPC:         Address64,
    AddrReturn:     Address64,
    AddrFrame:      Address64,
    AddrStack:      Address64,
    AddrBStore:     Address64,
    FuncTableEntry: win.PVOID,
    Params:         [4]win.DWORD64,
    Far:            win.BOOL,
    Virtual:        win.BOOL,
    Reserved:       [3]win.DWORD64,
    KdHelp:         Kdhelp64,
}

Pread_Process_Memory_Routine64    :: #type proc "system" (hProcess: win.HANDLE, qwBaseAddress: win.DWORD64, lpBuffer: win.LPVOID, nSize: win.DWORD, lpNumberOfBytesRead: ^win.DWORD) -> win.BOOL
Pfunction_Table_Access_Routine64  :: #type proc "system" (hProcess: win.HANDLE, AddrBase: win.DWORD64) -> win.PVOID
Pget_Module_Base_Routine64        :: #type proc "system" (hProcess: win.HANDLE, Address: win.DWORD64) -> win.DWORD64
Ptranslate_Address_Routine64      :: #type proc "system" (hProcess: win.HANDLE, hThread: win.HANDLE, lpaddr: ^Address64) -> win.DWORD64

// -------------------------------------------------------
// exception helpers

MAX_CRASH_STACK_FRAMES :: 64

exception_code_name :: proc(code: win.DWORD) -> string {
    switch code {
    case 0xC0000005: return "access violation"
    case 0xC0000094: return "integer divide by zero"
    case 0xC0000095: return "integer overflow"
    case 0xC000001D: return "illegal instruction"
    case 0xC00000FD: return "stack overflow"
    case 0xC0000025: return "noncontinuable exception"
    case 0x80000003: return "breakpoint"
    case 0x80000004: return "single step"
    case 0x40000015: return "fatal app exit"
    }
    return "unknown"
}

// -------------------------------------------------------
// crash handler entry point

crash_handler_is_game_process :: proc() -> bool {
    for arg in os.args[1:] {
        if arg == "--crash-handler" do return true
    }
    return false
}

crash_handler_run :: proc() {
    exe_buf: [261]win.WCHAR
    win.GetModuleFileNameW(nil, &exe_buf[0], 260)

    // command line must include argv[0] -- windows convention
    exe_path, _ := win.wstring_to_utf8(cstring16(&exe_buf[0]), -1)
    cmd := fmt.tprintf(`"%s" --crash-handler`, exe_path)

    startup_info := win.STARTUPINFOW{ cb = size_of(win.STARTUPINFOW) }
    process_info: win.PROCESS_INFORMATION

    if !win.CreateProcessW(
        win.utf8_to_wstring(exe_path),
        win.utf8_to_wstring(cmd),
        nil, nil, false,
        win.DEBUG_ONLY_THIS_PROCESS,
        nil, nil,
        &startup_info, &process_info,
    ) {
        win.MessageBoxW(nil,
            win.utf8_to_wstring(fmt.tprintf("failed to launch game process (error %d)", win.GetLastError())),
            win.utf8_to_wstring("notosu"),
            win.MB_OK | win.MB_ICONERROR)
        return
    }
    defer win.CloseHandle(process_info.hProcess)
    defer win.CloseHandle(process_info.hThread)

    exit_code, log_path := crash_handler_debug_loop(process_info.hProcess, process_info.dwProcessId)

    if exit_code != 0 {
        msg: string
        if log_path != "" {
            msg = fmt.tprintf(
                "notosu exited with code 0x%08X\n\ncrash log: %s",
                exit_code, log_path)
        } else {
            msg = fmt.tprintf(
                "notosu exited with code 0x%08X\n\ncrash log could not be written.",
                exit_code)
        }
        win.MessageBoxW(nil,
            win.utf8_to_wstring(msg),
            win.utf8_to_wstring("notosu crashed"),
            win.MB_OK | win.MB_ICONERROR)
    }
}

// -------------------------------------------------------
// debug loop

crash_handler_debug_loop :: proc(process: win.HANDLE, pid: win.DWORD) -> (exit_code: win.DWORD, log_path: string) {
    sym_ready := false

    for {
        event: Debug_Event
        if !WaitForDebugEvent(&event, win.INFINITE) do break

        cont := DBG_CONTINUE

        switch event.dwDebugEventCode {
        case CREATE_PROCESS_DEBUG_EVENT:
            if event.u.CreateProcess.hFile != nil {
                win.CloseHandle(event.u.CreateProcess.hFile)
            }
        case LOAD_DLL_DEBUG_EVENT:
            if event.u.LoadDll.hFile != nil {
                win.CloseHandle(event.u.LoadDll.hFile)
            }
        case EXIT_PROCESS_DEBUG_EVENT:
            exit_code = event.u.ExitProcess.dwExitCode
            ContinueDebugEvent(event.dwProcessId, event.dwThreadId, DBG_CONTINUE)
            return
        case EXCEPTION_DEBUG_EVENT:
            info := event.u.Exception
            code := info.ExceptionRecord.ExceptionCode
            if info.dwFirstChance != 0 {
                if code != win.EXCEPTION_BREAKPOINT {
                    cont = DBG_EXCEPTION_NOT_HANDLED
                }
            } else {
                if !sym_ready {
                    win.SymInitialize(process, nil, true)
                    win.SymSetOptions(win.SYMOPT_LOAD_LINES)
                    sym_ready = true
                }
                log_path = crash_handler_write_log(process, pid, event.dwThreadId, &info.ExceptionRecord)
                cont = DBG_EXCEPTION_NOT_HANDLED
            }
        }

        ContinueDebugEvent(event.dwProcessId, event.dwThreadId, cont)
    }
    return
}

// -------------------------------------------------------
// log writing

crash_handler_write_log :: proc(
    process:   win.HANDLE,
    pid:       win.DWORD,
    thread_id: win.DWORD,
    record:    ^win.EXCEPTION_RECORD,
) -> (log_path: string) {
    thread := win.OpenThread(win.THREAD_GET_CONTEXT | win.THREAD_QUERY_INFORMATION, false, thread_id)
    if thread == nil do return
    defer win.CloseHandle(thread)

    ctx: win.CONTEXT
    ctx.ContextFlags = CONTEXT_FULL
    if !win.GetThreadContext(thread, &ctx) do return

    exe_buf: [261]win.WCHAR
    win.GetModuleFileNameW(nil, &exe_buf[0], 260)
    exe_path, _ := win.wstring_to_utf8(cstring16(&exe_buf[0]), -1)
    log_dir := filepath.dir(exe_path, context.temp_allocator)

    st: win.SYSTEMTIME
    GetLocalTime(&st)
    stem := fmt.tprintf("crash_%4d%02d%02d_%02d%02d%02d",
        st.year, st.month, st.day, st.hour, st.minute, st.second)
    log_path = fmt.aprintf("%s/%s.log", log_dir, stem)
    dmp_path := fmt.tprintf("%s/%s.dmp", log_dir, stem)

    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    // header
    fmt.sbprintf(&b, "notosu %s\n", VERSION)
    fmt.sbprintf(&b, "crash_%s\n\n", stem[6:]) // strip "crash_" prefix for the timestamp

    // exception info
    fmt.sbprintf(&b, "exception: %s (0x%08X)\n",
        exception_code_name(record.ExceptionCode), record.ExceptionCode)
    fmt.sbprintf(&b, "address:   0x%016X\n", uintptr(record.ExceptionAddress))
    if record.ExceptionCode == win.EXCEPTION_ACCESS_VIOLATION && record.NumberParameters >= 2 {
        op := "read" if uintptr(record.ExceptionInformation[0]) == 0 else "write"
        fmt.sbprintf(&b, "           %s at 0x%016X\n", op, uintptr(record.ExceptionInformation[1]))
    }

    // stack trace
    fmt.sbprint(&b, "\nstack trace:\n")

    frame: Stack_Frame64
    frame.AddrPC.Offset    = ctx.Rip
    frame.AddrPC.Mode      = .AddrModeFlat
    frame.AddrStack.Offset = ctx.Rsp
    frame.AddrStack.Mode   = .AddrModeFlat
    frame.AddrFrame.Offset = ctx.Rbp
    frame.AddrFrame.Mode   = .AddrModeFlat

    sym_buf: [size_of(win.SYMBOL_INFOW) + 256 * size_of(win.WCHAR)]byte
    sym := (^win.SYMBOL_INFOW)(&sym_buf[0])
    sym.SizeOfStruct = size_of(win.SYMBOL_INFOW)
    sym.MaxNameLen   = 255

    for frame_index := 0; ; frame_index += 1 {
        if frame_index == MAX_CRASH_STACK_FRAMES {
            fmt.sbprintf(&b, "  ... (truncated at %d frames)\n", MAX_CRASH_STACK_FRAMES)
            break
        }
        if !StackWalk64(
            IMAGE_FILE_MACHINE_AMD64,
            process, thread,
            &frame, &ctx,
            nil,
            SymFunctionTableAccess64,
            SymGetModuleBase64,
            nil,
        ) { break }

        pc := frame.AddrPC.Offset
        if pc == 0 do break

        lookup_addr := pc if frame_index == 0 else pc - 1

        proc_name := "?"
        disp64: win.DWORD64
        if win.SymFromAddrW(process, lookup_addr, &disp64, sym) {
            proc_name, _ = win.wstring_to_utf8(cstring16(&sym.Name[0]), -1, context.temp_allocator)
        }

        line: win.IMAGEHLP_LINE64
        line.SizeOfStruct = size_of(win.IMAGEHLP_LINE64)
        disp32: win.DWORD
        if win.SymGetLineFromAddrW64(process, lookup_addr, &disp32, &line) {
            file, _ := win.wstring_to_utf8(line.FileName, -1, context.temp_allocator)
            fmt.sbprintf(&b, "  #%d  %s  (%s:%d)\n", frame_index, proc_name, file, line.LineNumber)
        } else {
            fmt.sbprintf(&b, "  #%d  %s  (0x%016X)\n", frame_index, proc_name, pc)
        }
    }

    crash_handler_append_stats(&b, pid)

    // write log
    content := strings.to_string(b)
    _ = os.write_entire_file(log_path, transmute([]byte)content)

    // write minidump alongside the log
    ex_ptrs := win.EXCEPTION_POINTERS{ ExceptionRecord = record, ContextRecord = &ctx }
    mini_ex := win.MINIDUMP_EXCEPTION_INFORMATION{
        ThreadId          = thread_id,
        ExceptionPointers = &ex_ptrs,
        ClientPointers    = false,
    }
    dmp_file := win.CreateFileW(
        win.utf8_to_wstring(dmp_path),
        win.GENERIC_WRITE, 0, nil,
        win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil,
    )
    if dmp_file != win.INVALID_HANDLE_VALUE {
        win.MiniDumpWriteDump(process, pid, dmp_file, .Normal, &mini_ex, nil, nil)
        win.CloseHandle(dmp_file)
    }

    return
}

// -------------------------------------------------------
// crash stats section

_CRASH_HANDLER_ARENA_NAMES := [CRASH_STATS_ARENAS]string{
    "global", "mapset", "drawables", "judgements", "skin", "sound", "script elements", "frame",
}

_CRASH_HANDLER_MODE_NAMES := [4]string{
    "uninitialized", "main_menu", "play", "editor",
}

crash_handler_append_stats :: proc(b: ^strings.Builder, child_pid: win.DWORD) {
    name := fmt.tprintf("Local\\notosu_stats_%d", child_pid)
    mapping := win.OpenFileMappingW(win.FILE_MAP_READ, false, win.utf8_to_wstring(name))
    if mapping == nil {
        fmt.sbprint(b, "\ncrash stats: unavailable (shared memory not found)\n")
        return
    }
    defer win.CloseHandle(mapping)

    ptr := win.MapViewOfFile(mapping, win.FILE_MAP_READ, 0, 0, size_of(Crash_Stats))
    if ptr == nil {
        fmt.sbprint(b, "\ncrash stats: failed to map view\n")
        return
    }
    defer win.UnmapViewOfFile(ptr)

    s := (^Crash_Stats)(ptr)

    fmt.sbprint(b, "\n--- crash stats (last written frame) ---\n")

    uptime_min := s.uptime_s / 60.0
    fmt.sbprintf(b, "frame: %d  uptime: %.1fs (%.1fm)  last dt: %.2fms\n",
        s.frame_count, s.uptime_s, uptime_min, s.last_dt_ms)

    mode_name := "unknown"
    if int(s.game_mode) < len(_CRASH_HANDLER_MODE_NAMES) {
        mode_name = _CRASH_HANDLER_MODE_NAMES[s.game_mode]
    }
    fmt.sbprintf(b, "mode: %s\n", mode_name)

    if s.beatmap_active != 0 {
        fmt.sbprintf(b, "map: %s%s  pos: %.0fms\n",
            cstring(&s.map_folder[0]), cstring(&s.map_file[0]), s.music_time_ms)
    } else {
        fmt.sbprint(b, "map: none\n")
    }

    fmt.sbprintf(b, "skin: %s\n", cstring(&s.skin_path[0]))
    fmt.sbprintf(b, "mouse: (%.0f, %.0f)\n", s.mouse_x, s.mouse_y)
    fmt.sbprintf(b, "hitobjects: %d total, %d visible\n", s.hitobject_count, s.visible_hitobjects)
    fmt.sbprintf(b, "system free memory: %d MB\n", s.free_phys_memory_mb)

    if s.lua_last_callback[0] != 0 {
        fmt.sbprintf(b, "lua last callback: %s\n", cstring(&s.lua_last_callback[0]))
    } else {
        fmt.sbprint(b, "lua last callback: none\n")
    }

    if s.gpu_vram_total_mb > 0 {
        fmt.sbprintf(b, "gpu vram: %d MB free / %d MB total\n", s.gpu_vram_free_mb, s.gpu_vram_total_mb)
    } else if s.gpu_vram_free_mb > 0 {
        fmt.sbprintf(b, "gpu vram: %d MB free\n", s.gpu_vram_free_mb)
    } else {
        fmt.sbprint(b, "gpu vram: unavailable\n")
    }

    fmt.sbprint(b, "\narena memory (current / peak):\n")
    for arena_name, i in _CRASH_HANDLER_ARENA_NAMES {
        fmt.sbprintf(b, "  %-12s  %6d KB / %6d KB\n",
            arena_name,
            s.arena_current[i] / 1024,
            s.arena_peak[i]    / 1024)
    }
}
