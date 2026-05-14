#+build !windows
package notosu

MAX_PATH :: 260

// note: memory guard is disabled on non-windows; see guarding_allocator_proc
get_free_phys_memory :: proc() -> u64 {
    return 0
}
