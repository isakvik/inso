package notosu

import "core:mem/virtual"
import "core:fmt"
import "core:mem"
import "core:container/queue"

import sdl "vendor:sdl3"


//////////////////////////////////////////////////////
// note(isak): globals

profiler_w :: i32(600)
profiler_h :: i32(200)

fps_average_running_frame_count :: 100

profiler: struct {
    trace_points: [Trace_Blocks]Trace_Block_Timer,
    start_tsc: u64,

    prev_frame_blocks_elapsed: [Trace_Blocks]u64,
    frame_times: [fps_average_running_frame_count]u64,
    next_frame_time_at: i32,
    
    prev_frame_command_buffer_lens: [Layer]uint,
    prev_frame_command_buffer_caps: [Layer]int,

    pixels: [profiler_h]u32,
    frame_pixel_count: i32,

    current_open_block: Trace_Blocks
}

//////////////////////////////////////////////////////
// note(isak): types

Trace_Blocks :: enum {
    NONE,
    MESSAGE_HANDLING,
    PREPARE_FRAME,
    GAME_UPDATE,
    GAME_DRAW,
    SWAP_FRAME,
    SLEEP,
    BETWEEN_FRAMES,
}

trace_block_colors := [Trace_Blocks]Color {
    .NONE = color_none,
    .MESSAGE_HANDLING = color_orange,
    .PREPARE_FRAME = color_yellow,
    .GAME_UPDATE = color_red,
    .GAME_DRAW = color_purple,
    .SWAP_FRAME = color_lime_green,
    .SLEEP = color_dark_blue,
    .BETWEEN_FRAMES = color_white
}

Trace_Block_Timer :: struct {
    start_tsc, elapsed_tsc: u64
}


//////////////////////////////////////////////////////
// note(isak): api

profiler_begin :: proc() {
    profiler.trace_points = {}
    profiler.start_tsc = sdl.GetPerformanceCounter()
}

profiler_end :: proc() {
    total_elapsed_tsc := sdl.GetPerformanceCounter() - profiler.start_tsc

    profiler.frame_times[profiler.next_frame_time_at] = total_elapsed_tsc
    profiler.next_frame_time_at = (profiler.next_frame_time_at + 1) % fps_average_running_frame_count

    for profiler_block in Trace_Blocks {
        profiler.prev_frame_blocks_elapsed[profiler_block] =
            profiler.trace_points[profiler_block].elapsed_tsc
    }
}

profiler_block_begin :: proc(block: Trace_Blocks) {
    assert(profiler.current_open_block == .NONE)
    profiler.current_open_block = block

    profiler.trace_points[block].start_tsc = sdl.GetPerformanceCounter()
}

profiler_block_end :: proc() {
    trace_point := &profiler.trace_points[profiler.current_open_block]
    trace_point.elapsed_tsc = sdl.GetPerformanceCounter() - trace_point.start_tsc
    
    assert(profiler.current_open_block != .NONE)
    profiler.current_open_block = .NONE
}


profiler_push_blocks_as_text :: proc(renderer: ^Renderer, frame_count: u64) {
    y_inc: f32 = 24
    pos_top_left := vec2{ 32, f32(window.rect.h) - (len(Trace_Blocks)) * y_inc }    

    x_inc: f32
    x_inc_max: f32 = min(f32)
    for trace_block in Trace_Blocks {
        if trace_block == .NONE { continue }
        
        push_text(renderer, 
                  fmt.enum_value_to_string(trace_block) or_else unreachable(), 
                  pos_top_left + {0, y_inc * f32(trace_block)},
                  size = y_inc,
                  x_inc = &x_inc)
        x_inc_max = max(x_inc, x_inc_max)
        x_inc = 0
    }
    
    buf: [32]byte
    for trace_block in Trace_Blocks {
        if trace_block == .NONE { continue }

        trace_block_ms := tsc_to_ms(profiler.prev_frame_blocks_elapsed[trace_block])

        trace_block_str := fmt.bprintf(buf[:], "%.4f", trace_block_ms)

        push_text(renderer, 
                  trace_block_str,
                  pos_top_left + {16 + x_inc_max, y_inc * f32(trace_block)},
                  size = y_inc)
    }
}

profiler_collect_command_buffer_memory_data :: proc() {
    for layer in Layer {
        layer_queue := &window.renderer.layer_command_queues[layer]
        profiler.prev_frame_command_buffer_lens[layer] = layer_queue.len
        profiler.prev_frame_command_buffer_caps[layer] = cap(layer_queue.data)
    }
}

profiler_push_memory_diag_text :: proc(renderer: ^Renderer) {
    y_spacing: f32 = 24
    pos_top_right := vec2{ window.rect.w - 32, y_spacing*1.5 }
    x_inc: f32
    x_inc_max: f32 = min(f32)
    
    // note(isak): arena section
    for arena, i in memory.arenas {
        unit_i: int
        used_in_units := arena.total_used
        reserved_in_units := arena.total_reserved

        if arena.total_reserved > mem.Kilobyte * 10 {
            unit_i += 1
            used_in_units /= mem.Kilobyte
            reserved_in_units /= mem.Kilobyte
        }
        if arena.total_reserved > mem.Megabyte * 10 {
            unit_i += 1
            used_in_units /= mem.Kilobyte
            reserved_in_units /= mem.Kilobyte
        }
        
        push_text(renderer, 
                  fmt.tprintf("%d/%d %s", used_in_units, reserved_in_units, size_units_str[unit_i]),
                  pos_top_right + {0, y_spacing * f32(i)},
                  size = y_spacing,
                  align_h = .Right,
                  x_inc = &x_inc)
                  
        x_inc_max = max(x_inc, x_inc_max)
        x_inc = 0
    }

    for arena, i in memory.arenas {
        push_text(renderer, 
                  memory_arena_names[i],
                  pos_top_right + { -x_inc_max - 16 , y_spacing * f32(i)},
                  size = y_spacing,
                  align_h = .Right)
    }
    
    // note(isak): command buffer section
    x_inc = 0
    x_inc_max = min(f32)
    pos_top_right.y += y_spacing * len(Memory_Arenas)

    for layer in Layer {
        unit_i: int
        len_in_units := profiler.prev_frame_command_buffer_lens[layer]
        cap_in_units := profiler.prev_frame_command_buffer_caps[layer]
        if profiler.prev_frame_command_buffer_caps[layer] > mem.Kilobyte * 10 {
            unit_i += 1
            len_in_units /= mem.Kilobyte
            cap_in_units /= mem.Kilobyte
        }
        if profiler.prev_frame_command_buffer_caps[layer] > mem.Megabyte * 10 {
            unit_i += 1
            len_in_units /= mem.Kilobyte
            cap_in_units /= mem.Kilobyte
        }
        
        push_text(renderer, 
                  fmt.tprintf("%d/%d %s", len_in_units, cap_in_units, size_units_str[unit_i]),
                  pos_top_right + { 0, f32(layer) * y_spacing },
                  size = y_spacing,
                  align_h = .Right,
                  x_inc = &x_inc)

        x_inc_max = max(x_inc, x_inc_max)
        x_inc = 0
    }

    for layer in Layer {
        push_text(renderer, 
                  fmt.enum_value_to_string(layer) or_else unreachable(),
                  pos_top_right + { -x_inc_max - 16, y_spacing * f32(layer) },
                  size = y_spacing,
                  align_h = .Right)
    }
}

profiler_write_texture_column :: proc(frame_count: u64, texture: Texture) {
    profiler.frame_pixel_count = 0
    blocks: for trace_block in Trace_Blocks {
        if trace_block == .NONE { continue }

        // note(isak): one ms = ten pixels
        elapsed_pixels := i32(profiler.prev_frame_blocks_elapsed[trace_block] / (_rdtsc_frequency / 10_000))
        block_frame_pixel_count := elapsed_pixels

        for i in 0..<block_frame_pixel_count {
            pixel_i := profiler.frame_pixel_count + i
            if pixel_i >= profiler_h {
                profiler.frame_pixel_count = profiler_h
                break blocks
            }
            profiler.pixels[pixel_i] = color_to_pixel(trace_block_colors[trace_block])
        }
        profiler.frame_pixel_count += block_frame_pixel_count
    }

    if profiler.frame_pixel_count < profiler_h {
        mem.zero_slice(profiler.pixels[profiler.frame_pixel_count:profiler_h])
    }

    texture_write_u32_to(window.profiler_texture, 
        {f32(i32(frame_count) % profiler_w), 0, 1, f32(profiler_h)},
        profiler.pixels[:])
}

profiler_push_quad :: proc(geometry: ^Buffer(Quad), frame_count: u64) {
    pixel_shift := i32(frame_count % u64(profiler_w))
    pixel_shift_clipspace := f32(pixel_shift) / f32(profiler_w)

    profiler_rect: Rect = { f32(window.rect.w), f32(window.rect.h), f32(profiler_w), f32(profiler_h) }
    r := rect_translate_by_anchor(profiler_rect, .BOTTOM_RIGHT)
    
    r_draw_quad_with_uv(geometry, {r.x, r.y}, {r.x + r.w, r.y + r.h},
                                 {0 + pixel_shift_clipspace, 1}, {1 + pixel_shift_clipspace, 0}, 
                                 color_white, u32(Builtin_Texture_Slot.PROFILER))
}

profiler_get_fps :: proc() -> f64 {
    cum_frame_time_tsc: u64
    for frame_time in profiler.frame_times {
        cum_frame_time_tsc += frame_time
    }

    s_per_n_frames := tsc_to_s(cum_frame_time_tsc)
    return s_per_n_frames == 0 ? 0 : fps_average_running_frame_count / s_per_n_frames
}

profiler_get_frametime :: proc() -> f64 {
    cum_frame_time_tsc: u64
    for frame_time in profiler.frame_times {
        cum_frame_time_tsc += frame_time
    }

    s_per_n_frames := tsc_to_ms(cum_frame_time_tsc)
    return s_per_n_frames / fps_average_running_frame_count
}
