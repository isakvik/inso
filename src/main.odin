package notosu

import "core:math"
import "core:sys/windows"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:unicode/utf16"

import lua "vendor:lua/5.4"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"

vec2 :: struct { x, y: f32 }
vec3 :: struct { x, y, z: f32 }
vec4 :: struct { x, y, z, w: f32 }
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

Window_Rect :: _Rect(i32)

window: struct {
    rect: Window_Rect,

    handle: ^sdl.Window,
    gl_context: sdl.GLContext,

    main_shader: sg.Shader,
    pipeline: sg.Pipeline,
    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,

    vertex_buffer: Persistent_Buffer(Vertex),
    index_buffer: Persistent_Buffer(u32),
}

init_window :: proc(rect: Window_Rect) {
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

    init_renderer()

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

    /* todo(isak): more rendering stuff to do...
    
    - sg_desc (sg.begin) pipeline_pool_size... grow pipeline pool size to num layers in mapset?
    - screenspace rendering size handling
        - groups
    - texture residency
    
    */ 

    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

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

        pbo_lock(&window.vertex_buffer)
        pbo_lock(&window.index_buffer)

        // game update

        // todo(isak): need a more intelligent bucketing and batching system....
        // a triple buffer for every layer seems overkill memory wise, since a fixed bucket
        // has to be allocated for each, so draw calls might need sorting (or depth testing), whichever
        // is less expensive... profile first.

        draw := begin_draw(.DEFAULT)

        s := i32(math.sin_f32(f32(time_since_beginning_of_program())) * 100)
                
        _debug_rect: Window_Rect = { s + window.rect.w, window.rect.h, 600, 200 }
        debug_rect := rect_translate_by_anchor(_debug_rect, .BOTTOM_RIGHT)

        debug_rect2: Rect = { 0, 0, 1, 0.5 }
        lol := rect_translate_to_inner(debug_rect2, debug_rect)
        
        push_screenspace_rect(draw, debug_rect, {0,0,0,0.25})
        push_screenspace_rect(draw, lol, {1,0,0,0.25})

        // end frame

        end_frame()

        process_main_shader_changes(&shaders_watch)

        // profiling
        
        // todo(isak): generate osu profiling texture, draw to bottom right in screenspace
    }

    pbo_cleanup(&window.vertex_buffer)
}

end_frame :: proc() {
    pbo_unlock(&window.vertex_buffer)
    pbo_unlock(&window.index_buffer)
    pbo_bind(&window.vertex_buffer, 0)
    pbo_bind(&window.index_buffer, 1)

    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
    sg.apply_pipeline(window.pipeline)

    //sg.apply_bindings(window.bindings)

    //sg.apply_uniforms(0, { ptr = &vs, size = size_of(vs) })
    sg.draw(0, renderer.draw_buckets[.DEFAULT].indexCount, 1)
    sg.end_pass()
    sg.commit()
    
    sdl.GL_SwapWindow(window.handle)

    pbo_increment_index(&window.vertex_buffer)
    pbo_increment_index(&window.index_buffer)
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
