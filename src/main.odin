package notosu

import "core:container/queue"
import "core:mem"
import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import miniaudio "vendor:miniaudio"

vec2 :: linalg.Vector2f32
vec3 :: linalg.Vector3f32
vec4 :: linalg.Vector4f32

mat3 :: linalg.Matrix3x3f32
mat4 :: linalg.Matrix4x4f32

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

memory: struct {
    // note(isak): this is to be used for mapset runtime data, such as timing state, 
    // judgements, etc. (fill in)
    // cleared on mapset load
    mapset_allocator: runtime.Allocator,
    frame_allocator: runtime.Allocator,
    command_buffer_allocator: runtime.Allocator,

    mapset_arena: virtual.Arena,
    frame_arena: virtual.Arena,
    command_buffer_arena: virtual.Arena,
}

init_growing_arena :: proc(arena: ^virtual.Arena, alloc: ^runtime.Allocator, size_MB: uint = 1) -> runtime.Allocator_Error {
    alloc_err := virtual.arena_init_growing(arena, size_MB)
    if alloc_err != .None {
        fmt.println("mapset arena init error:", alloc_err)
        return alloc_err
    }
    alloc^ = virtual.arena_allocator(arena)
    return .None
}

// note(isak): this should take care of error printing
init_memory :: proc() -> runtime.Allocator_Error {
    init_growing_arena(&memory.mapset_arena, &memory.mapset_allocator)
    init_growing_arena(&memory.frame_arena, &memory.frame_allocator)
    init_growing_arena(&memory.command_buffer_arena, &memory.command_buffer_allocator)
    return .None
}

Dynamic_Geometry_Store :: struct(T: typeid) {
    vertex_buffer: GL_Triple_Buffer(T),
    index_buffer: GL_Triple_Buffer(u32),
}

Static_Geometry_Store :: struct(T: typeid) {
    vertex_buffer: GL_Buffer(T),
    index_buffer: GL_Buffer(u32),
}

window: struct {
    rect: Window_Rect,
    aspect_ratio: f32, // note(isak): height over width
    renderer: Renderer,

    handle: ^sdl.Window,
    gl_context: sdl.GLContext,

    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,

    fullscreen_store: Static_Geometry_Store(Quad_Vertex), // note(isak): deferred rendering quad store

    quad_shader: sg.Shader,
    quad_pipeline: sg.Pipeline,
    quad_store: Dynamic_Geometry_Store(Quad_Vertex),
    
    slider_shader: sg.Shader,
    slider_pipeline: sg.Pipeline,
    slider_framebuffer: GL_Framebuffer,
    slider_instance_store: GL_Triple_Buffer(vec2),
    
    transform_buffer: GL_Buffer(Transform),
    circle_buffer: GL_Buffer(Slider_Vertex),
    texture_buffer: GL_Buffer(u64),

    white_texture: Texture,
    profiler_texture: Texture,

    skin_textures: [Skin_Element]Texture,
}

Transform :: struct {
    bounds_rect: vec4,
    aspect_ratio: f32,
    cs_in_osupx: f32,
}

default_transform :: Transform{
    bounds_rect = {-1, -1, 2, 2},
    aspect_ratio = 1
}

lua_ctx: struct {
    state: ^lua.State
}

window_init :: proc(rect: Window_Rect) {
    window.rect = rect
    window.handle = sdl.CreateWindow("notosu!", rect.w, rect.h, sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    window.aspect_ratio = f32(rect.h) / f32(rect.w)

    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 4)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 6)
    sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengl")

    sdl.GL_SetSwapInterval(0)
    sdl.SetWindowSurfaceVSync(window.handle, 0)

    window.gl_context = sdl.GL_CreateContext(window.handle)
    gl.load_up_to(4, 6, sdl.gl_set_proc_address)

    sdl.GetWindowPosition(window.handle, &window.rect.x, &window.rect.y)

    _ignored := sdl.HideCursor()
}

window_resize :: proc(new_w, new_h: i32) {
    window.rect.w = new_w
    window.rect.h = new_h
    window.swapchain.width = new_w
    window.swapchain.height = new_h
    window.aspect_ratio = f32(new_h) / f32(new_w)

    if window.slider_framebuffer.id > 0 {
        fbo_cleanup(&window.slider_framebuffer)
    }
    window.slider_framebuffer = fbo_init(1, 1, new_w, new_h, gl.RGBA8)
}

window_cleanup :: proc() {
    sdl.GL_DestroyContext(window.gl_context)
    sdl.DestroyWindow(window.handle)
}


Mouse_State :: struct {
    x, y: i32
}

Button_State :: struct {
    is_down, was_down: bool
}

osu_controller: struct {
    k1, k2, m1, m2: Button_State,
    k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu
    in_gameplay: bool
}

check_game_input :: proc(event: sdl.Event) {
    osu_controller.k1_key = sdl.Scancode.Z
    osu_controller.k2_key = sdl.Scancode.X

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

main :: proc() {
    _program_start_time = current_time()

    if init_memory() != .None {
        panic("memory init error")
    }

    current_dir, dir_error := os.get_working_directory(context.allocator)
    if strings.compare("build", filepath.base(current_dir)) == 0 {
        os.set_working_directory(filepath.dir(current_dir))
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

    window_init({w = 1280, h = 720})
    defer window_cleanup()

    renderer_init()
    renderer := &window.renderer
    defer renderer_cleanup()

    window_resize(window.rect.w, window.rect.h)
    
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

    make_test_slider(&test_slider, 0)
    make_test_slider(&test_slider2, 1)
    
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
                    cleanup_textures_for_rendering()
                    window_resize(event.window.data1, event.window.data2)
                    prepare_textures_for_rendering()
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
            }
            
            xf, yf: f32
            mouse_flags := sdl.GetGlobalMouseState(&xf, &yf)
            sdl.GetWindowPosition(window.handle, &mouse.x, &mouse.y)

            mouse.x = i32(xf) - mouse.x
            mouse.y = i32(yf) - mouse.y
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
            if is_pressed(osu_controller.k1) {
                fmt.printfln("is pressed")
            } else if is_held(osu_controller.k1) {
                fmt.printfln("is held")
            } else if is_released(osu_controller.k1) {
                fmt.printfln("is released")
            }
        }
        
        {
            /*
                we want to put bounds calculations on the gpu, so shader and draw command pipeline
                has to support this. this means we need a queue for uniform upload and draw commands
                
                so the frame procedure becomes:
                begin frame:
                - lock, etc.
                - write default bounds

                write quads
                write playfield quads
                write playfield sliders

                write procedure:
                - write into quad buf
                - write bounds change
                    write batch command for quads up to this point
                - write more quads
                - write sliders

                render procedure:
                - tbo_wait
                - for each command
                    if bounds update
                        upload (or select from set of bounds, but is there a good reason for that?)
                    if draw
                        issue draw call
                - reset command buf

                on batch full:
                - render
                    (settings are kept by driver state machine)
                - tbo_lock

                end frame:
                - render
            */
            profiler_block_begin(.GAME_DRAW); defer profiler_block_end()

            begin_draw_with_transform(default_transform)

            // bounds testers
            push_rect(&renderer.quad_geometry, {-1,-1,1,1}, color_red)
            push_rect(&renderer.quad_geometry, {0,0,1,1}, color_red)
            
            cursor_rect: Window_Rect = { mouse.x, mouse.y, 80, 80 }
            push_screenspace_layout_rect(&renderer.quad_geometry, cursor_rect, .CENTER, color_red, skin_texture_slot(.CURSOR))
            
            // playfield
            begin_draw_with_transform({
                bounds_rect = {-1/512, -1/512, 2/512, 2/512},
                aspect_ratio = 1,
                cs_in_osupx = 48
            })

            push_slider(renderer, &test_slider)
            push_slider(renderer, &test_slider2)

            if profiler_display_enabled {
                begin_draw_with_transform(default_transform)
                profiler_push_quads(&renderer.quad_geometry, frame_count)
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

                if frame_count % 100 == 0 {
                    fmt.println("fps:", profiler_get_fps())
                }
            }
            frame_count += 1

            virtual.arena_free_all(&memory.frame_arena)
        }
    }
}

begin_frame :: proc(renderer: ^Renderer) {
    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
    
    //gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE)
    
    batch_begin(renderer)
    reset_transform()
}

end_frame :: proc(renderer: ^Renderer) {
    batch_end(renderer)
    
    //
    for renderer.command_queue.len > 0 {
        cmd_type := queue.pop_front(&renderer.command_queue)

        switch(Command_Type(cmd_type)) {
            case .SET_BOUNDS: {
                cmd := (^Command_Set_Bounds)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Set_Bounds))

                fmt.println("set bounds", cmd.transform.bounds_rect.x, cmd.transform.bounds_rect.y, cmd.transform.bounds_rect.z, cmd.transform.bounds_rect.w)
            }
            case .DRAW: {
                cmd := (^Command_Draw)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Draw))
                
                fmt.println("draw", cmd.index_count, cmd.index_offset)
            }
        }
    }

    queue.clear(&renderer.command_queue)

    sg.end_pass()
    sg.commit()
}

swap_frame :: proc() {
    sdl.GL_SwapWindow(window.handle)
}

process_main_shader_changes :: proc(watch: ^Win32_Directory_Watch) {
    updated_systems := mapset_check_system_file_watch(watch)

    if updated_systems[.SHADERS] {
        reinit_shader(&window.quad_shader, main_vs_path, main_fs_path, main_uniform_desc())
        reinit_pipeline(&window.quad_pipeline, main_pipeline(window.quad_shader))
        
        reinit_shader(&window.slider_shader, slider_vs_path, slider_fs_path, slider_uniform_desc())
        reinit_pipeline(&window.slider_pipeline, slider_pipeline(window.slider_shader))
    }
}
