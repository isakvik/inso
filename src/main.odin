package notosu

import "base:runtime"
import "core:fmt"
import "core:math/linalg"

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
time synchronized audio play (desync proofing, essentially. check if miniaudio can be used)
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
    glContext: sdl.GLContext,

    pipeline: sg.Pipeline,
    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,

}

init_window :: proc(rect: Rect) {
    window.rect = rect
    window.handle = sdl.CreateWindow("notosu!", rect.w, rect.h, sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    window.glContext = sdl.GL_CreateContext(window.handle)

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
    sdl.GL_DestroyContext(window.glContext)
    sdl.DestroyWindow(window.handle)
}

osu_controller: struct {
    k1: bool,
    k2: bool,
    m1: bool,
    m2: bool,
    k1_key: sdl.Scancode,
    k2_key: sdl.Scancode
}

check_game_input :: proc(event: sdl.Event) {
    osu_controller.k1_key = sdl.Scancode.Z
    osu_controller.k2_key = sdl.Scancode.X
    if (event.type == sdl.EventType.KEY_DOWN) {
        if (event.key.scancode == osu_controller.k1_key && osu_controller.k1 == false) {
            osu_controller.k1 = true
            //fmt.println("k1 pressed!")
        }
        if (event.key.scancode == osu_controller.k2_key && osu_controller.k2 == false) {
            osu_controller.k2 = true
            //fmt.println("k2 pressed!")
        }
    }
    if (event.type == sdl.EventType.KEY_UP) {
        if (event.key.scancode == osu_controller.k1_key) {
            osu_controller.k1 = false
            //fmt.println("k1 released!")
        }
        if (event.key.scancode == osu_controller.k2_key) {
            osu_controller.k2 = false
            //fmt.println("k2 released!")
        }
    }
    if (event.type == sdl.EventType.MOUSE_BUTTON_DOWN) {
        if (event.button.button == sdl.BUTTON_LEFT) {
            osu_controller.m1 = true
            //fmt.println("m1 pressed!")
        }
        if (event.button.button == sdl.BUTTON_RIGHT) {
            osu_controller.m2 = true
            //fmt.println("m2 pressed!")
        }
    }
    if (event.type == sdl.EventType.MOUSE_BUTTON_UP) {
        if (event.button.button == sdl.BUTTON_LEFT) {
            osu_controller.m1 = false
            //fmt.println("m1 pressed!")
        }
        if (event.button.button == sdl.BUTTON_RIGHT) {
            osu_controller.m2 = false
            //fmt.println("m2 pressed!")
        }
    }
    /*
    if (osu_controller.k1) {
        fmt.println("k1 held!")
    }
    if (osu_controller.k2) {
        fmt.println("k2 held!")
    }
    if (osu_controller.m1) {
        fmt.println("m1 held!")
    }
    if (osu_controller.m2) {
        fmt.println("m2 held!")
    }*/
}

main :: proc() {
    _rdtsc_start_time = current_time()

    L := lua.L_newstate()
    defer lua.close(L)
    
    lua.L_openlibs(L)
    
    script: cstring = "print('Hello from Lua!')"
    lua.L_dostring(L, script)

    if (!sdl.Init(sdl.INIT_VIDEO)) {
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
    
    window.pipeline = sg.make_pipeline({
        shader = sg.make_shader(sg.Shader_Desc{ 
            vertex_func = {source = `
                #version 430

                uniform vec4 vs_params[4];
                layout(location = 0) in vec4 pos;
                layout(location = 1) in vec4 color0;

                out vec4 color;
                out vec2 uv;
            
                void main()
                {
                    gl_Position = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]) * pos;
                    color = color0;
                }`},
            fragment_func = {source = `
                #version 430

                layout(binding = 0) uniform sampler2D tex_smp;
            
                in vec4 color;
                
                out vec4 frag_color;
            
                void main()
                {
                    frag_color = color;
                }`},
            uniform_blocks = [8]sg.Shader_Uniform_Block{
                0 = { stage = .VERTEX,
                    size = 64,
                    glsl_uniforms = [16]sg.Glsl_Shader_Uniform{
                        0 = { type = .FLOAT4, array_count = 4, glsl_name = "vs_params" }
                    }
                }
            }
        }),
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


    // arbitrary state
    rx := f32(0.0)
    ry := f32(0.0)


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

            check_game_input(event)
        }

        time_last_frame = time_current_frame
        time_current_frame = current_time()
        dt := time_current_frame - time_last_frame

        // todo(isak): begin frame, set up mapped uniform block

        // game update

        rx += 60  * f32(dt)
        ry += 120 * f32(dt)

        vs: struct {
            mvp: mat4
        }
        vs.mvp = compute_mvp(rx, ry)


        // end frame

        sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
        sg.apply_pipeline(window.pipeline)
        sg.apply_bindings(window.bindings)
        sg.apply_uniforms(0, { ptr = &vs, size = size_of(mat4) })
        sg.draw(0, 36, 1)
        sg.end_pass()
        sg.commit()
        
        sdl.GL_SwapWindow(window.handle)

        // profiling
        
    }

}

compute_mvp :: proc (rx, ry: f32) -> mat4 {
    proj := linalg.matrix4_perspective(60.0 * linalg.RAD_PER_DEG, f32(window.rect.w) / f32(window.rect.h), 0.01, 10.0)
    view := linalg.matrix4_look_at_f32({0.0, -1.5, -6.0}, {}, {0.0, 1.0, 0.0})
    view_proj := proj * view
    rxm := linalg.matrix4_rotate_f32(rx * linalg.RAD_PER_DEG, {1.0, 0.0, 0.0})
    rym := linalg.matrix4_rotate_f32(ry * linalg.RAD_PER_DEG, {0.0, 1.0, 0.0})
    model := rxm * rym
    return view_proj * model
}

