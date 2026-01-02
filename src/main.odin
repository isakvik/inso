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

memory_arena_names := [4]string {
    "Global",
    "Mapset",
    "Frame",
    "Command buffer"
}

memory: struct {
    global_allocator: runtime.Allocator, // cleared on mapset load
    // note(isak): this is to be used for mapset runtime data, such as timing state, 
    // judgements, etc. (fill in)
    mapset_allocator: runtime.Allocator, // cleared on mapset load
    // cleared on frame end
    frame_allocator: runtime.Allocator,
    command_buffer_allocator: runtime.Allocator,

    global_arena: virtual.Arena,
    mapset_arena: virtual.Arena,
    frame_arena: virtual.Arena,
    command_buffer_arena: virtual.Arena,
}

// note(isak): this should take care of error printing
memory_init :: proc() -> runtime.Allocator_Error {
    memory.global_allocator, _ = init_growing_arena(&memory.global_arena)
    memory.mapset_allocator, _ = init_growing_arena(&memory.mapset_arena)
    memory.frame_allocator, _ = init_growing_arena(&memory.frame_arena)
    memory.command_buffer_allocator, _ = init_static_arena(&memory.command_buffer_arena)

    context.allocator = memory.global_allocator
    context.temp_allocator = memory.frame_allocator
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

    shaders: [Pipeline_ID]Shader,
    pipelines: [Pipeline_ID]sg.Pipeline,
    framebuffers: [Framebuffer_ID]GL_Framebuffer,
    
    // note(isak): we make a distinction between static and dynamic geometry; dynamic can be streamed
    // data into efficiently by using a triple buffer setup, while static is single-buffered and is fit
    // for bigger data that isn't updated as often (such as in a loading screen)

    // note(isak): single quad buffer for deferred rendering quad store, unused
    fullscreen_store: Static_Geometry_Store(Quad_Vertex),

    quad_store: Dynamic_Geometry_Store(Quad_Vertex),
    
    slider_instance_store: GL_Buffer(vec2),
    
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

    fbo_reinit(&window.framebuffers[.SLIDERS], new_w, new_h)
    window.renderer.default_transform = transform_from_bounds({0, 0, 1, 1}, window.aspect_ratio)
}

window_get_screenspace_transform :: proc() -> Transform {
    return transform_from_bounds({0, 0, window.rect.w, window.rect.h}, 1)
}

window_get_fullscreen_transform :: proc() -> Transform {
    return transform_from_bounds({0, 0, 1, 1}, 1)
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

rebind_input :: proc(event: sdl.Event, rebind: ^sdl.Scancode) {
    if (event.type == sdl.EventType.KEY_DOWN) {
        rebind^ = event.key.scancode //TODO(yokes): this doesn't work, osu_controller.k1_key = event.key.scancode works
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

input_display :: proc(key: Button_State, rect: Rect, anchor: Layout_Anchor, color: vec4, tex_index: u32 = 0) {
    if is_pressed(key) {
        push_layout_rect(&window.renderer.quad_geometry, rect, anchor, color, tex_index)
    } else if is_held(key) {
        push_layout_rect(&window.renderer.quad_geometry, rect, anchor, color, tex_index)
    } else if is_released(key) {
        push_layout_rect(&window.renderer.quad_geometry, rect, anchor, {0.2,0.2,0.2,1}, tex_index)
    } else {
        push_layout_rect(&window.renderer.quad_geometry, rect, anchor, {0.2,0.2,0.2,1}, tex_index)
        //push_layout_rect(&window.renderer, key_input_rect, .BOTTOM_RIGHT, {0.5,0.5,0.5,1})
    }
}

g_engine: miniaudio.engine
g_sound: miniaudio.sound

data_callback :: proc "c" (pUserData: rawptr, pStream: ^sdl.AudioStream, additional_amount, total_amount: i32) {
    numSamples := additional_amount / size_of(f32)
    numFrames := u64(numSamples / 2)
    numFramesRead: u64
    g_sound := transmute(^miniaudio.sound)pUserData
    samples: [1024]f32
    
    miniaudio.data_source_read_pcm_frames(g_sound.pDataSource, raw_data(&samples), numFrames, &numFramesRead)
    sdl.PutAudioStreamData(pStream, raw_data(&samples), i32(numFramesRead * size_of(f32) * 2))
}

main :: proc() {
    _program_start_time = current_time()

    if memory_init() != .None {
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

    deviceID: sdl.AudioDeviceID
    //desiredSpec: sdl.AudioSpec
    obtainedSpec: sdl.AudioSpec
    sample_frames: i32

    if (!sdl.Init({.AUDIO, .VIDEO})) {
    fmt.printfln("SDL init error: {}", sdl.GetError())
    return
    }

    sound_enabled := false
    if sound_enabled {
        desiredSpec := sdl.AudioSpec{
            freq = 48000,
            format = .F32,
            channels = 2
        }
    
        deviceID = sdl.OpenAudioDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &desiredSpec)
        if deviceID == 0 {
            fmt.printfln("SDL init error: {}", sdl.GetError())
            return
        }
    
        stream := sdl.CreateAudioStream(&desiredSpec, &desiredSpec); // Input and output specs can match initially
    
        result: miniaudio.result
    
        sdl.GetAudioDeviceFormat(deviceID, &obtainedSpec, &sample_frames)
    
        engineConfig := miniaudio.engine_config_init()
        engineConfig.channels = u32(obtainedSpec.channels)
        engineConfig.sampleRate = u32(obtainedSpec.freq)
        engineConfig.noDevice = true
    
        result = miniaudio.engine_init(&engineConfig, &g_engine)
        if (result != .SUCCESS) {
            fmt.printf("Failed to initialize audio engine.")
            return
        }
    
        result = miniaudio.sound_init_from_file(&g_engine, "songs/test/test.mp3", {.STREAM}, nil, nil, &g_sound)
        if (result != .SUCCESS) {
            fmt.printf("Failed to initialize sound.")
            return
        }
    
        // Register the callback, passing a pointer to the sound object as user data
        sdl.SetAudioStreamGetCallback(stream, data_callback, &g_sound);
    
        // Bind the stream to a logical audio device
        sdl.BindAudioStreams(deviceID, &stream, 1);
        
        sdl.ResumeAudioDevice(deviceID)
        miniaudio.sound_start(&g_sound)
    }

    window_init({w = 1024, h = 512})
    defer window_cleanup()

    renderer_init()
    renderer := &window.renderer
    defer renderer_cleanup()

    window_resize(i32(window.rect.w), i32(window.rect.h))
    
    text_init()
    
    load_skin_textures("skins/gn/")
    prepare_textures_for_rendering()

    shaders_watch := win32_init_directory_watch("shaders/")

    {
        ok: bool
        mapset_path := "songs/test/"
        game.active_mapset, ok = mapset_open_for_editing(mapset_path)
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
        - slider path gen
    */

    osu_on_init()

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
                        case sdl.Scancode.F11:
                            debug_info.display_profiler = !debug_info.display_profiler
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
            
            osu_on_update(dt)
            
            begin_draw_with_transform(window_get_screenspace_transform())
            
            // game update
            input_display(osu_controller.k1, { window.rect.w, window.rect.h / 2 - 30, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
            input_display(osu_controller.k2, { window.rect.w, window.rect.h / 2,      30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
            input_display(osu_controller.m1, { window.rect.w, window.rect.h / 2 + 30, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
            input_display(osu_controller.m2, { window.rect.w, window.rect.h / 2 + 60, 30, 30 }, .BOTTOM_RIGHT, {0.7,0.7,0.7,1})
            
            cursor_rect: Rect = { f32(mouse.pos.x), f32(mouse.pos.y), 80, 80 }
            push_layout_rect(&renderer.quad_geometry, cursor_rect, .CENTER, color_white, skin_texture_slot(.CURSOR))
            
            if selection_active {
                push_rect_outline_fill(&window.renderer.quad_geometry, rect_from_points(mouse.pos, selection_start_mouse_pos), 
                                       color_sky_blue, with_alpha(color_sky_blue, 0.3), 1)
            }

            begin_draw_with_transform(transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio))
            push_rect_outline(&renderer.quad_geometry, playfield_rect, with_alpha(color_white, 0.1), 2)

            // todo(isak): create some kinda iterator for this; keep track of earliest active object and 
            // stop once first nonstarted obj is done
            for &hit_object in sa.slice(&osu_map_hit_objects) {
                render_hit_object(renderer, &hit_object)
            }
        }
        
        {
            /*
                todo(isak): state of the renderer:
                usage:
                - batch overrun has not been tested but won't work; it should run end_frame().. probably
                - the rect pushing in the draw section is artificial; only text_end_frame() and 
                    end_frame() need to happen here
                - transforms should be a dynamic stack that we just write as we process the frame; can save a bunch
                    of draw calls

                optimization:
                - opengl has pretty bad overhead per frame even if it's not doing much work, so i think
                    directx is a better choice cuz we don't do anything fancy
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

            render_slider(renderer, &test_slider)
            command_push_bind_framebuffer({})
            
            command_push_set_mode({mode = .TEXT})
            begin_draw_with_transform(window_get_screenspace_transform())

            push_text(renderer, "Hello, world!", {100, 100})
            push_text(renderer, "饕餮尤魔 :3", {200, 200}, size=24)
            
            game_timer_str := fmt.tprintf("%.3f", game.play_timer_ms)
            push_text(renderer, game_timer_str, {20, 20}, size = 22)

            if debug_info.display_profiler {
                profiler_push_blocks_as_text(renderer, frame_count)
                profiler_push_memory_diag_text(renderer)
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

            process_watch_changes(&shaders_watch)

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
    sg.apply_pipeline(window.pipelines[.QUAD])

    renderer.transform_queue.len = 0
    begin_draw_with_transform(renderer.default_transform)
}

end_frame :: proc(renderer: ^Renderer) {
    batch_end(renderer)

    trace := renderer.trace_frame
    
    for renderer.command_queue.len > 0 {
        cmd_type := queue.pop_front(&renderer.command_queue)

        switch Command_Type(cmd_type) {
            case .SET_MODE: {
                cmd := (^Command_Set_Mode)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Set_Mode))

                switch(cmd.mode) {
                    case .QUAD_UV: {
                        fbo_bind_default()

                        tbo_bind(&window.quad_store.vertex_buffer, 0)
                        tbo_bind(&window.quad_store.index_buffer, 1)

                        sg.apply_pipeline(window.pipelines[.QUAD])
                        
                        if (trace) { fmt.println("quads") }
                    }
                    case .TEXT: {
                        sg.apply_pipeline(window.pipelines[.TEXT])
                        
                        tbo_bind(&window.text_store, 0)
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

                // todo(isak) implement
                
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
                                
                gl.DrawArraysInstancedBaseInstance(
                    gl.TRIANGLE_FAN, 
                    0, 
                    renderer.circle_geometry.count,
                    cmd.instance_count, cmd.base_instance)

                if (trace) { fmt.println("drawslider", cmd.instance_count, cmd.base_instance) }
            }
            case .BIND_PIPELINE: {
                cmd := (^Command_Bind_Pipeline)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Bind_Pipeline))

                sg.apply_pipeline(window.pipelines[cmd.pipeline])
                
                if (trace) { fmt.println("pipeline", cmd.pipeline) }
            }
            case .BIND_FRAMEBUFFER: {
                cmd := (^Command_Bind_Framebuffer)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Bind_Framebuffer))

                fbo_bind(window.framebuffers[cmd.read].id, window.framebuffers[cmd.write].id)
                
                if (trace) { fmt.println("framebuffer", cmd.read, cmd.write) }
            }
            case .BIND_SSBO: {
                cmd := (^Command_Bind_SSBO)(queue.front_ptr(&renderer.command_queue))
                queue.consume_front(&renderer.command_queue, size_of(Command_Bind_SSBO))
                
                gl.BindBufferRange(
                    gl.SHADER_STORAGE_BUFFER,
                    cmd.slot,
                    cmd.id,
                    cmd.offset,
                    cmd.size)
                
                if (trace) { fmt.println("ssbo", cmd.id, cmd.slot, cmd.size, cmd.offset) }
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

process_watch_changes :: proc(watch: ^Win32_Directory_Watch) {
    updated_systems := mapset_check_system_file_watch(watch)

    if updated_systems[.OSU_FILE] {
        // todo(isak): reload osu file specifically on update so that we can tell slider path gen works
        //mapset_open_for_editing()
        //write_instances_from_curve(&buf, test_curves[0], .BEZIER)
    }

    if updated_systems[.SHADERS] {
        for &shader in window.shaders {
            reinit_shader(&shader)
        }
        fmt.println("reloaded shaders")

        reinit_pipeline(&window.pipelines[.QUAD], quad_pipeline())
        reinit_pipeline(&window.pipelines[.SLIDER], slider_pipeline())
        reinit_pipeline(&window.pipelines[.TEXT], text_pipeline())
    }
}
