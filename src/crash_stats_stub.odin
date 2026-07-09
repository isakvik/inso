#+build !windows
package inso

crash_stats_init    :: proc() {}
crash_stats_cleanup :: proc() {}
crash_stats_write   :: proc(frame_count: u64, dt_ms: f64) {}
