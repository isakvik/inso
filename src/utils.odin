package notosu

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"

import sdl "vendor:sdl3"


//////////////////////////////////////////////////////
// note(isak): time api

_rdtsc_frequency := u64(sdl.GetPerformanceFrequency())
_program_start_tsc: u64


tsc_to_ms :: proc(tsc: u64) -> f64 {
    return f64(tsc) / f64(_rdtsc_frequency / 1000)
}
tsc_to_s :: proc(tsc: u64) -> f64 {
    return f64(tsc) / f64(_rdtsc_frequency)
}

current_time_ms :: proc() -> f64 {
    return tsc_to_ms(sdl.GetPerformanceCounter())
}
current_time_s :: proc() -> f64 {
    return tsc_to_s(sdl.GetPerformanceCounter())
}

time_s_since_beginning_of_program :: proc() -> f64 {
    return tsc_to_s(sdl.GetPerformanceCounter() - _program_start_tsc)
}

time_ms_to_string :: proc(time: f64) -> (result: string) {
    if time < 0 {
        abs_time := abs(time)
        min := math.floor(abs_time / 60000)
        sec := math.mod(math.floor(abs_time / 1000), 60)
        result = fmt.tprintf("-%.0f:%2.0f:%3.0f", min, sec, math.mod_f64(abs_time, 1000))
    } else {
        min := math.floor(time / 60000)
        sec := math.mod(math.floor(time / 1000), 60)
        result = fmt.tprintf("%.0f:%2.0f:%3.0f", min, sec, math.mod_f64(time, 1000))
    }
    return
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
color_cyan          :: Color{0x00, 0xFF, 0xFF, 0xFF}
color_orange        :: Color{0xFF, 0x80, 0x00, 0xFF}
color_dim_orange    :: Color{0xF0, 0xA0, 0x40, 0xFF}
color_lime_green    :: Color{0x80, 0xFF, 0x00, 0xFF}
color_yellow        :: Color{0xFF, 0xFF, 0x00, 0xFF}
color_dim_yellow    :: Color{0xF0, 0xF0, 0x40, 0xFF}
color_light_blue    :: Color{0x5C, 0xE0, 0xFF, 0xFF}
color_sky_blue      :: Color{0x4C, 0x59, 0xFF, 0xFF}
color_dark_blue     :: Color{0x00, 0x00, 0xCC, 0xFF}
color_purple        :: Color{0x80, 0x00, 0xFF, 0xFF}
color_magenta       :: Color{0xFF, 0x00, 0xFF, 0xFF}

with_alpha_f32 :: proc "contextless" (c: Color, alpha: f32) -> Color { return {c.r, c.g, c.b, u8(alpha * 0xFF)} }
with_alpha_u8 :: proc "contextless" (c: Color, alpha: u8) -> Color { return {c.r, c.g, c.b, alpha} }
with_alpha :: proc {
    with_alpha_f32
}

color_to_pixel_f32 :: proc "contextless" (v: vec4) -> u32 {
    result := u32(v.r * 0xFF)
    result |= u32(v.g * 0xFF) << 8
    result |= u32(v.b * 0xFF) << 16
    result |= u32(v.a * 0xFF) << 24
    return result
}
color_to_pixel_u8 :: proc "contextless" (c: Color) -> u32 {
    result := u32(c.r)
    result |= u32(c.g) << 8
    result |= u32(c.b) << 16
    result |= u32(c.a) << 24
    return result
}
color_to_pixel :: proc {
    color_to_pixel_f32,
    color_to_pixel_u8,
}

color_to_vec :: proc "contextless" (c: Color) -> (result: vec4) {
    result[0] = f32(c.r) / 0xFF
    result[1] = f32(c.g) / 0xFF
    result[2] = f32(c.b) / 0xFF
    result[3] = f32(c.a) / 0xFF
    return result
}
color_from_vec :: proc "contextless" (v: vec4) -> (result: Color) {
    result[0] = u8(v.r * 0xFF)
    result[1] = u8(v.g * 0xFF)
    result[2] = u8(v.b * 0xFF)
    result[3] = u8(v.a * 0xFF)
    return result
}
color_from_pixel :: proc "contextless" (p: u32) -> (result: Color) {
    result[0] = u8((p & 0x000000FF) >> 0)
    result[1] = u8((p & 0x0000FF00) >> 8)
    result[2] = u8((p & 0x00FF0000) >> 16)
    result[3] = u8((p & 0xFF000000) >> 24)
    return result
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

init_tracked_growing_arena :: proc(
    arena: ^virtual.Arena, alloc: ^runtime.Allocator, backing: ^runtime.Allocator, track: ^Guarding_Allocator, size_mb: int = 1
) -> runtime.Allocator_Error {
    alloc_err := virtual.arena_init_growing(arena, reserved = 1)
    assert(alloc_err == .None)
    
    backing^ = virtual.arena_allocator(arena)
    mem.tracking_allocator_init(&track.alloc, backing^)
    alloc^ = guarding_allocator(track)
    
    return alloc_err
}

init_static_arena :: proc(arena: ^virtual.Arena, alloc: ^runtime.Allocator, size: int = runtime.Megabyte) -> runtime.Allocator_Error {
    alloc_err := virtual.arena_init_static(arena, reserved = uint(size))
    assert(alloc_err == .None)
    alloc^ = virtual.arena_allocator(arena)
    return alloc_err
}


Guarding_Allocator :: struct {
    alloc: mem.Tracking_Allocator,
}

@(require_results, no_sanitize_address)
guarding_allocator :: proc(data: ^Guarding_Allocator) -> mem.Allocator {
	return mem.Allocator{
		data = data,
		procedure = guarding_allocator_proc,
	}
}

@(no_sanitize_address)
guarding_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (result: []byte, err: mem.Allocator_Error) {
    data := (^Guarding_Allocator)(allocator_data)
    
    when ODIN_OS == .Windows {
        buffer_guard := int(get_free_phys_memory()) - gigabytes(1)
        assert(int(data.alloc.current_memory_allocated) + size < buffer_guard, "memory guard triggered: less than 1GB memory left on computer")
        if int(data.alloc.current_memory_allocated) + size >= buffer_guard {
            log.error("memory guard triggered: less than 1GB memory left on computer")
            return nil, mem.Allocator_Error.Out_Of_Memory
        }
    }
    return mem.tracking_allocator_proc(allocator_data, mode, size, alignment, old_memory, old_size, loc)
}



//////////////////////////////////////////////////////
// note(isak): collision utils

point_in_rect :: proc(p: vec2, r: Rect) -> bool {
    is_within_x := p.x >= (r.x) && p.x <= (r.x + r.w);
    is_within_y := p.y >= (r.y) && p.y <= (r.y + r.h);
    return is_within_x && is_within_y;
}

point_in_circle :: proc(p, c: vec2, r: f32) -> bool {
    return linalg.distance(p, c) <= r
}

rect_from_points :: proc "contextless" (from, to: vec2) -> Rect {
    return {
        min(from.x, to.x),
        min(from.y, to.y),
        abs(from.x - to.x),
        abs(from.y - to.y)
    }
}

//////////////////////////////////////////////////////
// note(isak): math utils

vec2 :: linalg.Vector2f32
vec3 :: linalg.Vector3f32
vec4 :: linalg.Vector4f32

mat3 :: linalg.Matrix3x3f32
mat4 :: linalg.Matrix4x4f32

// note(isak): GPU transforms, not particularly useful for cpu operations before they're
// converted to mat3
Transform :: linalg.Matrix4x3f32

transform_to_mat3 :: proc "contextless" (t: Transform) -> mat3 {
    return {
        t[0][0], t[1][0], t[2][0],
        t[0][1], t[1][1], t[2][1],
        t[0][2], t[1][2], t[2][2]
    }
}

mat3_to_transform :: proc "contextless" (m: mat3) -> Transform {
    return Transform{
        m[0][0], m[1][0], m[2][0],
        m[0][1], m[1][1], m[2][1],
        m[0][2], m[1][2], m[2][2],
        0,0,0
    }
}

mat3_rotation :: proc "contextless" (th: f32) -> mat3 {
    return {
        math.cos(th), -math.sin(th), 0,
        math.sin(th), math.cos(th), 0,
        0, 0, 1
    }
}

// note(isak): builds a 2d affine transform mat3: scale -> rotate -> translate.
// column-vector convention: mat3_affine(...) * vec3(pos, 1)
mat3_affine :: proc "contextless" (translation: vec2, scale: f32, rotation_rad: f32) -> mat3 {
    t := mat3{1, 0, translation.x,  0, 1, translation.y,  0, 0, 1}
    s := mat3{scale, 0, 0,  0, scale, 0,  0, 0, 1}
    return t * mat3_rotation(rotation_rad) * s
}

line_normal :: proc "contextless" (from_to: vec2) -> vec2 {
    return linalg.normalize(linalg.vector2_orthogonal(from_to))
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

fullscreen_transform :: Transform {
    2, 0, -1,
    0, 2, -1,
    0, 0, 1,
    0, 0, 0,
}
