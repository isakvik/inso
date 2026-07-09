#+build windows
package inso

import win "core:sys/windows"
import "core:fmt"
import gl "vendor:OpenGL"

CRASH_STATS_ARENAS :: 8 // must match len(Memory_Arena_Type)
CRASH_STATS_LAYERS :: 8
#assert(CRASH_STATS_LAYERS == len(Layer))

// vendor-specific GL enums for VRAM queries. not in the standard gl package
// since they're extensions, but glGetIntegerv with an unsupported enum just
// generates GL_INVALID_ENUM and returns 0
_GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX :: u32(0x9047) // nvidia: total dedicated VRAM in KB
_GL_GPU_MEMORY_INFO_CURRENT_AVAILABLE_VIDMEM_NVX :: u32(0x9049) // nvidia: available VRAM in KB
_GL_TEXTURE_FREE_MEMORY_ATI :: u32(0x87FC) // amd: [total, largest, aux, aux_largest] in KB

GPU_Vendor :: enum u8 { None, NVIDIA, AMD }
_gpu_vendor: GPU_Vendor

Crash_Stats :: struct {
    // timing
    frame_count: u64,
    uptime_s:    f64,
    last_dt_ms:  f64,

    // game state
    game_mode:      u8,  // cast of Game_Mode enum
    beatmap_active: u8,
    _pad1:          [6]u8,
    music_time_ms:  f64,

    // what was loaded
    map_folder: [256]u8,
    map_file:   [128]u8,
    skin_path:  [256]u8,

    // input
    mouse_x: f32,
    mouse_y: f32,

    // hitobjects
    hitobject_count:    i32,
    visible_hitobjects: i32,

    // system
    free_phys_memory_mb: u64,

    // per-arena memory usage in bytes (order matches Memory_Arena_Type)
    arena_current: [CRASH_STATS_ARENAS]i64,
    arena_peak:    [CRASH_STATS_ARENAS]i64,

    // lua
    lua_last_callback: [64]u8, // last event name dispatched into lua (e.g. "on_update")

    // gpu
    gpu_vram_free_mb:  i32,
    gpu_vram_total_mb: i32, // nvidia only; 0 on amd/unknown

    // gpu profiler results, ~3 frames latent; all zero when disabled via gpu_profiler_enabled
    gpu_layer_time_ns:          [CRASH_STATS_LAYERS]u64,
    gpu_layer_frag_invocations: [CRASH_STATS_LAYERS]u64,
}

_crash_stats_mapping: win.HANDLE
_crash_stats_ptr: ^Crash_Stats

crash_stats_init :: proc() {
    pid  := win.GetCurrentProcessId()
    name := fmt.tprintf("Local\\inso_stats_%d", pid)
    _crash_stats_mapping = win.CreateFileMappingW(
        win.INVALID_HANDLE_VALUE, nil,
        win.PAGE_READWRITE,
        0, size_of(Crash_Stats),
        win.utf8_to_wstring(name),
    )
    if _crash_stats_mapping == nil do return

    ptr := win.MapViewOfFile(_crash_stats_mapping, win.FILE_MAP_WRITE, 0, 0, size_of(Crash_Stats))
    if ptr == nil {
        win.CloseHandle(_crash_stats_mapping)
        _crash_stats_mapping = nil
        return
    }
    _crash_stats_ptr = (^Crash_Stats)(ptr)
}

crash_stats_cleanup :: proc() {
    if _crash_stats_ptr != nil {
        win.UnmapViewOfFile(_crash_stats_ptr)
        _crash_stats_ptr = nil
    }
    if _crash_stats_mapping != nil {
        win.CloseHandle(_crash_stats_mapping)
        _crash_stats_mapping = nil
    }
}

crash_stats_write :: proc(frame_count: u64, dt_ms: f64) {
    s := _crash_stats_ptr
    if s == nil do return

    s.frame_count = frame_count
    s.uptime_s    = time_s_since_beginning_of_program()
    s.last_dt_ms  = dt_ms

    s.game_mode      = u8(game.mode)
    s.beatmap_active = u8(1) if game.beatmap_active else u8(0)
    s.music_time_ms  = game.beatmap.music_time_ms

    copy_fixed :: proc(dst: []u8, src: string) {
        n := min(len(src), len(dst) - 1)
        copy(dst[:n], src[:n])
        dst[n] = 0
    }
    copy_fixed(s.skin_path[:],  game.user_config.skin_path)

    if s.beatmap_active == 1 {
        copy_fixed(s.map_folder[:], game.beatmap.map_reference.folder_path)
        copy_fixed(s.map_file[:],   game.beatmap.map_reference.osu_filename)
    }

    s.mouse_x = mouse.pos.x
    s.mouse_y = mouse.pos.y

    vis := game.beatmap.visible_hitobject_state
    s.hitobject_count    = i32(len(game.beatmap.hitobjects))
    s.visible_hitobjects = i32(vis.latest_i - vis.earliest_i)

    s.free_phys_memory_mb = get_free_phys_memory() / (1024 * 1024)

    for arena in Memory_Arena_Type {
        i := int(arena)
        t := &memory.tracker[arena]
        s.arena_current[i] = i64(t.alloc.current_memory_allocated)
        s.arena_peak[i]    = i64(t.alloc.peak_memory_allocated)
    }

    if lua_beatmap.last_callback != nil {
        cb := string(lua_beatmap.last_callback)
        copy_fixed(s.lua_last_callback[:], cb)
    }

    if frame_count == 0 {
        for gl.GetError() != gl.NO_ERROR {}
        val: i32
        gl.GetIntegerv(_GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX, &val)
        if gl.GetError() == gl.NO_ERROR && val > 0 {
            _gpu_vendor = .NVIDIA
        } else {
            for gl.GetError() != gl.NO_ERROR {}
            gl.GetIntegerv(_GL_TEXTURE_FREE_MEMORY_ATI, &val)
            if gl.GetError() == gl.NO_ERROR && val > 0 {
                _gpu_vendor = .AMD
            }
            for gl.GetError() != gl.NO_ERROR {}
        }
    }

    for layer in Layer {
        s.gpu_layer_time_ns[int(layer)]          = gpu_profiler.layer_time_ns[layer]
        s.gpu_layer_frag_invocations[int(layer)] = gpu_profiler.layer_frag_invocations[layer]
    }

    switch _gpu_vendor {
    case .NVIDIA:
        free_kb, total_kb: i32
        gl.GetIntegerv(_GL_GPU_MEMORY_INFO_CURRENT_AVAILABLE_VIDMEM_NVX, &free_kb)
        gl.GetIntegerv(_GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX, &total_kb)
        s.gpu_vram_free_mb  = free_kb  / 1024
        s.gpu_vram_total_mb = total_kb / 1024
    case .AMD:
        // ATI_meminfo returns [total_pool, largest_free, total_aux, largest_free_aux] in KB
        vals: [4]i32
        gl.GetIntegerv(_GL_TEXTURE_FREE_MEMORY_ATI, &vals[0])
        s.gpu_vram_free_mb  = vals[0] / 1024
        s.gpu_vram_total_mb = 0
    case .None:
        // no vendor extension available
    }
}
