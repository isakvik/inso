package notosu

import "core:fmt"
import os "core:os"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"


//////////////////////////////////////////////////////
// note(isak): textures
// all textures are GL_TEXTURE_2D_ARRAY; single images use 1 layer.
// uv.z in the quad carries the layer index for frame selection.

Texture_Wrap :: enum {
    CLAMP,   // note(isak): default — edge samples clamp, no bleed
    REPEAT,  // note(isak): tiling, e.g. scrolling backgrounds / render fx
}

_gl_wrap :: proc(wrap: Texture_Wrap) -> i32 {
    switch wrap {
    case .CLAMP:  return gl.CLAMP_TO_EDGE
    case .REPEAT: return gl.REPEAT
    }
    return gl.CLAMP_TO_EDGE
}

texture_create :: proc(wrap: Texture_Wrap = .CLAMP) -> u32 {
    texture: u32
    gl.CreateTextures(gl.TEXTURE_2D_ARRAY, 1, &texture)
    gl.TextureParameteri(texture, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TextureParameteri(texture, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_S, _gl_wrap(wrap))
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_T, _gl_wrap(wrap))
    return texture
}

_texture_init :: proc(x, y: i32, layers: i32 = 1, internal_format: u32 = gl.RGBA8, wrap: Texture_Wrap = .CLAMP) -> (u32, Texture_Handle) {
    texture := texture_create(wrap)
    gl.TextureStorage3D(texture, 1, internal_format, x, y, layers)

    tex_handle: Texture_Handle
    if window.bindless_supported {
        // note(isak): this makes texture state (not data) immutable
        tex_handle = gl.GetTextureHandleARB(texture)
    }

    return texture, tex_handle
}

_texture_init_with_data :: proc(
    x, y: i32,
    pixels: rawptr,
    layer: i32 = 0,
    internal_format: u32 = gl.RGBA8,
    format: u32 = gl.RGBA,
    wrap: Texture_Wrap = .CLAMP
) -> (u32, Texture_Handle) {
    texture, tex_handle := _texture_init(x, y, 1, internal_format, wrap)
    gl.TextureSubImage3D(texture, 0, 0, 0, layer, x, y, 1, format, gl.UNSIGNED_BYTE, pixels)
    return texture, tex_handle
}

_texture_reinit :: proc(texture: ^Texture, x, y: i32, pixels: rawptr) {
    if window.bindless_supported {
        gl.MakeTextureHandleNonResidentARB(texture.tex_handle)
    }

    texture_free({texture.tex_id})
    texture.tex_id, texture.tex_handle =
        _texture_init(x, y, 1, texture.internal_format, texture.wrap)

    texture.w = x
    texture.h = y
    texture.layer_count = 1

    if window.bindless_supported {
        gl.MakeTextureHandleResidentARB(texture.tex_handle)
    }
}

texture_free :: proc(textures: []u32) {
    gl.DeleteTextures(i32(len(textures)), raw_data(textures))
}

texture_cleanup :: proc(texture: ^Texture) {
    // note(isak): a resident bindless handle keeps its texture's storage alive even after DeleteTextures,
    // so it must go non-resident first or the GPU memory leaks. teardown can run mid-frame while the
    // handle is still resident from prepare_textures_for_rendering.
    if window.bindless_supported && texture.tex_handle != 0 {
        gl.MakeTextureHandleNonResidentARB(texture.tex_handle)
    }
    texture_free({texture.tex_id})
    texture.tex_id = 0
    texture.tex_handle = 0
}


texture_from_size :: proc(
    x, y: i32,
    internal_format: u32 = gl.RGBA8,
    format: u32 = gl.RGBA,
    wrap: Texture_Wrap = .CLAMP
) -> Texture {
    result: Texture = {
        w = x,
        h = y,
        layer_count = 1,
        format = format,
        internal_format = internal_format,
        wrap = wrap,
    }
    result.tex_id, result.tex_handle = _texture_init(x, y, 1, internal_format, wrap)
    return result
}

texture_from_data :: proc(width, height: i32,
    data: rawptr,
    internal_format: u32 = gl.RGBA8,
    format: u32 = gl.RGBA,
    wrap: Texture_Wrap = .CLAMP
) -> Texture {
    result: Texture = {
        w = width,
        h = height,
        layer_count = 1,
        format = format,
        internal_format = internal_format,
        wrap = wrap,
    }
    result.tex_id, result.tex_handle = _texture_init_with_data(width, height, data, 0, internal_format, format, wrap)
    return result
}

texture_from_file :: proc(path: string, wrap: Texture_Wrap = .CLAMP) -> (Texture, os.Error) {
    result: Texture
    result.path = path
    result.layer_count = 1
    result.wrap = wrap

    data, err := read_entire_file(path, context.temp_allocator)
    if err != os.General_Error.None {
        return result, err
    }

    channels: i32
    pixels := stbi.load_from_memory(raw_data(data[:]), i32(len(data)), &result.w, &result.h, &channels, 4)
    defer stbi.image_free(pixels)
    result.tex_id, result.tex_handle = _texture_init_with_data(result.w, result.h, pixels, 0, gl.RGBA8, gl.RGBA, wrap)
    return result, err
}

// note(isak): creates a GL_TEXTURE_2D_ARRAY with one layer per image in paths.
// all images must have the same dimensions (asserted on the first load).
texture_array_from_files :: proc(paths: []string, wrap: Texture_Wrap = .CLAMP) -> (result: Texture, err: os.Error) {
    if len(paths) == 0 do return

    result.layer_count = i32(len(paths))
    result.format = gl.RGBA
    result.internal_format = gl.RGBA8
    result.wrap = wrap

    // note(isak): load all frames, upload each as its layer
    for path, i in paths {
        data, derr := read_entire_file(path, context.temp_allocator)
        if derr != os.General_Error.None {
            err = derr
            return
        }

        w, h, channels: i32
        pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &channels, 4)
        defer stbi.image_free(pixels)

        if i == 0 {
            result.w = w
            result.h = h
            result.tex_id = texture_create(wrap)
            gl.TextureStorage3D(result.tex_id, 1, result.internal_format, w, h, result.layer_count)
            if window.bindless_supported {
                result.tex_handle = gl.GetTextureHandleARB(result.tex_id)
            }
        } else {
            assert(w == result.w && h == result.h, "texture_array_from_files: all frames must be the same size")
        }

        gl.TextureSubImage3D(result.tex_id, 0, 0, 0, i32(i), w, h, 1, result.format, gl.UNSIGNED_BYTE, pixels)
    }

    return result, nil
}


texture_write_ptr_to :: proc(texture: Texture, rect: Rect, pixels: rawptr, pixel_count: int) {
    assert(int(rect.w * rect.h) <= pixel_count)
    gl.TextureSubImage3D(texture.tex_id, 0, i32(rect.x), i32(rect.y), 0, i32(rect.w), i32(rect.h), 1,
        texture.format, gl.UNSIGNED_BYTE, pixels)
}

texture_write_u32_to :: proc(texture: Texture, rect: Rect, pixels: []u32) {
    texture_write_ptr_to(texture, rect, raw_data(pixels), len(pixels))
}

texture_write_to :: proc {
    texture_write_ptr_to,
    texture_write_u32_to
}
