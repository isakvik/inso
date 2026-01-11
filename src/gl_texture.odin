package notosu

import "core:fmt"
import os "core:os/os2"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"


//////////////////////////////////////////////////////
// note(isak): textures

texture_create :: proc() -> u32 {
    texture: u32
    gl.CreateTextures(gl.TEXTURE_2D, 1, &texture)
    gl.TextureParameteri(texture, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TextureParameteri(texture, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_S, gl.REPEAT)
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_T, gl.REPEAT)
    return texture
}

_texture_init :: proc(x, y: i32, internal_format: u32 = gl.RGBA8) -> (u32, Texture_Handle) {
    texture := texture_create()
    gl.TextureStorage2D(texture, 1, internal_format, x, y)

    // note(isak): this makes texture state (not data) immutable
    tex_handle := gl.GetTextureHandleARB(texture)

    return texture, tex_handle
}

_texture_init_with_data :: proc(
    x, y: i32,
    pixels: rawptr, 
    internal_format: u32 = gl.RGBA8,
    format: u32 = gl.RGBA
) -> (u32, Texture_Handle) {
    texture, tex_handle := _texture_init(x, y, internal_format)
    gl.TextureSubImage2D(texture, 0, 0, 0, x, y, format, gl.UNSIGNED_BYTE, pixels)
    return texture, tex_handle
}

_texture_reinit :: proc(texture: ^Texture, x, y: i32, pixels: rawptr) {
    gl.MakeTextureHandleNonResidentARB(texture.tex_handle)

    texture_delete({texture.tex_id})
    texture.tex_id, texture.tex_handle = 
        _texture_init(x, y, texture.internal_format)

    texture.w = x
    texture.h = y

    gl.MakeTextureHandleResidentARB(texture.tex_handle)
}

texture_delete :: proc(textures: []u32) {
    gl.DeleteTextures(i32(len(textures)), raw_data(textures))
}


texture_from_size :: proc(
    x, y: i32,
    internal_format: u32 = gl.RGBA8,
    format: u32 = gl.RGBA
) -> Texture {
    result: Texture = {
        w = x,
        h = y,
        format = format,
        internal_format = internal_format,
    }
    result.tex_id, result.tex_handle = _texture_init(x, y, internal_format)
    return result
}

texture_from_data :: proc(width, height: i32,
    data: rawptr,
    internal_format: u32 = gl.RGBA8,
    format: u32 = gl.RGBA
) -> Texture {
    result: Texture = {
        w = width,
        h = height,
        format = format,
        internal_format = internal_format,
    }
    result.tex_id, result.tex_handle = _texture_init_with_data(width, height, data, internal_format, format)
    return result
}

texture_from_file :: proc(path: string) -> (Texture, os.Error) {
    result: Texture
    result.path = path

    data, err := read_entire_file(path, context.temp_allocator)
    if err != os.General_Error.None {
        return result, err
    }
    
    channels: i32
    pixels := stbi.load_from_memory(raw_data(data[:]), i32(len(data)), &result.w, &result.h, &channels, 4)
    if channels != 4 {
        fmt.println("image with less than 4 channels unhandled:", path)
        assert(channels == 4)
    }
    result.tex_id, result.tex_handle = _texture_init_with_data(result.w, result.h, pixels)

    return result, err
}


texture_write_ptr_to :: proc(texture: Texture, rect: Rect, pixels: rawptr, pixel_count: int) {
    assert(int(rect.w * rect.h) <= pixel_count)
    gl.TextureSubImage2D(texture.tex_id, 0, i32(rect.x), i32(rect.y), i32(rect.w), i32(rect.h), 
        texture.format, gl.UNSIGNED_BYTE, pixels)
}

texture_write_u32_to :: proc(texture: Texture, rect: Rect, pixels: []u32) {
    texture_write_ptr_to(texture, rect, raw_data(pixels), len(pixels))
}

texture_write_to :: proc {
    texture_write_ptr_to,
    texture_write_u32_to
}
