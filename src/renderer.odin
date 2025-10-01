package notosu

import "core:fmt"
import "core:os"
import "core:strings"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"


main_vs_path :: "../shaders/main.vs.glsl"
main_fs_path :: "../shaders/main.fs.glsl"


init_graphics :: proc() {
    gl.load_up_to(4, 6, sdl.gl_set_proc_address)

    sg.setup({
        environment = { defaults = {
                sample_count = 4,
                color_format = sg.Pixel_Format.RGBA8,
                depth_format = sg.Pixel_Format.DEPTH_STENCIL
        }},
        logger = { func = slog.func }
    })
    
    {
        err: Shader_Error
        window.main_shader, err = init_shader(main_vs_path, main_fs_path)
        assert(err == .NONE)
    }
    
    window.pipeline = init_pipeline(window.main_shader)
    window.gpu_buffer = pbo_init(64*1024*1024)
}


Shader_Error :: enum {
    NONE,
    READ_ERROR,
    PATH_ERROR,
    COMPILE_ERROR
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

    temp_shader := sg.make_shader(sg.Shader_Desc{
        vertex_func = {source = strings.unsafe_string_to_cstring(string(vs_filedata)) },
        fragment_func = {source = strings.unsafe_string_to_cstring(string(fs_filedata)) },
        uniform_blocks = [8]sg.Shader_Uniform_Block{
            0 = { stage = .VERTEX,
                size = 64,
                glsl_uniforms = [16]sg.Glsl_Shader_Uniform{
                    0 = { type = .FLOAT4, array_count = 4, glsl_name = "vs_params" }
                }
            }
        }
    })

    if sg.query_shader_state(temp_shader) == sg.Resource_State.VALID {
        return temp_shader, .NONE
    }
    return window.main_shader, .COMPILE_ERROR
}

init_pipeline :: proc(shader: sg.Shader) -> sg.Pipeline {
    return sg.make_pipeline({
        shader = shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = { 0.0, 0.0, 0.0, 1.0 },
    })
}

remake_main_pipeline :: proc(shader: sg.Shader) {
    sg.destroy_shader(window.main_shader)
    sg.destroy_pipeline(window.pipeline)
    window.main_shader = shader
    window.pipeline = init_pipeline(window.main_shader)
}

process_main_shader_changes :: proc(watch: ^Win32_Directory_Watch) {
    updated_systems := mapset_check_system_file_watch(watch)

    if updated_systems[.SHADERS] {
        temp_shader, err := init_shader(main_vs_path, main_fs_path)
        if err == .NONE {
            fmt.println("reloaded shaders")
            remake_main_pipeline(temp_shader)
        } else {
            fmt.println("shader error: {}", err)
        }
    }
}

// persistent triple buffer object

_pbo_multiple_count :: 3

Persistent_Buffer :: struct {
    id: u32,
    begin: rawptr,
    size: int,

    current_index: u8,
    offsets: [_pbo_multiple_count]int,
    sync: [_pbo_multiple_count]gl.sync_t
}

pbo_init :: proc(size: int) -> Persistent_Buffer {
    result: Persistent_Buffer
    gl.CreateBuffers(1, &result.id)

    flags := u32(gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
    gl.NamedBufferStorage(result.id, size * _pbo_multiple_count, nil, flags)
    result.begin = gl.MapNamedBufferRange(result.id, 0, size * _pbo_multiple_count, flags)

    result.size = size
    result.current_index = 0
    for i in 0..<_pbo_multiple_count {
        result.offsets[i] = size * i
    }

    return result
}

pbo_lock :: proc(buf: ^Persistent_Buffer) {
    sync := buf.sync[buf.current_index]
    if sync > nil {
        for true {
            waitReturn := gl.ClientWaitSync(sync, gl.SYNC_FLUSH_COMMANDS_BIT, 0);
            if (waitReturn == gl.ALREADY_SIGNALED ||
                waitReturn == gl.CONDITION_SATISFIED ||
                waitReturn == gl.WAIT_FAILED) {
                break;
            }
        }
    }
}

pbo_unlock :: proc(buf: ^Persistent_Buffer) {
    sync := buf.sync[buf.current_index]
    if sync > nil {
        gl.DeleteSync(sync)
    }
    sync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
}

pbo_get_current :: proc(buf: ^Persistent_Buffer) -> rawptr {
    return rawptr(uintptr(buf.begin) + uintptr(buf.offsets[buf.current_index]))
}

pbo_bind :: proc(buf: ^Persistent_Buffer, bindIndex: u32) {
    gl.BindBufferRange(
        gl.SHADER_STORAGE_BUFFER,
        bindIndex,
        buf.id,
        buf.offsets[buf.current_index],
        buf.size)
}

pbo_increment_index :: proc(buf: ^Persistent_Buffer) {
    buf.current_index = (buf.current_index + 1) % _pbo_multiple_count
}

pbo_cleanup :: proc(buf: ^Persistent_Buffer) {
    gl.UnmapNamedBuffer(buf.id)
    gl.DeleteBuffers(1, &buf.id);
}

Vertex :: struct {
    pos: vec2,
    uv: vec2,
    color: vec4
}
