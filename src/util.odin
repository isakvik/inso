package notosu

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
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

Color :: [4]u8

color_none          :: Color{0x00, 0x00, 0x00, 0x00}
color_white         :: Color{0xFF, 0xFF, 0xFF, 0xFF}
color_dark_gray     :: Color{0x33, 0x33, 0x33, 0xFF}
color_medium_gray   :: Color{0x80, 0x80, 0x80, 0xFF}
color_light_gray    :: Color{0xB2, 0xB2, 0xB2, 0xFF}
color_black         :: Color{0x00, 0x00, 0x00, 0xFF}
color_red           :: Color{0xFF, 0x00, 0x00, 0xFF}
color_green         :: Color{0x00, 0xFF, 0x00, 0xFF}
color_blue          :: Color{0x00, 0x00, 0xFF, 0xFF}
color_orange        :: Color{0xFF, 0x80, 0x00, 0xFF}
color_lime_green    :: Color{0x80, 0xFF, 0x00, 0xFF}
color_yellow        :: Color{0xFF, 0xFF, 0x00, 0xFF}
color_sky_blue      :: Color{0x4C, 0x59, 0xFF, 0xFF}
color_dark_blue     :: Color{0x00, 0x00, 0xCC, 0xFF}
color_purple        :: Color{0x80, 0x00, 0xFF, 0xFF}

with_alpha_f32 :: proc "contextless" (c: Color, alpha: f32) -> Color { return {c.x, c.y, c.z, u8(alpha * 0xFF)} }
with_alpha_u8 :: proc "contextless" (c: Color, alpha: u8) -> Color { return {c.x, c.y, c.z, alpha} }
with_alpha :: proc {
    with_alpha_f32,
    with_alpha_u8
}

color_to_pixel_f32 :: proc "contextless" (v: vec4) -> u32 {
    result := u32(v.x * 0xFF)
    result |= u32(v.y * 0xFF) << 8
    result |= u32(v.z * 0xFF) << 16
    result |= u32(v.w * 0xFF) << 24
    return result
}
color_to_pixel_u8 :: proc "contextless" (c: Color) -> u32 {
    result := u32(c.x)
    result |= u32(c.y) << 8
    result |= u32(c.z) << 16
    result |= u32(c.w) << 24
    return result
}
color_to_pixel :: proc {
    color_to_pixel_f32,
    color_to_pixel_u8,
}

color_from_vec :: proc "contextless" (v: vec4) -> Color {
    result: Color
    result[0] = u8(v.x * 0xFF)
    result[1] = u8(v.y * 0xFF)
    result[2] = u8(v.z * 0xFF)
    result[3] = u8(v.w * 0xFF)
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
// note(isak): memory utils

bytes     :: proc "contextless" (v: int) -> int {return v * 1}
kilobytes :: proc "contextless" (v: int) -> int {return v * 1024}
megabytes :: proc "contextless" (v: int) -> int {return v * 1024 * 1024}
gigabytes :: proc "contextless" (v: int) -> int {return v * 1024 * 1024 * 1024}

size_units_str := [4]string {
    "B",
    "KiB",
    "MiB",
    "GiB"
}

init_growing_arena :: proc(arena: ^virtual.Arena, alloc: ^runtime.Allocator, size_mb: int = 1) -> runtime.Allocator_Error {
    alloc_err := virtual.arena_init_growing(arena, reserved = 1)
    assert(alloc_err == .None)
    alloc^ = virtual.arena_allocator(arena)
    return alloc_err
}

init_static_arena :: proc(arena: ^virtual.Arena, alloc: ^runtime.Allocator, size: int = runtime.Megabyte) -> runtime.Allocator_Error {
    alloc_err := virtual.arena_init_static(arena, reserved = uint(size))
    assert(alloc_err == .None)
    alloc^ = virtual.arena_allocator(arena)
    return alloc_err
}

//////////////////////////////////////////////////////
// note(isak): math utils

vec2 :: linalg.Vector2f32
vec3 :: linalg.Vector3f32
vec4 :: linalg.Vector4f32

mat3 :: linalg.Matrix3x3f32
mat4 :: linalg.Matrix4x4f32

Transform :: linalg.Matrix4x3f32

line_normal :: proc "contextless" (from_to: vec2) -> vec2 {
    return linalg.normalize(linalg.vector2_orthogonal(from_to))
}

rect_from_points :: proc "contextless" (from, to: vec2) -> Rect {
    return {
        min(from.x, to.x),
        min(from.y, to.y),
        abs(from.x - to.x),
        abs(from.y - to.y)
    }
}

transform_from_bounds :: proc "contextless" (r: vec4, aspect_ratio: f32) -> Transform {
    center: vec2 = { r.x + r.z * 0.5, r.y + r.w * 0.5 }
    sx: f32 = 2.0 * aspect_ratio / r.z
    sy: f32 = 2.0 / r.w
    return {
        sx, 0.0, -sx * center.x,
        0.0, sy, -sy * center.y,
        0.0, 0.0, 1.0,
        0.0, 0.0, 0.0,
    }
}

identity_transform :: Transform {
    1, 0, 0,
    0, 1, 0,
    0, 0, 1,
    0, 0, 0,
} 
