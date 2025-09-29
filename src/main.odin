package notosu

import "core:sys/windows"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf16"

import lua "vendor:lua/5.4"

import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"

vector3 :: struct { x, y, z: f32 }
vec3 :: vector3
mat4 :: matrix[4,4]f32

_rdtsc_frequency := f64(sdl.GetPerformanceFrequency())
_rdtsc_start_time: f64

current_time :: proc() -> f64 {
    return f64(sdl.GetPerformanceCounter()) / _rdtsc_frequency
}

time_since_beginning_of_program :: proc() -> f64 {
    return current_time() - _rdtsc_start_time
}

/*
note(isak):

mapset definition:
.osu (core, lets you interface with existing editors)
.notosu (additional interface, lua scripting capabilities)
    additional .lua files (for import utilities)
.glsl (shaders, either merged glsl or .vs.glsl/.fs.glsl)

communication layer:
core runtime info such as map time and objects
- state buffer
- graphics buffer (will be uploaded to gpu, loaded pipelines (shaders) work with it)
    are these just defined as lua metatables?

-- todos

general:
ui core (map selector, skin select?)
.osu support
win32 directory watch
sokol pipeline rendering

play mode:
audio play (miniaudio)
    desync proofing (always wait for sound to be able to be played, like osu (so device errors will just freeze the game))
input handling

figure out if we need some graphical core of a playfield (i'm thinking we have some default implementation; optionally hide it and let people render whatever based on mapset data)

editor mode (viewer mode only? edit functionality is probably low priority):
automatic reload
scrubbing support (jump to arbitrary time, display content)

*/

// hey, i know you hate questions like this but i'm having a hard time getting started on getting started programming. is it better to get started with setting 
// up your environment, or should i do all the work in my head so i can feel good about not having done anything at all? thanks, 200 word essay due tomorrow

Rect :: struct {
    x, y, w, h: i32
}

window: struct {
    rect: Rect,

    handle: ^sdl.Window,
    gl_context: sdl.GLContext,

    main_shader: sg.Shader,
    pipeline: sg.Pipeline,
    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,
}

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

remake_pipeline :: proc(shader: sg.Shader) {
    sg.destroy_pipeline(window.pipeline)
    window.pipeline = init_pipeline(shader)
}

init_window :: proc(rect: Rect) {
    window.rect = rect
    window.handle = sdl.CreateWindow("notosu!", rect.w, rect.h, sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    window.gl_context = sdl.GL_CreateContext(window.handle)

    sdl.GetWindowPosition(window.handle, &window.rect.x, &window.rect.y)

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
}

cleanup_window :: proc() {
    sdl.GL_DestroyContext(window.gl_context)
    sdl.DestroyWindow(window.handle)
}


main :: proc() {
    _rdtsc_start_time = current_time()

    L := lua.L_newstate()
    defer lua.close(L)
    
    lua.L_openlibs(L)
    
    script: cstring = "print('Hello from Lua!')"
    lua.L_dostring(L, script)

    if (!sdl.Init(sdl.INIT_VIDEO)) {
        fmt.printfln("SDL init error: {}", sdl.GetError())
        return;
    }

    init_window({w = 1024, h = 576})
    defer cleanup_window()
    
    sg.setup({
        environment = { defaults = {
                sample_count = 4,
                color_format = sg.Pixel_Format.RGBA8,
                depth_format = sg.Pixel_Format.DEPTH_STENCIL
        }},
        logger = { func = slog.func }
    })

    vs_path := "../shaders/main.vs.glsl"
    fs_path := "../shaders/main.fs.glsl"
    
    {
        err: shader_error
        window.main_shader, err = init_shader(vs_path, fs_path)
        assert(err == .NONE)
    }
    
    window.pipeline = init_pipeline(window.main_shader)
    defer sg.destroy_pipeline(window.pipeline)

    
    // cube vertex buffer
    vertices := [?]f32 {
        -1.0, -1.0, -1.0,   1.0, 0.0, 0.0, 1.0,
         1.0, -1.0, -1.0,   1.0, 0.0, 0.0, 1.0,
         1.0,  1.0, -1.0,   1.0, 0.0, 0.0, 1.0,
        -1.0,  1.0, -1.0,   1.0, 0.0, 0.0, 1.0,

        -1.0, -1.0,  1.0,   0.0, 1.0, 0.0, 1.0,
         1.0, -1.0,  1.0,   0.0, 1.0, 0.0, 1.0,
         1.0,  1.0,  1.0,   0.0, 1.0, 0.0, 1.0,
        -1.0,  1.0,  1.0,   0.0, 1.0, 0.0, 1.0,

        -1.0, -1.0, -1.0,   0.0, 0.0, 1.0, 1.0,
        -1.0,  1.0, -1.0,   0.0, 0.0, 1.0, 1.0,
        -1.0,  1.0,  1.0,   0.0, 0.0, 1.0, 1.0,
        -1.0, -1.0,  1.0,   0.0, 0.0, 1.0, 1.0,

        1.0, -1.0, -1.0,    1.0, 0.5, 0.0, 1.0,
        1.0,  1.0, -1.0,    1.0, 0.5, 0.0, 1.0,
        1.0,  1.0,  1.0,    1.0, 0.5, 0.0, 1.0,
        1.0, -1.0,  1.0,    1.0, 0.5, 0.0, 1.0,

        -1.0, -1.0, -1.0,   0.0, 0.5, 1.0, 1.0,
        -1.0, -1.0,  1.0,   0.0, 0.5, 1.0, 1.0,
         1.0, -1.0,  1.0,   0.0, 0.5, 1.0, 1.0,
         1.0, -1.0, -1.0,   0.0, 0.5, 1.0, 1.0,

        -1.0,  1.0, -1.0,   1.0, 0.0, 0.5, 1.0,
        -1.0,  1.0,  1.0,   1.0, 0.0, 0.5, 1.0,
         1.0,  1.0,  1.0,   1.0, 0.0, 0.5, 1.0,
         1.0,  1.0, -1.0,   1.0, 0.0, 0.5, 1.0,
    }
    
    window.bindings.vertex_buffers[0] = sg.make_buffer({
        data = { ptr = &vertices, size = size_of(vertices) },
    })
    defer sg.destroy_buffer(window.bindings.vertex_buffers[0])

    // create an index buffer for the cube
    indices := [?]u16 {
        0, 1, 2,  0, 2, 3,
        6, 5, 4,  7, 6, 4,
        8, 9, 10,  8, 10, 11,
        14, 13, 12,  15, 14, 12,
        16, 17, 18,  16, 18, 19,
        22, 21, 20,  23, 22, 20,
    }
    window.bindings.index_buffer = sg.make_buffer({
        usage = { index_buffer = true },
        data = { ptr = &indices, size = size_of(indices) },
    })
    defer sg.destroy_buffer(window.bindings.index_buffer)


    shaders_watch := win32_init_directory_watch("../shaders/")

    /*
        todo(isak): some research on timestep (consistent deltatime) would be prudent
        https://jakubtomsu.github.io/posts/fixed_timestep_without_interpolation/
    */
    time_current_frame := current_time()
    time_last_frame := time_current_frame
    dt := 0.0

    active := true
    event: sdl.Event

    for active {

        // message handling, time handling
        
        for sdl.PollEvent(&event) {
            if event.type == sdl.EventType.QUIT {
                active = false
            }
            
            if event.type == sdl.EventType.WINDOW_RESIZED {
                window.rect.w = event.window.data1
                window.rect.h = event.window.data2
                window.swapchain.width = event.window.data1
                window.swapchain.height = event.window.data2
            }

            
        }

        time_last_frame = time_current_frame
        time_current_frame = current_time()
        dt := time_current_frame - time_last_frame

        // todo(isak): begin frame, set up mapped uniform block

        // game update

        vs: struct {
            mvp: mat4
        }
        vs.mvp = {1,0,0,0, 0,1,0,0, 0,0,1,2, 0,0,5,1}

        // end frame

        sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
        sg.apply_pipeline(window.pipeline)
        sg.apply_bindings(window.bindings)
        sg.apply_uniforms(0, { ptr = &vs, size = size_of(vs) })
        sg.draw(0, 36, 1)
        sg.end_pass()
        sg.commit()
        
        sdl.GL_SwapWindow(window.handle)

        // platform directory watch

        win32_get_directory_changes(&shaders_watch)
        win32_print_error()
        if shaders_watch.watch_bytes_written > 0 {
            notify := (^win32_file_notify_info)(&shaders_watch.notify_buffer)

            filename_cs16 := ([^]u16)(&notify.file_name)

            filename_buf: [windows.MAX_PATH]u16
            for i in 0 ..< notify.file_name_length {
                filename_buf[i] = filename_cs16[i]
            }
            filename_buf[notify.file_name_length] = 0

            switch (notify.action) {
                case windows.FILE_ACTION_MODIFIED:
                    fmt.printfln("%s", filename_buf)
            }
            
        }

        // profiling
        
        // todo(isak): generate texture, draw to bottom right in screenspace
    }

}
