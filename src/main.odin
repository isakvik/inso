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
import mu "vendor:microui"
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
- expose rendering and resource api

-- todos

general:
ui core (map selector, skin select?)
"full" .osu support (no sb, editor features, osu integration)

play mode:
audio play (miniaudio)
    desync proofing (always wait for sound to be able to be played, like osu (so device errors will just freeze the game))
    multiple channels, 
input handling

figure out if we need some graphical core of a playfield (i'm thinking we have some default implementation; optionally hide it and let people render whatever based on mapset data)

editor mode:
(viewer mode only? edit functionality is probably low priority, osu can be used for the map)
scrubbing support (jump to arbitrary time, display content)

eventual YEAST on-scene features:
local networking
    multiple client sync
    potentially display other client cursors? w

*/

memory_arena_names := [?]string {
    "Global",
    "Mapset",
    "Frame",
    "Command buffer[BACKGROUND]",
    "Command buffer[FOREGROUND]",
    "Command buffer[HIT_OBJECT]",
    "Command buffer[OVERLAY]",
    "Command buffer[UI]",
    "Command buffer[DEBUG]",
}

memory: struct {
    global_allocator: runtime.Allocator,
    global_arena: virtual.Arena,
    // note(isak): this is to be used for mapset runtime data, such as timing state, judgements, etc. (fill in)
    // cleared on mapset reload/unload
    mapset_allocator: runtime.Allocator,
    mapset_arena: virtual.Arena,
    
    // cleared on frame end
    frame_allocator: runtime.Allocator,
    frame_arena: virtual.Arena,

    command_buffer_allocators: [Layer]runtime.Allocator,
    command_buffer_arenas: [Layer]virtual.Arena,
}

// note(isak): this should take care of error printing
memory_init :: proc() -> runtime.Allocator_Error {
    _ = init_growing_arena(&memory.global_arena, &memory.global_allocator)
    _ = init_growing_arena(&memory.mapset_arena, &memory.mapset_allocator)
    _ = init_growing_arena(&memory.frame_arena, &memory.frame_allocator)

    for layer in Layer {
        _ = init_growing_arena(&memory.command_buffer_arenas[layer], &memory.command_buffer_allocators[layer])
    }

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
    
    ui_ctx: mu.Context,
    
    // note(isak): graphical resources used by the drawing context go here 

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
    fullscreen_store: GL_Buffer(Quad),

    quad_store: GL_Triple_Buffer(Quad),
    
    slider_instance_store: GL_Buffer(vec2),
    
    text_store: GL_Triple_Buffer(Glyph_Quad),
    
    transform_buffer: GL_Uniform_Buffer(Transform),
    circle_geo_buffer: GL_Buffer(Slider_Vertex),
    texture_buffer: GL_Buffer(u64),

    white_texture: Texture,
    profiler_texture: Texture,
    font_atlas_texture: Texture,
    ui_atlas_texture: Texture,

    skin_textures: [Skin_Element]Texture,
}

debug_info: struct {
    display_frame_profiler: bool,
    display_memory_profiler: bool,
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

clipspace_transform := transform_from_bounds({0, 0, 1, 1}, 1)
window_get_clipspace_transform :: proc() -> Transform {
    return clipspace_transform
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

audio_ctx: struct {
    g_engine: miniaudio.engine,
    g_sound: miniaudio.sound,
}

miniaudio_data_callback :: proc "c" (pUserData: rawptr, pStream: ^sdl.AudioStream, additional_amount, total_amount: i32) {
    numSamples := additional_amount / size_of(f32)
    numFrames := u64(numSamples / 2)
    numFramesRead: u64
    sound := transmute(^miniaudio.sound)pUserData
    samples: [1024]f32
    
    miniaudio.data_source_read_pcm_frames(sound.pDataSource, raw_data(&samples), numFrames, &numFramesRead)
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
    
        result = miniaudio.engine_init(&engineConfig, &audio_ctx.g_engine)
        if (result != .SUCCESS) {
            fmt.printf("Failed to initialize audio engine.")
            return
        }
    
        result = miniaudio.sound_init_from_file(&audio_ctx.g_engine, "songs/test/test.mp3", {.STREAM}, nil, nil, &audio_ctx.g_sound)
        if (result != .SUCCESS) {
            fmt.printf("Failed to initialize sound.")
            return
        }
    
        // Register the callback, passing a pointer to the sound object as user data
        sdl.SetAudioStreamGetCallback(stream, miniaudio_data_callback, &audio_ctx.g_sound);
    
        // Bind the stream to a logical audio device
        sdl.BindAudioStreams(deviceID, &stream, 1);
        
        sdl.ResumeAudioDevice(deviceID)
        miniaudio.sound_start(&audio_ctx.g_sound)
    }

    window_init({w = 1024, h = 512})
    defer window_cleanup()

    renderer_init()
    renderer := &window.renderer
    defer renderer_cleanup()

    window_resize(i32(window.rect.w), i32(window.rect.h))

    mu_init :: proc() {
        mu.init(&window.ui_ctx)
        window.ui_ctx.text_width = mu.default_atlas_text_width
        window.ui_ctx.text_height = mu.default_atlas_text_height

        pixels := make([][4]u8, mu.DEFAULT_ATLAS_WIDTH*mu.DEFAULT_ATLAS_HEIGHT)
        defer delete(pixels)
        for alpha, i in mu.default_atlas_alpha {
            pixels[i] = {0xff, 0xff, 0xff, alpha}
        }
        
        window.ui_atlas_texture = texture_from_data(
            width = mu.DEFAULT_ATLAS_WIDTH,
            height = mu.DEFAULT_ATLAS_HEIGHT,
            data = raw_data(pixels),
            internal_format = gl.RGBA8,
            format = gl.RGBA,
        )
    }

    mu_init()
    text_init()
    
    load_skin_textures("skins/gn/")
    prepare_textures_for_rendering()

    builtin_shaders_watch := win32_init_directory_watch("shaders/")

    {
        ok: bool
        test_mapset_path := "songs/test/"
        game.active_mapset, ok = mapset_open_for_editing(test_mapset_path)
        game.active_map = &game.active_mapset.osu_map
        if !ok {
            fmt.println("tried to open mapset, but failed:", test_mapset_path)
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
                        case sdl.Scancode.F2:
                            debug_info.display_fontatlas = !debug_info.display_fontatlas
                        case sdl.Scancode.F3:
                            debug_info.display_memory_profiler = !debug_info.display_memory_profiler
                        case sdl.Scancode.F11:
                            debug_info.display_frame_profiler = !debug_info.display_frame_profiler
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
            
            r_bind_layer(.UI)
            r_push_transform(window_get_screenspace_transform())
            
            // game update
            render_input_display(&renderer.quad_geometry)            
            
            if selection_active {
                push_rect_outline_fill(&window.renderer.quad_geometry, rect_from_points(mouse.pos, selection_start_mouse_pos), 
                                       color_sky_blue, with_alpha(color_sky_blue, 0.3), 1)
            }
            
            cursor_rect: Rect = { f32(mouse.pos.x), f32(mouse.pos.y), 80, 80 }
            push_layout_rect(&renderer.quad_geometry, cursor_rect, .CENTER, color_white, skin_texture_slot(.CURSOR))

            r_push_transform(transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio))
            push_rect_outline(&renderer.quad_geometry, playfield_rect, with_alpha(color_white, 0.1), 2)
            
            r_bind_layer(.BACKGROUND)
        }
        
        {
            /*
                todo(isak): state of the renderer:
                usage:
                - the rect pushing in the draw section is artificial; only end_frame() needs to happen here
                    and maybe also profiler calls
                - batch overrun has not been tested but won't work; it should run end_frame().. probably
                - transforms should be a dynamic stack that we just write as we process the frame; can save a bunch
                    of draw calls
            */
            profiler_block_begin(.GAME_DRAW); defer profiler_block_end()

            if debug_info.display_fontatlas {
                r_push_transform(window_get_screenspace_transform())
                push_rect(&renderer.quad_geometry,
                    {0, 0, f32(text_engine.ctx.width), f32(text_engine.ctx.height)},
                    color_white,
                    reserved_texture(.FONT_ATLAS))
            }

            if debug_info.display_frame_profiler {
                r_push_transform(window_get_screenspace_transform())
                profiler_push_quad(&renderer.quad_geometry, frame_count)
            }

            for i in 0..<1 {
                render_slider(renderer, &test_slider)
            }
            r_bind_framebuffer({})
            
            r_push_transform(window_get_screenspace_transform())

            push_text(renderer, "饕餮尤魔 :3", {100, 100}, size=24)
            
            game_timer_str := fmt.tprintf("%.3f", game.active_map.play_timer_ms)
            push_text(renderer, game_timer_str, {20, 20}, size = 22)
            
            if debug_info.display_frame_profiler {
                profiler_push_blocks_as_text(renderer, frame_count)
            }
            if debug_info.display_memory_profiler {
                profiler_push_memory_diag_text(renderer)
            }
            
            r_bind_layer(.DEBUG, transform = window_get_screenspace_transform())
            mu.begin(&window.ui_ctx)
            render_debug_ui(&window.ui_ctx)
            mu.end(&window.ui_ctx)

            end_frame(renderer)
        }

        {
            profiler_block_begin(.SWAP_FRAME); defer profiler_block_end() 
            sdl.GL_SwapWindow(window.handle)
        }
        
        {
            profiler_block_begin(.BETWEEN_FRAMES); defer profiler_block_end() 

            process_builtin_shader_changes(&builtin_shaders_watch)

            if debug_info.display_frame_profiler {
                profiler_write_texture_column(frame_count, window.profiler_texture)

                if frame_count % 100 == 0 {
                    fmt.println("ms:", profiler_get_frametime())
                }
            }
            
            frame_count += 1
            
            virtual.arena_free_all(&memory.frame_arena)
            for layer in Layer {
                queue.clear(&window.renderer.layer_command_queues[layer])
            }
        }
    }
}

render_debug_ui :: proc(ctx: ^mu.Context) {

}

begin_frame :: proc(renderer: ^Renderer) {
    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
    
    batch_begin(renderer)
    
    r_bind_pipeline({.QUAD})
    r_push_transform(renderer.default_transform)

    r_bind_framebuffer(window.renderer.current_framebuffer)
    r_bind_pipeline(window.renderer.current_pipeline)
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    
    renderer.transform_queue.len = 0
}

end_frame :: proc(renderer: ^Renderer) {
    text_submit_geometry(renderer)

    profiler_collect_command_buffer_memory_data()
    batch_end(renderer)
}

process_builtin_shader_changes :: proc(watch: ^Win32_Directory_Watch) {
    updated_systems := mapset_check_system_file_watch(watch)
    if updated_systems[.SHADERS] {
        for &shader in window.shaders {
            reinit_shader(&shader)
        }
        fmt.println("reloaded builtin shaders")

        reinit_pipeline(&window.pipelines[.QUAD], quad_pipeline())
        reinit_pipeline(&window.pipelines[.SLIDER], slider_pipeline())
        reinit_pipeline(&window.pipelines[.TEXT], text_pipeline())
    }
}
