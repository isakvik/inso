package notosu

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import os "core:os/os2"
import "core:slice"
import "core:strings"

import sg "vendor:sokol/gfx"

Shader_ID :: enum {
    QUAD,
    SLIDER,
    TEXT
}


batch_max_vertices :: 64*1024
max_texture_handles :: 1024

Reserved_Texture_Slots :: enum u32 {
    WHITE,
    PROFILER,
    FONT_ATLAS,
    SLIDER_FRAMEBUFFER
}

reserved_texture :: proc(slot: Reserved_Texture_Slots) -> u32 { return u32(slot) }


Transform :: struct {
    bounds_rect: vec4,
    aspect_ratio: f32,
}

default_transform :: Transform{
    bounds_rect = {-1, -1, 2, 2},
    aspect_ratio = 1
}

Texture_Handle :: u64

Texture :: struct {
    path: string,
    w, h: i32,
    format, internal_format: u32,
    tex_id: u32, // note(isak): assigned texture id
    tex_handle: Texture_Handle, // note(isak): bindless handle
}

Layout_Anchor :: enum {
    TOP_LEFT,
    TOP_MIDDLE,
    TOP_RIGHT,
    MIDDLE_LEFT,
    CENTER,
    MIDDLE_RIGHT,
    BOTTOM_LEFT,
    BOTTOM_MIDDLE,
    BOTTOM_RIGHT,
}

_Rect :: struct($T: typeid) {
    x, y, w, h: T,
}

Rect :: _Rect(f32)
Window_Rect :: _Rect(i32) // note(isak): window space rect measured in pixels

rect_to_array :: proc(r: Rect) -> [4]f32 {
    return {r.x, r.y, r.w, r.h}
}

max_active_texture_resource_size :: 128 * 1024 * 1024

unit_circle_vertex_count :: 32


//////////////////////////////////////////////////////
// note(isak): pipeline definitions

quad_pipeline :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.quad",
        shader = window.shaders[.QUAD].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = {
                enabled = true,
                op_alpha = .SUBTRACT,
                src_factor_rgb = .SRC_ALPHA,
                src_factor_alpha = .SRC_ALPHA,
                dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            }}
        },
        depth = {compare = .LESS_EQUAL, write_enabled = true},
    },
}

slider_pipeline :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.slider",
        shader = window.shaders[.SLIDER].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = {
                enabled = false,
                op_alpha = .MAX,
                src_factor_rgb = .ONE,
                src_factor_alpha = .ONE,
                dst_factor_rgb = .ONE,
                dst_factor_alpha = .ONE,
            }}
        },
        depth = {compare = .LESS_EQUAL, write_enabled = true},
    }
}

text_pipeline :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.text",
        shader = window.shaders[.TEXT].shader,
        index_type = .NONE,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = {
                enabled = true,
                op_alpha = .ADD,
                src_factor_rgb = .SRC_ALPHA,
                dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                src_factor_alpha = .SRC_ALPHA,
                dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            }}
        },
        //depth = {compare = .LESS_EQUAL, write_enabled = true},
    },
}

// note(isak): i didn't get these to work... might not be better than ssbos anyway
quad_uniform_desc :: proc() -> [8]sg.Shader_Uniform_Block { return {} }
slider_uniform_desc :: proc() -> [8]sg.Shader_Uniform_Block { return {} }
text_uniform_desc :: proc() -> [8]sg.Shader_Uniform_Block { return {} }


//////////////////////////////////////////////////////
// note(isak): buffer object, useful for proxies to GPU buffers

Buffer :: struct(T: typeid) {
    count: i32,
    data: []T,
    size: i32
}

buffer_init :: proc(N: i32, data: []$T) -> Buffer(T) {
    result: Buffer(T) = {
        count = 0,
        data = data,
        size = N
    }
    return result
}

buffer_push :: proc(buf: ^Buffer($T), t: T) {
    if true { return }
    assert(buf.count + 1 < buf.size)
    buf.data[buf.count] = t
    buf.count += 1
}


//////////////////////////////////////////////////////
// note(isak): shader api (program api)

Shader_Error :: enum {
    NONE,
    READ_ERROR,
    PATH_ERROR,
    COMPILE_ERROR,
}

Shader :: struct {
    shader: sg.Shader,
    vs_path, fs_path: string,
    uniform_desc: [8]sg.Shader_Uniform_Block
}

init_shader :: proc(vs_path, fs_path: string, uniform_desc: [8]sg.Shader_Uniform_Block = {}) -> (Shader, Shader_Error) {
    vs_filedata, vs_err := read_entire_file(vs_path)
    if vs_err != os.ERROR_NONE {
        fmt.printfln("loading vert shader file '{}' failed: {}", vs_path, vs_err)
        return {}, .READ_ERROR
    }
    fs_filedata, fs_err := read_entire_file(fs_path)
    if fs_err != os.ERROR_NONE {
        fmt.printfln("loading frag shader file '{}' failed: {}", fs_path, fs_err)
        return {}, .READ_ERROR
    }

    if (vs_err != os.ERROR_NONE) || (fs_err != os.ERROR_NONE) {
        return {}, .PATH_ERROR
    }

    temp_shader := sg.make_shader(
        sg.Shader_Desc {
            vertex_func = {source = strings.unsafe_string_to_cstring(string(vs_filedata))},
            fragment_func = {source = strings.unsafe_string_to_cstring(string(fs_filedata))},
            uniform_blocks = uniform_desc
        },
    )

    if sg.query_shader_state(temp_shader) == sg.Resource_State.VALID {
        return {
            shader = temp_shader,
            vs_path = vs_path,
            fs_path = fs_path,
            uniform_desc = uniform_desc
        }, .NONE
    }
    sg.destroy_shader(temp_shader)
    return {}, .COMPILE_ERROR
}

reinit_shader :: proc(shader: ^Shader) -> Shader_Error {
    new_shader, err := init_shader(shader.vs_path, shader.fs_path, shader.uniform_desc)
    if err != .NONE {
        assert(err == .COMPILE_ERROR)
        fmt.println("Shader compile errors found. Paths:", shader.vs_path, shader.fs_path)
        return err
    }
    sg.destroy_shader(shader.shader)
    shader^ = new_shader
    return err
}

reinit_pipeline :: proc(pipeline: ^sg.Pipeline, pipeline_desc: sg.Pipeline_Desc) {
    sg.destroy_pipeline(pipeline^)
    pipeline^ = sg.make_pipeline(pipeline_desc)
}

//////////////////////////////////////////////////////
// note(isak): command queue api

Command_Type :: enum(u8) {
    SET_BOUNDS,
    SET_MODE,
    CLEAR,
    DRAW,
    DRAW_SLIDER,
}

Command_Mode_Type :: enum(u8) {
    QUAD_UV,
    TEXT,
    BEGIN_SLIDERS,
    END_SLIDERS
}

Command_Header :: struct {
    command_type: Command_Type
}

Command_Set_Bounds :: struct {
    transform: Transform
}

Command_Set_Mode :: struct {
    mode: Command_Mode_Type
}

Command_Draw :: struct {
    index_offset: u32,
    index_count: i32,
    base_instance: u32,
    instance_count: i32
}

Command_Draw_Slider :: struct {
    base_instance: u32,
    instance_count: i32
}

Command_Draw_Text :: struct {
    glyph_offset: i32,
    glyph_count: i32,
}

_command_push_header :: proc(type: Command_Type) -> bool {
    ok, err := queue.push_back(&window.renderer.command_queue, u8(type))
    assert(err == .None)
    return ok
}

_command_push :: proc(cmd: $T, type: Command_Type) -> bool {
    cmd := cmd
    ok := _command_push_header(type)
    if ok {
        err: runtime.Allocator_Error
        cmd_data: []u8 = slice.from_ptr((^u8)(&cmd), size_of(T))
        ok, err = queue.push_back_elems(&window.renderer.command_queue, ..cmd_data)
        assert(err == .None)
    }
    assert(ok)
    return ok
}

command_push_set_bounds :: proc(cmd: Command_Set_Bounds) -> bool {
    return _command_push(cmd, .SET_BOUNDS)
}

command_push_set_mode :: proc(cmd: Command_Set_Mode) -> bool {
    return _command_push(cmd, .SET_MODE)
}

command_push_clear :: proc() -> bool {
    return _command_push_header(.CLEAR)
}

command_push_draw :: proc(cmd: Command_Draw) -> bool { 
    return _command_push(cmd, .DRAW)
}

command_push_draw_slider :: proc(cmd: Command_Draw_Slider) -> bool { 
    return _command_push(cmd, .DRAW_SLIDER)
}

//////////////////////////////////////////////////////
// note(isak): texture api

prepare_textures_for_rendering :: proc() {
    /* dx11
    textures := &window.texture_buffer.data

    textures[Reserved_Texture_Slots.WHITE] = window.white_texture.tex_handle
    textures[Reserved_Texture_Slots.PROFILER] = window.profiler_texture.tex_handle
    textures[Reserved_Texture_Slots.FONT_ATLAS] = window.font_atlas_texture.tex_handle
    textures[Reserved_Texture_Slots.SLIDER_FRAMEBUFFER] = window.slider_framebuffer.color_texture_handles[0]
    num_elements := len(Reserved_Texture_Slots)

    for element in Skin_Element {
        textures[num_elements] = window.skin_textures[element].tex_handle
        num_elements += 1
    }

    for i in 0..<num_elements {
        gl.MakeTextureHandleResidentARB(textures[i])
    }
    */
}

cleanup_textures_for_rendering :: proc() {
    /* dx11
    textures := &window.texture_buffer.data
    
    num_elements := len(Reserved_Texture_Slots) + len(Skin_Element)
    for i in 0..<num_elements {
        gl.MakeTextureHandleNonResidentARB(textures[i])
    }
    */
}

//////////////////////////////////////////////////////
// note(isak): layout api

rect_translate_by_anchor :: proc(rect: _Rect($T), anchor: Layout_Anchor) -> _Rect(T) {
    result := _Rect(T) {
        w = rect.w,
        h = rect.h,
    }
    if anchor == .TOP_MIDDLE || anchor == .CENTER || anchor == .BOTTOM_MIDDLE {
        result.x = rect.x - (rect.w / 2)
    } else if anchor == .TOP_RIGHT || anchor == .MIDDLE_RIGHT || anchor == .BOTTOM_RIGHT {
        result.x = rect.x - rect.w
    } else {
        result.x = rect.x
    }

    if anchor == .MIDDLE_LEFT || anchor == .CENTER || anchor == .MIDDLE_RIGHT {
        result.y = rect.y - (rect.h / 2)
    } else if anchor == .BOTTOM_LEFT || anchor == .BOTTOM_MIDDLE || anchor == .BOTTOM_RIGHT {
        result.y = rect.y - rect.h
    } else {
        result.y = rect.y
    }
    return result
}

rect_f32_translate_to_inner_f32 :: proc(inner, outer: _Rect(f32)) -> _Rect(f32) {
    if outer.w <= 0 || outer.h <= 0 {
        return {
            x = outer.x,
            y = outer.y
        }
    }

    return {
        x = outer.x + (inner.x * outer.w),
        y = outer.y + (inner.y * outer.h),
        w = inner.w * outer.w,
        h = inner.h * outer.h
    }
}

rect_u32_translate_to_inner_u32 :: proc(inner, outer: Window_Rect) -> Window_Rect {
    return {
        x = outer.x + inner.x,
        y = outer.y + inner.y,
        w = inner.w,
        h = inner.h
    }
}

rect_f32_translate_to_inner_u32 :: proc(inner: _Rect(f32), outer: Window_Rect) -> Window_Rect {
    if outer.w <= 0 || outer.h <= 0 {
        return {
            x = outer.x,
            y = outer.y
        }
    }
    return {
        x = outer.x + i32(inner.x * f32(outer.w)),
        y = outer.y + i32(inner.y * f32(outer.h)),
        w = i32(inner.w * f32(outer.w)),
        h = i32(inner.h * f32(outer.h))
    }
}

rect_translate_to_inner :: proc {
    rect_f32_translate_to_inner_f32,
    rect_u32_translate_to_inner_u32,
    rect_f32_translate_to_inner_u32,
}


to_clipspace_rect :: proc(rect: Window_Rect) -> _Rect(f32) {
    inv_ar := f32(window.rect.w) / f32(window.rect.h)
    return {
        x = (f32(rect.x) / f32(window.rect.w) * 2 * inv_ar) - inv_ar,
        y = (f32(rect.y) / f32(window.rect.h) * 2) - 1,
        w = (f32(rect.w) / f32(window.rect.w) * 2 * inv_ar),
        h = (f32(rect.h) / f32(window.rect.h) * 2),
    }
}

to_screenspace_rect :: proc(rect: _Rect(f32)) -> Window_Rect {
    return {
        x = i32(rect.x * f32(window.rect.w)),
        y = i32(rect.y * f32(window.rect.h)),
        w = i32(rect.w * f32(window.rect.w)),
        h = i32(rect.h * f32(window.rect.h))
    }
}
