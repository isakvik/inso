package notosu

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"
import stbi "vendor:stb/image"


main_vs_path :: "shaders/main.vs.glsl"
main_fs_path :: "shaders/main.fs.glsl"

batch_max_vertices :: 64*1024


Layer :: enum {
    DEFAULT,
    BACKGROUND,
    FOREGROUND,
    HIT_OBJECT,
    OVERLAY,
    DEBUG
}


Shader_Error :: enum {
    NONE,
    READ_ERROR,
    PATH_ERROR,
    COMPILE_ERROR,
}

Vertex :: struct {
    pos:   vec2,
    uv:    vec2,
    color: vec4,
    tex_index: u32,
    __padding: [3]u32
}

Vertex_Batch :: struct {
    vertexCount:   u32,
    indexCount:    u32,
    vertex_buffer: []Vertex,
    index_buffer:  []u32,
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

Texture_Handle :: u64

Texture :: struct {
    path: string,
    x, y: i32,
    tex_id: u32, // gl assigned texture id
    tex_handle: Texture_Handle, // note(isak): bindless handle
}

max_active_texture_resource_size :: 128 * 1024 * 1024


//////////////////////////////////////////////////////
// note(isak): resource api

init_renderer :: proc() {
    gl.load_up_to(4, 6, sdl.gl_set_proc_address)

    sg.setup(
        {
            environment = {
                defaults = {
                    sample_count = 4,
                    color_format = sg.Pixel_Format.RGBA8,
                    depth_format = sg.Pixel_Format.DEPTH_STENCIL,
                },
            },
            logger = {func = slog.func},
        },
    )

    err: Shader_Error
    window.main_shader, err = init_shader(main_vs_path, main_fs_path)
    assert(err == .NONE)

    window.pipeline = init_pipeline(window.main_shader)
    window.vertex_buffer = pbo_init(Vertex, 64 * 1024)
    window.index_buffer = pbo_init(u32, 128 * 1024)
    window.texture_buffer = pbo_init(u64, 128)
    
    window.pass_action = { 
        colors = {
            0 = { load_action = .CLEAR, clear_value = { 0.15, 0.10, 0.23, 1 } }, 
        }
    }

    window.swapchain = sg.Swapchain{
        width = window.rect.w,
        height = window.rect.h,
        sample_count = 4,
        color_format = .RGBA8,
        depth_format = .DEPTH_STENCIL,
        gl = {0} // default framebuffer
    }

    window.white_texture = texture_from_data(1, 1, {0xFFFFFFFF})
}

init_shader :: proc(vs_path, fs_path: string) -> (sg.Shader, Shader_Error) {
    vs_filedata, vs_err := read_entire_file(vs_path)
    if vs_err != os.ERROR_NONE {
        fmt.printfln("loading vert shader file '{}' failed: {}", vs_path, vs_err)
        return window.main_shader, .READ_ERROR
    }
    fs_filedata, fs_err := read_entire_file(fs_path)
    if fs_err != os.ERROR_NONE {
        fmt.printfln("loading frag shader file '{}' failed: {}", fs_path, fs_err)
        return window.main_shader, .READ_ERROR
    }

    if (vs_err != os.ERROR_NONE) || (fs_err != os.ERROR_NONE) {
        return window.main_shader, .PATH_ERROR
    }

    temp_shader := sg.make_shader(
        sg.Shader_Desc {
            vertex_func = {source = strings.unsafe_string_to_cstring(string(vs_filedata))},
            fragment_func = {source = strings.unsafe_string_to_cstring(string(fs_filedata))},
            /*uniform_blocks = [8]sg.Shader_Uniform_Block {
                0 = {
                    stage = .VERTEX,
                    size = 64,
                    glsl_uniforms = [16]sg.Glsl_Shader_Uniform {
                        0 = {type = .FLOAT4, array_count = 4, glsl_name = "vs_params"},
                    },
                },
            },*/
        },
    )

    if sg.query_shader_state(temp_shader) == sg.Resource_State.VALID {
        return temp_shader, .NONE
    }
    return window.main_shader, .COMPILE_ERROR
}

init_pipeline :: proc(shader: sg.Shader) -> sg.Pipeline {
    return sg.make_pipeline(
        {
            shader = shader,
            //index_type = .UINT16,
            cull_mode = .BACK,
            blend_color = {1.0, 1.0, 1.0, 1.0},
            colors = [4]sg.Color_Target_State {
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
    )
}

remake_main_pipeline :: proc(shader: sg.Shader) {
    sg.destroy_shader(window.main_shader)
    sg.destroy_pipeline(window.pipeline)
    window.main_shader = shader
    window.pipeline = init_pipeline(window.main_shader)
}

//////////////////////////////////////////////////////
// note(isak): texture api

texture_create :: proc(x, y: i32, pixels: rawptr) -> (u32, Texture_Handle) {
    texture: u32
    gl.CreateTextures(gl.TEXTURE_2D, 1, &texture)
    gl.TextureStorage2D(texture, 1, gl.RGBA8, x, y)
    gl.TextureSubImage2D(texture, 0, 0, 0, x, y, gl.RGBA, gl.UNSIGNED_BYTE, pixels)
    
    gl.TextureParameteri(texture, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.TextureParameteri(texture, gl.TEXTURE_MIN_FILTER, gl.LINEAR);

    // note(isak): this makes texture state immutable
    tex_handle := gl.GetTextureHandleARB(texture)

    return texture, tex_handle
}

texture_from_data :: proc(x, y: i32, data_rgba: []u32) -> Texture {
    result: Texture = {
        x = x,
        y = y
    }
    result.tex_id, result.tex_handle = texture_create(x, y, raw_data(data_rgba))
    return result
}

texture_from_file :: proc(path: string) -> (Texture, os.Error) {
    result: Texture
    result.path = path

    data, err := read_entire_file(path)
    if err != os.General_Error.None {
        return result, err
    }
    
    channels: i32
    pixels := stbi.load_from_memory(raw_data(data[:]), i32(len(data)), &result.x, &result.y, &channels, 4)
    if channels != 4 {
        fmt.println("image with less than 4 channels unhandled:", path)
        assert(channels == 4)
    }
    result.tex_id, result.tex_handle = texture_create(result.x, result.y, pixels)

    return result, err
}

prepare_textures_for_rendering :: proc() {
    pbo_bind(&window.texture_buffer, 2)
    textures := pbo_get_current(&window.texture_buffer)

    textures[0] = window.white_texture.tex_handle

    num_elements := 1
    for element in Skin_Element {
        textures[num_elements] = window.skin_textures[element].tex_handle
        num_elements += 1
    }


    for i in 0..<num_elements {
        gl.MakeTextureHandleResidentARB(textures[i])
    }
}


//////////////////////////////////////////////////////
// note(isak): draw api

batch_begin :: proc(batch: ^Vertex_Batch) {
    pbo_bind(&window.vertex_buffer, 0)
    pbo_bind(&window.index_buffer, 1)
    pbo_lock(&window.vertex_buffer)
    pbo_lock(&window.index_buffer)

    batch.vertexCount = 0
    batch.indexCount = 0

    batch.vertex_buffer = pbo_get_current(&window.vertex_buffer)
    batch.index_buffer = pbo_get_current(&window.index_buffer)
}

batch_end :: proc(batch: ^Vertex_Batch) {
    pbo_wait(&window.vertex_buffer)
    pbo_wait(&window.index_buffer)

    sg.draw(0, batch.indexCount, 1)

    pbo_increment_index(&window.vertex_buffer)
    pbo_increment_index(&window.index_buffer)
}

push_quad :: proc(batch: ^Vertex_Batch, pos1, pos2, pos3, pos4: vec2, color: vec4, tex_index: u32) {
    if batch.vertexCount + 4 > batch_max_vertices {
        batch_end(batch)
        batch_begin(batch)
    }
    
    #no_bounds_check {
        vert_i := batch.vertexCount
        verts := batch.vertex_buffer
        verts[vert_i + 0].pos = pos1; verts[vert_i + 0].uv = {0, 0}
        verts[vert_i + 1].pos = pos2; verts[vert_i + 1].uv = {1, 0}
        verts[vert_i + 2].pos = pos3; verts[vert_i + 2].uv = {0, 1}
        verts[vert_i + 3].pos = pos4; verts[vert_i + 3].uv = {1, 1}
        for i in 0..<4 {
            verts[vert_i + u32(i)].color = color
            verts[vert_i + u32(i)].tex_index = tex_index
        }

        index_i := batch.indexCount
        indices := batch.index_buffer
        indices[index_i + 0] = vert_i + 0
        indices[index_i + 1] = vert_i + 2
        indices[index_i + 2] = vert_i + 1
        indices[index_i + 3] = vert_i + 1
        indices[index_i + 4] = vert_i + 2
        indices[index_i + 5] = vert_i + 3

        batch.vertexCount += 4
        batch.indexCount += 6
    }
}

push_rect :: proc(batch: ^Vertex_Batch, rect: _Rect(f32), color: vec4, tex_index: u32 = 0) {
    push_quad(batch, {rect.x,          rect.y         },
                     {rect.x,          rect.y + rect.h},
                     {rect.x + rect.w, rect.y         },
                     {rect.x + rect.w, rect.y + rect.h}, color, tex_index)
}

push_screenspace_rect :: proc(batch: ^Vertex_Batch, rect: Window_Rect, color: vec4, tex_index: u32 = 0) {
    push_rect(batch, to_clipspace_rect(rect), color, tex_index)
}

push_layout_rect :: proc(batch: ^Vertex_Batch, rect: _Rect($T), anchor: Layout_Anchor, color: vec4, tex_index: u32 = 0) {
    push_rect(batch, rect_translate_by_anchor(rect, anchor), color, tex_index) 
}
push_screenspace_layout_rect :: proc(batch: ^Vertex_Batch, rect: _Rect($T), anchor: Layout_Anchor, color: vec4, tex_index: u32 = 0) {
    push_screenspace_rect(batch, rect_translate_by_anchor(rect, anchor), color, tex_index) 
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
    return {
        x = f32(rect.x) / f32(window.rect.w),
        y = f32(rect.y) / f32(window.rect.h),
        w = f32(rect.w) / f32(window.rect.w),
        h = f32(rect.h) / f32(window.rect.h)
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

// not needed...?
rect_translate_to_window :: proc(inner: _Rect(f32)) -> _Rect(f32) {
    return {
        x = inner.x / f32(window.rect.w),
        y = inner.y / f32(window.rect.h),
        w = inner.w / f32(window.rect.w),
        h = inner.h / f32(window.rect.h)
    }
}

/*
layout_rect_translate_to_window :: proc(inner: Layout_Rect) -> Rect {
    i := rect_translate_by_anchor(inner.rect, inner.anchor)
    return {
        x = i.x / f32(window.rect.w),
        y = i.y / f32(window.rect.h),
        w = i.w / f32(window.rect.w),
        h = i.h / f32(window.rect.h)
    }
}
*/
