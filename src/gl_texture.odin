package notosu

import "core:fmt"
import os "core:os/os2"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"


//////////////////////////////////////////////////////
// note(isak): textures

texture_init :: proc() -> u32 {
    texture: u32
    gl.CreateTextures(gl.TEXTURE_2D, 1, &texture)
    gl.TextureParameteri(texture, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TextureParameteri(texture, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_S, gl.REPEAT)
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_T, gl.REPEAT)
    return texture
}

texture_create :: proc(x, y: i32, pixels: rawptr) -> (u32, Texture_Handle) {
    texture := texture_init()
    gl.TextureStorage2D(texture, 1, gl.RGBA8, x, y)
    gl.TextureSubImage2D(texture, 0, 0, 0, x, y, gl.RGBA, gl.UNSIGNED_BYTE, pixels)

    // note(isak): this makes texture state immutable
    tex_handle := gl.GetTextureHandleARB(texture)

    return texture, tex_handle
}

texture_delete :: proc(textures: []u32) {
    gl.DeleteTextures(i32(len(textures)), raw_data(textures))
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

texture_write_to :: proc(texture: Texture, rect: Window_Rect, pixels: []u32) {
    assert(int(rect.w * rect.h) <= len(pixels))
    gl.TextureSubImage2D(texture.tex_id, 0, rect.x, rect.y, rect.w, rect.h, 
        gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
}
