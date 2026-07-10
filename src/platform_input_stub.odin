#+build !windows
package inso


Mouse_Handle :: uintptr

windows_key_set_disabled :: proc(disabled: bool) {}

input_thread_start :: proc() -> bool { return false }
input_thread_drain :: proc() -> []Input_Event { return nil }
input_thread_apply_events :: proc(events: []Input_Event) {}

input_tsc_now :: proc() -> i64 { return 0 }
input_tsc_frequency :: proc() -> i64 { return 1 }
