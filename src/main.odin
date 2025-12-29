package notosu

import "base:runtime"
import "core:container/queue"
import sa "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"
import miniaudio "vendor:miniaudio"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"


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

// note(isak): this should take care of error printing
init_memory :: proc() -> runtime.Allocator_Error {
    memory.mapset_allocator, _ = init_growing_arena(&memory.mapset_arena)
    memory.frame_allocator, _ = init_growing_arena(&memory.frame_arena)
    memory.command_buffer_allocator, _ = init_growing_arena(&memory.command_buffer_arena)
    return .None
}

window: struct {
    rect: Rect,
    aspect_ratio: f32, // note(isak): height over width
    renderer: Renderer,

    handle: ^sdl.Window,
    gl_context: sdl.GLContext,

    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,

    shaders: [Shader_ID]Shader,
    
    fullscreen_store: Static_Geometry_Store(Quad_Vertex), // note(isak): deferred rendering quad store

    quad_pipeline: sg.Pipeline,
    quad_store: Dynamic_Geometry_Store(Quad_Vertex),
    
    slider_pipeline: sg.Pipeline,
    slider_framebuffer: GL_Framebuffer,
    slider_instance_store: GL_Triple_Buffer(vec2),
    
    text_pipeline: sg.Pipeline,
    text_store: GL_Triple_Buffer(Glyph_Quad),
    
    current_transform: Transform,
    transform_buffer: GL_Uniform_Buffer(Transform),
    circle_geo_buffer: GL_Buffer(Slider_Vertex),
    texture_buffer: GL_Buffer(u64),

    white_texture: Texture,
    profiler_texture: Texture,
    font_atlas_texture: Texture,

    skin_textures: [Skin_Element]Texture,
}

debug_info: struct {
    display_profiler: bool,
    display_fontatlas: bool
}

lua_ctx: struct {
    state: ^lua.State
}

window_init :: proc(rect: Rect) {
    window.rect = rect
    window.handle = sdl.CreateWindow("notosu!", i32(rect.w), i32(rect.h), sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    window.aspect_ratio = f32(rect.h) / f32(rect.w)

    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 4)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 6)
    sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengl")

    sdl.GL_SetSwapInterval(0)
    sdl.SetWindowSurfaceVSync(window.handle, 0)

    window.gl_context = sdl.GL_CreateContext(window.handle)
    gl.load_up_to(4, 6, sdl.gl_set_proc_address)
    gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE)

    win_x, win_y: i32
    sdl.GetWindowPosition(window.handle, &win_x, &win_y)
    window.rect.x = f32(win_x)
    window.rect.y = f32(win_y)

    _ignored := sdl.HideCursor()
}

window_resize :: proc(new_w, new_h: i32) {
    window.rect.w = f32(new_w)
    window.rect.h = f32(new_h)
    window.swapchain.width = new_w
    window.swapchain.height = new_h
    window.aspect_ratio = window.rect.h / window.rect.w

    if window.slider_framebuffer.id > 0 {
        fbo_cleanup(&window.slider_framebuffer)
    }
    window.slider_framebuffer = fbo_init(1, 1, new_w, new_h, gl.RGBA8)
}

window_get_screenspace_transform :: proc() -> Transform {
    return transform_from_bounds({0, 0, window.rect.w, window.rect.h}, 1)
}

window_cleanup :: proc() {
    sdl.GL_DestroyContext(window.gl_context)
    sdl.DestroyWindow(window.handle)
}


mouse: struct {
    pos: vec2
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

    /*
    lua_ctx.state = lua.L_newstate()
    defer lua.close(lua_ctx.state)
    
    lua.L_openlibs(lua_ctx.state)
    
    script: cstring = "print('Hello from Lua!')"
    lua.L_dostring(lua_ctx.state, script)
    */


    if (!sdl.Init(sdl.INIT_VIDEO)) {
        fmt.printfln("SDL init error: {}", sdl.GetError())
        return
    }

    window_init({w = 1280, h = 720})
    defer window_cleanup()

    renderer_init()
    renderer := &window.renderer
    defer renderer_cleanup()

    window_resize(i32(window.rect.w), i32(window.rect.h))
    
    text_init()
    
    load_skin_textures("skins/gn/")
    prepare_textures_for_rendering()

    shaders_watch := win32_init_directory_watch("shaders/")

    mapset: ^Mapset
    {
        ok: bool
        mapset_path := "songs/test/"
        mapset, ok = mapset_open_for_editing(mapset_path)
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
        - imgui?
    - slider rendering
        + dynamic texture surface
        + slider geometry
        - slider path gen
        - slider quad clipping (scissor test?)
    */

    make_test_slider(&test_slider, 0)
    make_test_slider(&test_slider2, 1)

    preempt: f64 = convert_approach_rate_to_preempt(mapset.osu_map.diff_approach_rate)
    
    final_hobj_time_ms: f64
    for hobj in mapset.osu_map.hit_objects {
        make_test_obj(hobj.end_time_ms, preempt, hobj.pos)

        final_hobj_time_ms = max(final_hobj_time_ms, hobj.end_time_ms)
    }

    game.active_map.length_ms = final_hobj_time_ms + 500
    game.active_map.audio_lead_in = preempt + 1000
    game.play_timer_ms = -game.active_map.audio_lead_in

    selection_active: bool
    selection_start_mouse_pos: vec2
    
    
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
                #partial switch event.type {
                case sdl.EventType.QUIT:
                    active = false

                case sdl.EventType.WINDOW_FOCUS_LOST:
                    selection_active = false

                case sdl.EventType.WINDOW_RESIZED:
                    cleanup_textures_for_rendering()
                    window_resize(max(event.window.data1, 1), max(event.window.data2, 1))
                    prepare_textures_for_rendering()
                        
                case sdl.EventType.MOUSE_BUTTON_DOWN:
                    selection_start_mouse_pos = {event.button.x, event.button.y}
                    selection_active = true

                case sdl.EventType.MOUSE_BUTTON_UP:
                    selection_active = false

                case sdl.EventType.KEY_DOWN:
                    #partial switch (event.key.scancode) {
                        case sdl.Scancode.F1:
                            renderer.trace_frame = !renderer.trace_frame
                        case sdl.Scancode.F10:
                            debug_info.display_fontatlas = !debug_info.display_fontatlas
                        case sdl.Scancode.F9:
                            debug_info.display_profiler = !debug_info.display_profiler
                    }
                }
                
                if (osu_controller.in_gameplay) {
                    check_game_input(event)
                }
            }
            
            xi, yi: i32
            mouse_flags := sdl.GetGlobalMouseState(&mouse.pos.x, &mouse.pos.y)
            sdl.GetWindowPosition(window.handle, &xi, &yi)

            mouse.pos.x = mouse.pos.x - f32(xi)
            mouse.pos.y = mouse.pos.y - f32(yi)
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
            
            // bounds testers
            push_rect(&renderer.quad_geometry, {0,0,0.5,0.5}, with_alpha(color_red, 0.1))
            push_rect(&renderer.quad_geometry, {0.5,0.5,0.5,0.5}, with_alpha(color_blue, 0.1))
            

            game.play_timer_ms += dt * 1000
            if game.play_timer_ms > game.active_map.length_ms {
                game.play_timer_ms = -game.active_map.audio_lead_in
            }

            playfield_rect := Rect{ 0, 0, osu_playfield_size_osupx, osu_playfield_size_osupx }

            begin_draw_with_transform(window_get_screenspace_transform())
            
            cursor_rect: Rect = { f32(mouse.pos.x), f32(mouse.pos.y), 80, 80 }
            push_layout_rect(&renderer.quad_geometry, cursor_rect, .CENTER, color_white, skin_texture_slot(.CURSOR))
            
            if selection_active {
                push_rect_outline_fill(&window.renderer.quad_geometry, rect_from_points(mouse.pos, selection_start_mouse_pos), 
                    color_sky_blue, with_alpha(color_sky_blue, 0.3), 2)
            }

            begin_draw_with_transform(transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio))

            for hit_object in sa.slice(&osu_map_hit_objects) {
                if hit_object.start_time_ms < game.play_timer_ms && game.play_timer_ms < hit_object.end_time_ms {
                    ho_pos := rect_translate_by_anchor(Rect{hit_object.pos.x, hit_object.pos.y, 40, 40}, .CENTER)
                    push_rect(&renderer.quad_geometry, ho_pos, vec4(0.5), skin_texture_slot(.HITCIRCLE))
                }
            }

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
                todo(isak): state of the renderer:
                usage:
                - batch overrun has not been tested but won't work; it should run end_frame().. probably
                - the different clipspace/screenspace/layout quad pushing isn't really necessary with
                    the transformation matrix stuff, so the API can be simplified
                - the rect pushing in the draw section is artificial; only text_end_frame() and 
                    end_frame() need to happen here
                - transforms should be a dynamic stack because single state is annoying

                optimization:
                - opengl has pretty bad overhead per frame even if it's not doing much work, so i think
                    directx is a better choice
                - the vertex generation pipeline for main isn't particularly efficient, should be
                    rewritten to be more like text where quads are just written directly to the gpu
            */
            profiler_block_begin(.GAME_DRAW); defer profiler_block_end()

            if debug_info.display_fontatlas {
                begin_draw_with_transform(window_get_screenspace_transform())
                push_rect(&renderer.quad_geometry,
                    {0, 0, f32(text_engine.ctx.width), f32(text_engine.ctx.height)},
                    color_white,
                    reserved_texture(.FONT_ATLAS))
            }

            if debug_info.display_profiler {
                begin_draw_with_transform(window_get_screenspace_transform())
                profiler_push_quad(&renderer.quad_geometry, frame_count)
            }

            
            command_push_set_mode({mode = .BEGIN_SLIDERS})
            
            // playfield

            pf_size: f32 = 1

            begin_draw_with_transform(renderer.default_transform)

            push_slider(renderer, &test_slider)
            //push_slider(renderer, &test_slider2)
            
            command_push_set_mode({mode = .END_SLIDERS})
            
            command_push_set_mode({mode = .TEXT})
            begin_draw_with_transform(window_get_screenspace_transform())

            push_text(renderer, "Hello, world!", {100, 100})
            push_text(renderer, "yuuma toutetsu :3", {200, 200}, size=16)
            
            buf: [32]byte
            game_timer_str := fmt.bprintf(buf[:], "%.3f", game.play_timer_ms)
            push_text(renderer, game_timer_str, {20, 20}, size = 22)

            if debug_info.display_profiler {
                profiler_push_blocks_as_text(renderer, frame_count)
            }

            text_end_frame(renderer)
            end_frame(renderer)
        }

        {
            profiler_block_begin(.SWAP_FRAME); defer profiler_block_end() 
            swap_frame()
        }
        
        {
            profiler_block_begin(.BETWEEN_FRAMES); defer profiler_block_end() 

            process_main_shader_changes(&shaders_watch)

            if debug_info.display_profiler {
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
    
    batch_begin(renderer)
    command_push_set_mode({mode = .QUAD_UV})

    renderer.transform_queue.len = 0
    begin_draw_with_transform(renderer.default_transform)
}

end_frame :: proc(renderer: ^Renderer) {
    batch_end(renderer)

    trace := renderer.trace_frame
    
    for renderer.command_queue.len > 0 {
        cmd_type := queue.pop_front(&renderer.command_queue)

        switch(Command_Type(cmd_type)) {
            case .SET_MODE: {
                cmd := (^Command_Set_Mode)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Set_Mode))

                switch(cmd.mode) {
                    case .QUAD_UV: {
                        fbo_bind_default()

                        tbo_bind(&window.quad_store.vertex_buffer, 0)
                        tbo_bind(&window.quad_store.index_buffer, 1)
                        
                        sg.apply_pipeline(window.quad_pipeline)
                        
                        if (trace) { fmt.println("quads") }
                    }
                    case .TEXT: {
                        sg.apply_pipeline(window.text_pipeline)
                        
                        tbo_bind(&window.text_store, 0)
                    }
                    case .BEGIN_SLIDERS: {
                        sg.apply_pipeline(window.slider_pipeline)

                        sbo_bind(&window.fullscreen_store.vertex_buffer, 0)
                        sbo_bind(&window.fullscreen_store.index_buffer, 1)
                        
                        if (trace) { fmt.println("slider") }
                    }
                    case .END_SLIDERS: {
                        fbo_bind_default()
                        
                        if (trace) { fmt.println("slider") }
                    }
                }
            }
            case .PUSH_TRANSFORM: {
                cmd := (^Command_Push_Transform)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Push_Transform))

                commit_transform(cmd.transform)
                
                if (trace) { 
                    fmt.println("push xform", cmd.transform) 
                }
            }
            case .POP_TRANSFORM: {
                transform := Transform{}
                commit_transform(transform)
                
                if (trace) { 
                    fmt.println("push xform", transform) 
                }
            }
            case .CLEAR: {
                gl.ClearColor(0,0,0,0)
                gl.ClearDepth(1.0)
                gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

                if (trace) { fmt.println("clear") }
            }
            case .DRAW: {
                cmd := (^Command_Draw)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Draw))
                
                sg.draw(cmd.index_offset, cmd.index_count, cmd.instance_count)

                if (trace) { fmt.println("draw", cmd.index_count, cmd.index_offset, cmd.instance_count) }
            }
            case .DRAW_SLIDER: {
                cmd := (^Command_Draw_Slider)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Draw_Slider))
                
                sg.apply_pipeline(window.slider_pipeline)
                
                fbo_bind_write(window.slider_framebuffer)

                gl.ClearColor(0,0,0,0)
                gl.ClearDepth(1.0)
                gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
                
                gl.DrawArraysInstancedBaseInstance(
                    gl.TRIANGLE_FAN, 
                    0, 
                    renderer.circle_geometry.count,
                    cmd.instance_count, cmd.base_instance)
                    
                fbo_bind_read(window.slider_framebuffer)

                sg.apply_pipeline(window.quad_pipeline)
                sg.draw(0, 6, 1)

                if (trace) { fmt.println("drawslider", cmd.instance_count, cmd.base_instance) }
            }
        }
    }

    queue.clear(&renderer.command_queue)
    renderer.trace_frame = false

    sg.end_pass()
    sg.commit()
}

// note(isak): stolen wisdom; this is its own profiler section
swap_frame :: proc() {
    sdl.GL_SwapWindow(window.handle)
}

process_main_shader_changes :: proc(watch: ^Win32_Directory_Watch) {
    updated_systems := mapset_check_system_file_watch(watch)

    if updated_systems[.SHADERS] {
        for &shader in window.shaders {
            reinit_shader(&shader)
        }
        fmt.println("reloaded shaders")

        reinit_pipeline(&window.quad_pipeline, quad_pipeline())
        reinit_pipeline(&window.slider_pipeline, slider_pipeline())
        reinit_pipeline(&window.text_pipeline, text_pipeline())
    }
}
