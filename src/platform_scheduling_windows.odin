#+build windows
package inso

import "core:log"
import "core:sys/windows"

foreign import scheduling_kernel32 "system:Kernel32.lib"
foreign import avrt "system:Avrt.lib"

@(default_calling_convention="system")
foreign scheduling_kernel32 {
    SetPriorityClass      :: proc(hProcess: windows.HANDLE, dwPriorityClass: windows.DWORD) -> windows.BOOL ---
    SetProcessInformation :: proc(hProcess: windows.HANDLE, ProcessInformationClass: i32, ProcessInformation: rawptr, ProcessInformationSize: windows.DWORD) -> windows.BOOL ---
}

@(default_calling_convention="system")
foreign avrt {
    AvSetMmThreadCharacteristicsW :: proc(TaskName: windows.LPCWSTR, TaskIndex: ^windows.DWORD) -> windows.HANDLE ---
    AvSetMmThreadPriority         :: proc(AvrtHandle: windows.HANDLE, Priority: i32) -> windows.BOOL ---
}

ProcessPowerThrottling: i32 : 4

PROCESS_POWER_THROTTLING_CURRENT_VERSION         :: 1
PROCESS_POWER_THROTTLING_EXECUTION_SPEED         :: 0x1
PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION :: 0x4

PROCESS_POWER_THROTTLING_STATE :: struct {
    Version:     windows.ULONG,
    ControlMask: windows.ULONG,
    StateMask:   windows.ULONG,
}

AVRT_PRIORITY_HIGH:     i32 : 1
AVRT_PRIORITY_CRITICAL: i32 : 2

// note(isak): must run on the main thread - mmcss registration is per-thread.
// high priority class wins scheduler ties against normal background processes, mmcss "Games"
// boosts the render thread in a way that cooperates with audio, and the power throttling opt-out
// keeps us off e-cores and keeps timeBeginPeriod(1) honored while the window is occluded
platform_claim_scheduling_priority :: proc() {
    process := windows.GetCurrentProcess()

    if !SetPriorityClass(process, windows.HIGH_PRIORITY_CLASS) {
        log.warnf("SetPriorityClass(HIGH) failed! win32 error: %d", windows.GetLastError())
    }

    throttling := PROCESS_POWER_THROTTLING_STATE {
        Version     = PROCESS_POWER_THROTTLING_CURRENT_VERSION,
        ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
        StateMask   = 0,
    }
    if !SetProcessInformation(process, ProcessPowerThrottling, &throttling, size_of(throttling)) {
        // note(isak): the throttling class needs win10 1709+; older systems land here harmlessly
        log.infof("power throttling opt-out unavailable, win32 error: %d", windows.GetLastError())
    }

    task_index: windows.DWORD
    mmcss_handle := AvSetMmThreadCharacteristicsW(windows.L("Games"), &task_index)
    if mmcss_handle == nil {
        log.warnf("mmcss 'Games' registration failed! win32 error: %d", windows.GetLastError())
    } else {
        AvSetMmThreadPriority(mmcss_handle, AVRT_PRIORITY_HIGH)
    }
}
