package notosu

import "core:fmt"

import gl "vendor:OpenGL"


// note(isak): GPU profiling via GL query objects. every replayed layer gets a TIME_ELAPSED scope,
// plus a FRAGMENT_SHADER_INVOCATIONS scope where pipeline statistics queries are available, so we
// can see both where GPU time goes and how much overdraw each layer shades. results are read back
// GPU_FRAME_SLOTS-1 frames later and never block: a frame whose queries aren't ready is dropped.

GPU_FRAME_SLOTS :: 4
GPU_SCOPES_PER_FRAME :: 64

Gpu_Frame_Queries :: struct {
    time_queries: [GPU_SCOPES_PER_FRAME]u32,
    frag_queries: [GPU_SCOPES_PER_FRAME]u32,
    scope_layers: [GPU_SCOPES_PER_FRAME]Layer,
    scope_count:  int,
}

gpu_profiler: struct {
    slots: [GPU_FRAME_SLOTS]Gpu_Frame_Queries,
    current_slot: int,
    scope_open: bool,
    frag_queries_supported: bool,
    initialized: bool,

    layer_time_ns:          [Layer]u64,
    layer_frag_invocations: [Layer]u64,
}

profiler_gpu_init :: proc() {
    if !game.user_config.gpu_profiler_enabled do return

    gp := &gpu_profiler
    gp.frag_queries_supported = gl_has_extension("GL_ARB_pipeline_statistics_query")
    for &slot in gp.slots {
        gl.GenQueries(GPU_SCOPES_PER_FRAME, raw_data(slot.time_queries[:]))
        if gp.frag_queries_supported {
            gl.GenQueries(GPU_SCOPES_PER_FRAME, raw_data(slot.frag_queries[:]))
        }
    }
    gp.initialized = true
}

// note(isak): rotates to the next slot and harvests the one it displaces (the oldest in flight).
// checking only the last query's availability is enough - queries complete in submission order.
profiler_gpu_new_frame :: proc() {
    gp := &gpu_profiler
    if !gp.initialized do return

    gp.current_slot = (gp.current_slot + 1) % GPU_FRAME_SLOTS
    slot := &gp.slots[gp.current_slot]

    if slot.scope_count > 0 {
        available: u64
        gl.GetQueryObjectui64v(slot.time_queries[slot.scope_count - 1], gl.QUERY_RESULT_AVAILABLE, &available)
        if available != 0 {
            gp.layer_time_ns = {}
            gp.layer_frag_invocations = {}
            for i in 0..<slot.scope_count {
                layer := slot.scope_layers[i]
                time_ns: u64
                gl.GetQueryObjectui64v(slot.time_queries[i], gl.QUERY_RESULT, &time_ns)
                gp.layer_time_ns[layer] += time_ns

                if gp.frag_queries_supported {
                    frag_invocations: u64
                    gl.GetQueryObjectui64v(slot.frag_queries[i], gl.QUERY_RESULT, &frag_invocations)
                    gp.layer_frag_invocations[layer] += frag_invocations
                }
            }
        }
    }
    slot.scope_count = 0
}

// note(isak): scopes accumulate per layer across batch_flush replays within one frame, since a
// flush re-walks every layer. TIME_ELAPSED scopes can't nest, so an already-open scope wins.
profiler_gpu_scope_begin :: proc(layer: Layer) {
    gp := &gpu_profiler
    if !gp.initialized || gp.scope_open do return

    slot := &gp.slots[gp.current_slot]
    if slot.scope_count >= GPU_SCOPES_PER_FRAME do return

    gl.BeginQuery(gl.TIME_ELAPSED, slot.time_queries[slot.scope_count])
    if gp.frag_queries_supported {
        gl.BeginQuery(gl.FRAGMENT_SHADER_INVOCATIONS, slot.frag_queries[slot.scope_count])
    }
    slot.scope_layers[slot.scope_count] = layer
    gp.scope_open = true
}

profiler_gpu_scope_end :: proc() {
    gp := &gpu_profiler
    if !gp.initialized || !gp.scope_open do return

    gl.EndQuery(gl.TIME_ELAPSED)
    if gp.frag_queries_supported {
        gl.EndQuery(gl.FRAGMENT_SHADER_INVOCATIONS)
    }
    gp.slots[gp.current_slot].scope_count += 1
    gp.scope_open = false
}

profiler_push_gpu_blocks_as_text :: proc(renderer: ^Renderer) {
    gp := &gpu_profiler
    if !gp.initialized do return

    y_inc: f32 = 24
    row_count := len(Layer) + 2
    pos_top_left := vec2{ 400, f32(window.rect.h) - f32(row_count) * y_inc }

    row_label :: proc(row: int) -> string {
        if row < len(Layer) {
            return fmt.enum_value_to_string(Layer(row)) or_else unreachable()
        }
        return "GPU TOTAL" if row == len(Layer) else "TBO WAITS"
    }

    x_inc: f32
    x_inc_max: f32 = min(f32)
    for row in 0..<row_count {
        push_text(renderer, row_label(row),
                  pos_top_left + {0, y_inc * f32(row)},
                  size = y_inc,
                  x_inc = &x_inc)
        x_inc_max = max(x_inc, x_inc_max)
        x_inc = 0
    }

    total_time_ns: u64
    total_frag_invocations: u64
    for layer in Layer {
        total_time_ns          += gp.layer_time_ns[layer]
        total_frag_invocations += gp.layer_frag_invocations[layer]
    }

    time_col := pos_top_left.x + x_inc_max + 16
    frag_col := time_col + 110
    for row in 0..<row_count {
        if row_label(row) == "TBO WAITS" {
            push_text(renderer, fmt.tprintf("%.4f", f64(profiler.prev_frame_buffer_wait_ns) / 1_000_000),
                      {time_col, pos_top_left.y + y_inc * f32(row)},
                      size = y_inc)
            push_text(renderer, fmt.tprintf("x %d", profiler.prev_frame_buffer_wait_hits),
                      {frag_col, pos_top_left.y + y_inc * f32(row)},
                      size = y_inc)
            continue
        }

        time_ns := gp.layer_time_ns[Layer(row)] if row < len(Layer) else total_time_ns
        push_text(renderer, fmt.tprintf("%.4f", f64(time_ns) / 1_000_000),
                  {time_col, pos_top_left.y + y_inc * f32(row)},
                  size = y_inc)

        if gp.frag_queries_supported {
            frags := gp.layer_frag_invocations[Layer(row)] if row < len(Layer) else total_frag_invocations
            push_text(renderer, fmt.tprintf("%.2fM frag", f64(frags) / 1_000_000),
                      {frag_col, pos_top_left.y + y_inc * f32(row)},
                      size = y_inc)
        }
    }
}
