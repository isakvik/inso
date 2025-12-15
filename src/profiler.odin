package notosu

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:strconv"

import sdl "vendor:sdl3"


//////////////////////////////////////////////////////
// note(isak): globals

profiler_w :: i32(600)
profiler_h :: i32(200)

fps_average_running_frame_count :: 100

profiler_pixels: [profiler_h]u32
profiler_frame_pixel_count: i32

profiler: struct {
    trace_points: [Trace_Blocks]Trace_Block_Timer,
    start_tsc: u64,

    prev_frame_blocks_elapsed: [Trace_Blocks]u64,
    frame_times: [fps_average_running_frame_count]u64,
    next_frame_time_at: i32
}

_profiler_current_open_block: Trace_Blocks

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

trace_block_colors := [Trace_Blocks]vec4 {
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
    assert(_profiler_current_open_block == .NONE)
    _profiler_current_open_block = block

    profiler.trace_points[block].start_tsc = sdl.GetPerformanceCounter()
}

profiler_block_end :: proc() {
    trace_point := &profiler.trace_points[_profiler_current_open_block]
    trace_point.elapsed_tsc = sdl.GetPerformanceCounter() - trace_point.start_tsc
    
    assert(_profiler_current_open_block != .NONE)
    _profiler_current_open_block = .NONE
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

profiler_write_texture_column :: proc(frame_count: u64, texture: Texture) {
    profiler_frame_pixel_count = 0
    blocks: for trace_block in Trace_Blocks {
        if trace_block == .NONE { continue }

        // note(isak): one ms = ten pixels
        elapsed_pixels := i32(profiler.prev_frame_blocks_elapsed[trace_block] / (_rdtsc_frequency / 10_000))
        block_frame_pixel_count := elapsed_pixels

        for i in 0..<block_frame_pixel_count {
            pixel_i := profiler_frame_pixel_count + i
            if pixel_i >= profiler_h {
                profiler_frame_pixel_count = profiler_h
                break blocks
            }
            profiler_pixels[pixel_i] =
                color_to_pixel(trace_block_colors[trace_block])
        }
        profiler_frame_pixel_count += block_frame_pixel_count
    }

    if profiler_frame_pixel_count < profiler_h {
        mem.zero_slice(profiler_pixels[profiler_frame_pixel_count:profiler_h])
    }

    texture_write_u32_to(window.profiler_texture, 
        {i32(frame_count) % profiler_w, 0, 1, profiler_h},
        profiler_pixels[:])
}

profiler_push_quad :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), frame_count: u64) {
    pixel_shift := i32(frame_count % u64(profiler_w))
    pixel_shift_clipspace := f32(pixel_shift) / f32(profiler_w)

    profiler_rect: Window_Rect = { window.rect.w, window.rect.h, profiler_w, profiler_h }
    r := to_clipspace_rect(rect_translate_by_anchor(profiler_rect, .BOTTOM_RIGHT))
    

    push_quad_with_uvs(geometry, {r.x,       r.y      }, {0 + pixel_shift_clipspace, 0},
                                 {r.x,       r.y + r.h}, {0 + pixel_shift_clipspace, 1},
                                 {r.x + r.w, r.y      }, {1 + pixel_shift_clipspace, 0},
                                 {r.x + r.w, r.y + r.h}, {1 + pixel_shift_clipspace, 1}, 
                                 color_white, u32(Reserved_Texture_Slots.PROFILER))
      
}

profiler_get_fps :: proc() -> f64 {
    cum_frame_time_tsc: u64
    for frame_time in profiler.frame_times {
        cum_frame_time_tsc += frame_time
    }

    s_per_n_frames := tsc_to_s(cum_frame_time_tsc)
    return fps_average_running_frame_count / s_per_n_frames
}
