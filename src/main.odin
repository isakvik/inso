package notosu

import "core:math"
import "core:sys/windows"
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:unicode/utf16"
import "core:path/filepath"
import "core:strings"
import "core:mem/virtual"

import lua "vendor:lua/5.4"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"

vec2 :: struct { x, y: f32 }
vec3 :: struct { x, y, z: f32 }
vec4 :: struct { x, y, z, w: f32 }
mat4 :: matrix[4,4]f32

Window_Rect :: _Rect(i32)

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

communication layer:
core runtime info such as map time and objects
- state buffer
- graphics buffer (will be uploaded to gpu, loaded pipelines (shaders) work with it)
    are these just defined as lua metatables?

-- todos

general:
ui core (map selector, skin select?)
.osu support

play mode:
audio play (miniaudio)
    desync proofing (always wait for sound to be able to be played, like osu (so device errors will just freeze the game))
input handling

figure out if we need some graphical core of a playfield (i'm thinking we have some default implementation; optionally hide it and let people render whatever based on mapset data)

editor mode:
(viewer mode only? edit functionality is probably low priority, osu can be used for the map)
automatic reload
scrubbing support (jump to arbitrary time, display content)

*/

// hey, i know you hate questions like this but i'm having a hard time getting started on getting started programming. is it better to get started with setting 
// up your environment, or should i do all the work in my head so i can feel good about not having done anything at all? thanks, 200 word essay due tomorrow

memory: struct {
    // note(isak): this is to be used for mapset runtime data, such as timing state, 
    // judgements, etc. (fill in)
    // cleared on mapset load
    mapset_allocator: runtime.Allocator,
    mapset_arena: virtual.Arena,
}

// note(isak): this should take care of error printing
init_memory :: proc() -> runtime.Allocator_Error {
    alloc_err := virtual.arena_init_growing(&memory.mapset_arena) // note(isak): default size 1 MB
    if alloc_err != .None {
        fmt.println("mapset arena init error:", alloc_err)
        return alloc_err
    }
    memory.mapset_allocator = virtual.arena_allocator(&memory.mapset_arena)

    return .None
}

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
    texture_buffer: Persistent_Buffer(u64), // todo(isak): this doesn't need triple buffering

    white_texture: Texture,

    skin_textures: [Skin_Element]Texture,
}

lua_ctx: struct {
    state: ^lua.State
}

init_window :: proc(rect: Window_Rect) {
    window.rect = rect
    window.handle = sdl.CreateWindow("notosu!", rect.w, rect.h, sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 4)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 6)
    sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengl")

    sdl.GL_SetSwapInterval(0)
    sdl.SetWindowSurfaceVSync(window.handle, 0)
    window.gl_context = sdl.GL_CreateContext(window.handle)

    sdl.GetWindowPosition(window.handle, &window.rect.x, &window.rect.y)
    v := sdl.HideCursor()
}

cleanup_window :: proc() {
    sdl.GL_DestroyContext(window.gl_context)
    sdl.DestroyWindow(window.handle)
}


main :: proc() {
    _rdtsc_start_time = current_time()

    if init_memory() != .None {
        panic("memory init error")
    }

    current_dir := os.get_current_directory()
    if strings.compare("build", filepath.base(current_dir)) == 0 {
        os.set_current_directory(filepath.dir(current_dir))
    }


    lua_ctx.state = lua.L_newstate()
    defer lua.close(lua_ctx.state)
    
    lua.L_openlibs(lua_ctx.state)
    
    script: cstring = "print('Hello from Lua!')"
    lua.L_dostring(lua_ctx.state, script)


    if (!sdl.Init(sdl.INIT_VIDEO)) {
        fmt.printfln("SDL init error: {}", sdl.GetError())
        return
    }

    init_window({w = 1280, h = 720})
    defer cleanup_window()

    init_renderer()
    defer cleanup_renderer()
    
    // todo(isak): make a skin selector
    load_skin_textures("skins/gn/")
    prepare_textures_for_rendering()

    shaders_watch := win32_init_directory_watch("shaders/")

    {
        mapset_path := "songs/test/"
        mapset, ok := mapset_open_for_editing(mapset_path)
        if !ok {
            fmt.println("tried to open mapset, but failed:", mapset_path)
        }
    }


    /*
        todo(isak): some research on timestep (consistent deltatime) would be prudent
        https://jakubtomsu.github.io/posts/fixed_timestep_without_interpolation/
    */
    time_current_frame := current_time()
    time_last_frame := time_current_frame
    dt := 0.0

    frame_count: u64
    time_first_frame := time_current_frame

    /* todo(isak): more rendering stuff to do...
    
    - sg_desc (sg.begin) pipeline_pool_size... grow pipeline pool size to num layers in mapset?
    - create ui tree for menus?
    - font rendering (sdl? stb_truetype?)
    - slider rendering (dynamic texture surface)
    
    */
    
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
        
        mouse_x, mouse_y: i32
        mouse_xf, mouse_yf: f32
        mouse_flags := sdl.GetGlobalMouseState(&mouse_xf, &mouse_yf)
        sdl.GetWindowPosition(window.handle, &mouse_x, &mouse_y)

        mouse_x = i32(mouse_xf) - mouse_x
        mouse_y = i32(mouse_yf) - mouse_y

        time_last_frame = time_current_frame
        time_current_frame = current_time()
        dt := time_current_frame - time_last_frame

        begin_frame()
        
        _batch: Vertex_Batch
        batch := &_batch
        batch_begin(batch)
        
        // game update
        
        texture := u32(6 * (current_time() - time_first_frame)) % 6

        cursor_rect: Window_Rect = { mouse_x, mouse_y, 80, 80 }
        push_screenspace_layout_rect(batch, cursor_rect, .CENTER, {1,1,1,1}, texture)

        push_particle({
            rect = to_clipspace_rect(cursor_rect), 
            vel = {rand.float32()*2-1, rand.float32()*2-1},
            tex_index = texture
        })

        update_particles(dt)
        for i in 0..<particle_count {
            push_rect(batch, particles[i].rect, {1,1,1,1}, particles[i].tex_index)
        }
        
        // end frame
        
        debug_rect: Window_Rect = { window.rect.w, window.rect.h, 600, 200 }
        push_screenspace_layout_rect(batch, debug_rect, .BOTTOM_RIGHT, {1,1,1,0.25})

        end_frame(batch)

        process_main_shader_changes(&shaders_watch)

        // profiling
        
        // todo(isak): generate osu profiling texture, draw to bottom right in screenspace

        frame_count += 1
        if frame_count % 500 == 0 {
            fmt.println("fps:", f64(frame_count) / (time_current_frame - time_first_frame))
        }
    }
}

begin_frame :: proc() {
    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
    sg.apply_pipeline(window.pipeline)
}

end_frame :: proc(batch: ^Vertex_Batch) {
    
    batch_end(batch)
    //sg.apply_bindings(window.bindings)

    //sg.apply_uniforms(0, { ptr = &vs, size = size_of(vs) })
    sg.end_pass()
    sg.commit()
    
    sdl.GL_SwapWindow(window.handle)
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
