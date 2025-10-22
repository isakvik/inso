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
import "core:mem"
import "core:mem/virtual"

import lua "vendor:lua/5.4"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"
import miniaudio "vendor:miniaudio"

vec2 :: struct { x, y: f32 }
vec3 :: struct { x, y, z: f32 }
vec4 :: struct { x, y, z, w: f32 }
vec4_from :: proc(v: vec3, a: f32) -> vec4 { return {v.x,v.y,v.z,a}}

mat4 :: matrix[4,4]f32

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
    renderer: Renderer,

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
    profiler_texture: Texture,

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


Mouse_State :: struct {
    x, y: i32,
    xf, yf: f32
}

Button_State :: struct {
    is_down, was_down: bool
}

osu_controller: struct {
    k1, k2, m1, m2: Button_State,
    k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu
    in_gameplay: bool
}

rebind_input :: proc(event: sdl.Event, rebind: ^sdl.Scancode) {
    if (event.type == sdl.EventType.KEY_DOWN) {
        rebind := event.key.scancode //TODO(yokes): this doesn't work, osu_controller.k1_key = event.key.scancode works
        fmt.printfln("key set to {}", event.key.scancode)
    }
}

check_game_input :: proc(event: sdl.Event) {
    //osu_controller.k1_key = sdl.Scancode.Z
    //osu_controller.k2_key = sdl.Scancode.X

    if (event.type == sdl.EventType.KEY_DOWN) { //TODO(yokes): make this code shorter
        if (event.key.scancode == osu_controller.k1_key) {
            osu_controller.k1.is_down = true
        }
        if (event.key.scancode == osu_controller.k2_key) {
            osu_controller.k2.is_down = true
        }
    }
    if (event.type == sdl.EventType.KEY_UP) {
        if (event.key.scancode == osu_controller.k1_key) {
            osu_controller.k1.is_down = false
        }
        if (event.key.scancode == osu_controller.k2_key) {
            osu_controller.k2.is_down = false
        }
    }
    if (event.type == sdl.EventType.MOUSE_BUTTON_DOWN) {
        if (event.button.button == sdl.BUTTON_LEFT) {
            osu_controller.m1.is_down = true
        }
        if (event.button.button == sdl.BUTTON_RIGHT) {
            osu_controller.m2.is_down = true
        }
    }
    if (event.type == sdl.EventType.MOUSE_BUTTON_UP) {
        if (event.button.button == sdl.BUTTON_LEFT) {
            osu_controller.m1.is_down = false
        }
        if (event.button.button == sdl.BUTTON_RIGHT) {
            osu_controller.m2.is_down = false
        }
    }
}

//NOTE(yokes): API for in-game button input
is_held :: proc(button: Button_State) -> bool {
    return button.is_down
}

is_pressed :: proc(button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

is_released :: proc(button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

input_display :: proc(key: Button_State, rect: Window_Rect, anchor: Layout_Anchor, color: vec4, tex_index: u32 = 0) {
    if is_pressed(key) {
        push_screenspace_layout_rect(&window.renderer, rect, anchor, color, tex_index)
    } else if is_held(key) {
        push_screenspace_layout_rect(&window.renderer, rect, anchor, color, tex_index)
    } else if is_released(key) {
        push_screenspace_layout_rect(&window.renderer, rect, anchor, {0.2,0.2,0.2,1}, tex_index)
    } else {
        push_screenspace_layout_rect(&window.renderer, rect, anchor, {0.2,0.2,0.2,1}, tex_index)
        //push_layout_rect(&window.renderer, key_input_rect, .BOTTOM_RIGHT, {0.5,0.5,0.5,1})
    }
}

main :: proc() {
    _program_start_time = current_time()

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
    renderer := &window.renderer
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

    mouse: Mouse_State

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
        profiler_begin()
        defer profiler_end()

        {
            profiler_block_begin(.MESSAGE_HANDLING); defer profiler_block_end()

            // message handling, time handling
            osu_controller.k1.was_down = osu_controller.k1.is_down
            osu_controller.k2.was_down = osu_controller.k2.is_down
            osu_controller.m1.was_down = osu_controller.m1.is_down
            osu_controller.m2.was_down = osu_controller.m2.is_down

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

                if event.type == sdl.EventType.KEY_DOWN {
                    #partial switch (event.key.scancode) {
                        case sdl.Scancode.F11:
                            profiler_display_enabled = !profiler_display_enabled
                    }
                }
                
                if (osu_controller.in_gameplay) {
                    check_game_input(event)
                }
                check_game_input(event)

                if is_held(osu_controller.m1) {
                    rebind_input(event, &osu_controller.k1_key)
                }

                if is_held(osu_controller.m2) {
                    rebind_input(event, &osu_controller.k2_key)
                }
            }
            
            mouse_flags := sdl.GetGlobalMouseState(&mouse.xf, &mouse.yf)
            sdl.GetWindowPosition(window.handle, &mouse.x, &mouse.y)

            mouse.x = i32(mouse.xf) - mouse.x
            mouse.y = i32(mouse.yf) - mouse.y
        }

        {   
            profiler_block_begin(.PREPARE_FRAME); defer profiler_block_end() 
            
            time_last_frame = time_current_frame
            time_current_frame = current_time()
            dt = time_current_frame - time_last_frame
            // prepare drawing
            begin_frame(renderer)
        }   
        
        {   
            profiler_block_begin(.GAME_UPDATE); defer profiler_block_end() 
            
            // game update
            input_display(osu_controller.k1, { window.rect.w, window.rect.h / 2 - 30, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
            input_display(osu_controller.k2, { window.rect.w, window.rect.h / 2, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
            input_display(osu_controller.m1, { window.rect.w, window.rect.h / 2 + 30, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
            input_display(osu_controller.m2, { window.rect.w, window.rect.h / 2 + 60, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
        }   
        
        {   
            profiler_block_begin(.GAME_DRAW); defer profiler_block_end() 
            texture := u32((current_time() - time_first_frame)) % len(Skin_Element) + len(Reserved_Texture_Slots)

            cursor_rect: Window_Rect = { mouse.x, mouse.y, 80, 80 }
            push_screenspace_layout_rect(renderer, cursor_rect, .CENTER, {1,1,1,1}, texture)

            push_particle({
                rect = to_clipspace_rect(cursor_rect), 
                vel = {rand.float32()*2-1, rand.float32()*2-1},
                tex_index = texture
            })

            update_particles(dt)
            for i in 0..<particle_count {
                push_rect(renderer, particles[i].rect, {1,1,1,1}, particles[i].tex_index)
            }
            
            if profiler_display_enabled {
                profiler_push_quads(renderer, frame_count)
            }

            end_frame(renderer)
        }   

        {   
            profiler_block_begin(.SWAP_FRAME); defer profiler_block_end() 
            swap_frame()
        }
        
        {   
            profiler_block_begin(.BETWEEN_FRAMES); defer profiler_block_end() 

            process_main_shader_changes(&shaders_watch)

            if profiler_display_enabled {
                profiler_write_texture_column(frame_count, window.profiler_texture)
            }
            frame_count += 1
        }   
    }
}

begin_frame :: proc(renderer: ^Renderer) {
    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
    sg.apply_pipeline(window.pipeline)

    batch_begin(renderer)
}

end_frame :: proc(batch: ^Renderer) {
    batch_end(batch)
    //sg.apply_bindings(window.bindings)

    //sg.apply_uniforms(0, { ptr = &vs, size = size_of(vs) })
    sg.end_pass()
    sg.commit()
}

swap_frame :: proc() {
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
