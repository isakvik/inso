package notosu

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem/virtual"
import os "core:os/os2"
import "core:strings"

import sdl "vendor:sdl3"

//////////////////////////////////////////////////////
// note(isak): time api

_rdtsc_frequency := u64(sdl.GetPerformanceFrequency())
_program_start_time: f64


tsc_to_ms :: proc(tsc: u64) -> f64 {
    return f64(tsc) / f64(_rdtsc_frequency / 1000)
}

tsc_to_s :: proc(tsc: u64) -> f64 {
    return f64(tsc) / f64(_rdtsc_frequency)
}

current_time :: proc() -> f64 {
    return tsc_to_s(sdl.GetPerformanceCounter())
}

time_since_beginning_of_program :: proc() -> f64 {
    return current_time() - _program_start_time
}


//////////////////////////////////////////////////////
// note(isak): color api

color_none       :: vec4{0,0,0,0}
color_white      :: vec4{1,1,1,1}
color_black      :: vec4{0,0,0,1}
color_red        :: vec4{1,0,0,1}
color_green      :: vec4{0,1,0,1}
color_blue       :: vec4{0,0,1,1}
color_orange     :: vec4{1, 0.5, 0, 1}
color_lime_green :: vec4{0.5, 1, 0, 1}
color_yellow     :: vec4{1, 1, 0, 1}
color_sky_blue   :: vec4{0.3, 0.35, 1.0, 1}
color_dark_blue  :: vec4{0, 0, 0.8, 1}
color_purple     :: vec4{0.5, 0, 1, 1}

with_alpha :: proc(v: vec4, alpha: f32) -> vec4 { return {v.x, v.y, v.z, alpha} }

color_to_pixel :: proc(v: vec4) -> u32 {
    result := u32(v.x * 0xFF)
    result |= u32(v.y * 0xFF) << 8
    result |= u32(v.z * 0xFF) << 16
    result |= u32(v.w * 0xFF) << 24
    return result
}

//////////////////////////////////////////////////////
// note(isak): io api

read_entire_file :: proc(path: string, allocator := context.allocator) -> ([]u8, os.Error) {
    result: []u8
    err: os.Error = os.General_Error.None
    for len(result) == 0 && err == os.General_Error.None {
        result, err = os.read_entire_file_from_path(path, allocator)
    }
    return result, err
}

read_entire_file_to_string :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
    data, err := read_entire_file(path, allocator)
    return string(data), err
}


//////////////////////////////////////////////////////
// note(isak): memory api

arena_default_alignment :: 16

bytes     :: proc(v: int) -> int {return v * 1}
kilobytes :: proc(v: int) -> int {return v * 1024}
megabytes :: proc(v: int) -> int {return v * 1024 * 1024}
gigabytes :: proc(v: int) -> int {return v * 1024 * 1024 * 1024}


arena_push :: proc(arena: ^virtual.Arena, $T: typeid) -> (^T, virtual.Allocator_Error) {
    data, err := virtual.arena_alloc(arena, size_of(T), arena_default_alignment)
    assert(err == .None, "memory allocation error")
    return (^T)(raw_data(data)), err
}

init_growing_arena :: proc(arena: ^virtual.Arena, size_MB: uint = 1) -> (runtime.Allocator, runtime.Allocator_Error) {
    alloc_err := virtual.arena_init_growing(arena, size_MB)
    assert(alloc_err == .None)
    alloc := virtual.arena_allocator(arena)
    if alloc_err != .None {
        fmt.println("mapset arena init error:", alloc_err)
    }
    return alloc, .None
}


//////////////////////////////////////////////////////
// note(isak): math api

line_normal :: proc(from_to: vec2) -> vec2 {
    return linalg.normalize(linalg.vector2_orthogonal(from_to))
}

rect_from_points :: proc(from, to: vec2) -> Rect {
    return {
        min(from.x, to.x),
        min(from.y, to.y),
        abs(from.x - to.x),
        abs(from.y - to.y)
    }
}
