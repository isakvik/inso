package notosu

import "core:fmt"
import "core:os"
import "core:strings"

import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"


main_vs_path :: "../shaders/main.vs.glsl"
main_fs_path :: "../shaders/main.fs.glsl"

shader_error :: enum {
    NONE,
    PATH_ERROR,
    COMPILE_ERROR
}

init_shader :: proc(vs_path, fs_path: string) -> (sg.Shader, shader_error) {
    vs_filedata, vs_err := os.read_entire_file_or_err(vs_path)
    if vs_err != os.ERROR_NONE {
        fmt.printfln("loading vert shader file '{}' failed: {}", vs_path, vs_err)
    }
    fs_filedata, fs_err := os.read_entire_file_or_err(fs_path)
    if fs_err != os.ERROR_NONE {
        fmt.printfln("loading frag shader file '{}' failed: {}", fs_path, fs_err)
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
        layout = {
            attrs = [16]sg.Vertex_Attr_State{
                0 = {format = sg.Vertex_Format.FLOAT3},
                1 = {format = sg.Vertex_Format.FLOAT4},
            }
        },
        index_type = .UINT16,
        cull_mode = .BACK,
        depth = {
            compare = .LESS_EQUAL,
            write_enabled = true,
        },
    })
}

remake_main_pipeline :: proc(shader: sg.Shader) {
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
