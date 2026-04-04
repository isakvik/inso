#+build !windows
package notosu

// note: memory guard is disabled on non-windows; see guarding_allocator_proc
get_free_phys_memory :: proc() -> u64 {
    return 0
}
