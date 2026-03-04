package notosu

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import os "core:os/os2"
import "core:sys/windows"
import "core:time"
import vmem "core:mem/virtual"

import mu "vendor:microui"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import stbi "vendor:stb/image"

/*
todo(isak):

communication layer:
core runtime info such as map time and objects
- state buffer
- graphics buffer (will be uploaded to gpu, loaded pipelines (shaders) work with it)
    are these just defined as lua metatables?
- expose rendering and resource api


general:
ui core 
    map selector
    skin select
    volume settings

"full" .osu support (no sb, editor features, osu integration)

play mode:
audio play (miniaudio)
    desync proofing (always wait for sound to be able to be played, like osu (so device errors will just freeze the game))
    multiple channels, sound effects

editor mode:
(viewer mode only? edit functionality is probably low priority, osu can be used for the map)

eventual YEAST on-scene features:
local networking
    multiple client sync
    potentially display other client cursors? w

*/

Memory_Arenas :: enum {
    // note(isak): never cleared. used instead of odin's regular arena to keep track of our allocations
    GLOBAL,
    
    // note(isak): this is to be used for mapset runtime data, such as timing state, judgements, etc. (fill in)
    // cleared on mapset reload/unload
    MAPSET,
    
    // note(isak): this is to be used for graphical entity data, "unbounded" since it's written to by
    // game logic and scripts. cleared on mapset reload/unload
    DRAWABLES,
    
    // note(isak): temporary allocator. cleared on frame end
    FRAME,
}

memory_arena_names := [?]string {
    "Global",
    "Mapset",
    "Entities",
    "Frame",
    "Command buffer[BACKGROUND]",
    "Command buffer[FOREGROUND]",
    "Command buffer[HIT_OBJECT]",
    "Command buffer[OVERLAY]",
    "Command buffer[UI]",
    "Command buffer[DEBUG]",
}

memory: struct {
    allocators: [Memory_Arenas]runtime.Allocator,
    arenas: [Memory_Arenas]vmem.Arena,
    
    backing_alloc: [Memory_Arenas]runtime.Allocator,
    tracker: [Memory_Arenas]Guarding_Allocator,
    
    command_buffer_allocators: [Layer]runtime.Allocator,
    command_buffer_arenas: [Layer]vmem.Arena,
}

// note(isak): this should take care of error printing
memory_init :: proc() -> runtime.Allocator_Error {
    arenas := &memory.arenas
    allocators := &memory.allocators
    
    init_tracked_growing_arena(&arenas[.GLOBAL], &allocators[.GLOBAL], 
        &memory.backing_alloc[.GLOBAL], &memory.tracker[.GLOBAL]) or_return
    init_tracked_growing_arena(&arenas[.MAPSET], &allocators[.MAPSET], 
        &memory.backing_alloc[.MAPSET], &memory.tracker[.MAPSET]) or_return
    init_tracked_growing_arena(&arenas[.DRAWABLES], &allocators[.DRAWABLES], 
        &memory.backing_alloc[.DRAWABLES], &memory.tracker[.DRAWABLES]) or_return
    init_tracked_growing_arena(&arenas[.FRAME], &allocators[.FRAME], 
        &memory.backing_alloc[.FRAME], &memory.tracker[.FRAME]) or_return

    for layer in Layer {
        init_growing_arena(&memory.command_buffer_arenas[layer], &memory.command_buffer_allocators[layer]) or_return
    }
    return .None
}

debug_ui_init :: proc() {
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

window: struct {
    rect: Rect,
    aspect_ratio: f32, // note(isak): height over width
    screenspace_transform: Transform,
    playfield_to_screenspace_transform: Transform,
    renderer: Renderer,

    cursor_hidden: bool,

    handle: ^sdl.Window,
    gl_context: sdl.GLContext,
    
    ui_enabled: bool,
    ui_ctx: mu.Context,
    ui_hovered: bool,
    ui_dragging: bool,
    
    // note(isak): graphical resources used by the drawing context go here 

    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,

    shaders: queue.Queue(Shader),
    pipelines: queue.Queue(sg.Pipeline),
    framebuffers: [Framebuffer_ID]GL_Framebuffer,
    
    // note(isak): we make a distinction between static and dynamic geometry; dynamic can be streamed
    // data into efficiently by using a triple buffer setup, while static is single-buffered and is fit
    // for bigger data that isn't updated as often (such as during a loading screen)

    // note(isak): single quad buffer for deferred rendering quad store, unused
    fullscreen_store: GL_Buffer(Quad),

    quad_store: GL_Triple_Buffer(Quad),
    
    slider_instance_store: GL_Buffer(vec2),
    
    text_store: GL_Triple_Buffer(Glyph_Quad),
    
    shader_global_buffer: GL_Uniform_Buffer(Shader_Globals),
    circle_geo_buffer: GL_Buffer(Slider_Vertex),
    texture_buffer: GL_Buffer(u64),

    white_texture: Texture,
    profiler_texture: Texture,
    font_atlas_texture: Texture,
    ui_atlas_texture: Texture,

    skin_textures: [Skin_Element_Type]Texture,
    is_high_resolution: [Skin_Element_Type]bool
}

window_init :: proc(rect: Rect) {
    windows.SetProcessDPIAware()
    window.rect = rect
    window.handle = sdl.CreateWindow("notosu!", i32(rect.w), i32(rect.h), sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    window.aspect_ratio = f32(rect.h) / f32(rect.w)

    stbi.set_flip_vertically_on_load_thread(true)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 4)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 6)
    sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengl")

    sdl.GL_SetSwapInterval(0)
    sdl.SetWindowSurfaceVSync(window.handle, 0)

    window.gl_context = sdl.GL_CreateContext(window.handle)
    gl.load_up_to(4, 6, sdl.gl_set_proc_address)
    gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE)
    gl.Enable(gl.SCISSOR_TEST)

    win_x, win_y: i32
    sdl.GetWindowPosition(window.handle, &win_x, &win_y)
    window.rect.x = f32(win_x)
    window.rect.y = f32(win_y)

    window.cursor_hidden = sdl.HideCursor()
}

window_resize :: proc(new_w, new_h: i32) {
    window.rect.w = f32(new_w)
    window.rect.h = f32(new_h)
    window.swapchain.width = new_w
    window.swapchain.height = new_h
    window.aspect_ratio = window.rect.h / window.rect.w
    window.screenspace_transform = transform_from_bounds({0, 0, window.rect.w, window.rect.h}, 1)
    game.playfield_transform = transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    fbo_reinit(&window.framebuffers[.SLIDERS], new_w, new_h)
}

playfield_to_screenspace_transform :: proc() -> mat3 {
    side := window.rect.h
    offset_x := (window.rect.w - side) * 0.5
    viewport_rect := vec4{offset_x, 0, side, side}
    screen_to_ndc := transform_to_mat3(transform_from_bounds(viewport_rect, window.aspect_ratio))
    
    return transform_to_mat3(game.playfield_transform) * linalg.matrix3_inverse(screen_to_ndc)
}

clipspace_transform := transform_from_bounds({0, 0, 1, 1}, 1)

window_cleanup :: proc() {
    sdl.GL_DestroyContext(window.gl_context)
    sdl.DestroyWindow(window.handle)
}


Mouse_Button :: enum {
    LEFT,
    RIGHT,
    MIDDLE,
}

Button_State :: struct {
    is_down, was_down: bool
}

mouse: struct {
    pos: vec2,
    buttons: [Mouse_Button]Button_State,
    last_click_position: [Mouse_Button]vec2,
}


Keyboard_State :: #sparse [sdl.Scancode]bool

keyboard: struct {
    buttons: ^Keyboard_State,
    buttons_prev_frame: ^Keyboard_State,

    state: [2]Keyboard_State,
    // note(isak): if there's a reason to add text input (that's not microui related), we might wanna add some locale
    // info or state related to character translation messages
}

keyboard_init :: proc() {
    keyboard.buttons = &keyboard.state[0]
    keyboard.buttons_prev_frame = &keyboard.state[1]
}

keyboard_next_frame :: proc() {
    keyboard.buttons, keyboard.buttons_prev_frame = keyboard.buttons_prev_frame, keyboard.buttons

    num_keys: i32
    sdl_state := sdl.GetKeyboardState(&num_keys)
    mem.copy(keyboard.buttons, sdl_state, len(Keyboard_State))
}

rebind_input :: proc(event: sdl.Event, rebind: ^sdl.Scancode) {
    if (event.type == sdl.EventType.KEY_DOWN) {
        rebind^ = event.key.scancode //TODO(yokes): this doesn't work, game.input.k1_key = event.key.scancode works
        fmt.printfln("key set to {}", event.key.scancode)
    }
}

main :: proc() {
    _program_start_tsc = sdl.GetPerformanceCounter()
    
    if memory_init() != .None {
        panic("memory_init :: error")
    }
    
    // note(isak): context stuff must be set in main scope
    context.allocator = memory.allocators[.GLOBAL]
    context.temp_allocator = memory.allocators[.FRAME]
    
    app_init()
    context.logger = app.logger 
    defer app_cleanup()

    if (!sdl.Init({.VIDEO})) {
        log.panic("SDL video init error:", sdl.GetError())
    }

    window_init({w = 1024, h = 512})
    window.ui_enabled = true
    defer window_cleanup()
    
    audio_init()
    assert(audio.ready)
    defer audio_cleanup()
    
    audio_set_volume(0.05)

    renderer_init()
    renderer := &window.renderer
    defer renderer_cleanup()

    window_resize(i32(window.rect.w), i32(window.rect.h))

    debug_ui_init()
    text_init()
    keyboard_init()
    
    load_skin_textures("skins/gn/")

    shaders_watch := win32_init_directory_watch("shaders/")

    {
        ok: bool
        test_mapset_path := "songs/test/"
        
        game.active_mapset, ok = mapset_open_for_editing(test_mapset_path)
        game.active_notosu_map = &game.active_mapset.notosu_map
        game.active_map = &game.active_mapset.osu_map
        if !ok {
            log.error("tried to open mapset, but failed:", test_mapset_path)
        }
        
        // todo(isak): dependent on map load... make a more granular api for map load purposes
        prepare_textures_for_rendering()
    }
    

    osu_on_init()

    time_current_frame := current_time_s()
    time_first_frame := time_current_frame
    time_last_frame := time_current_frame
    frame_count: u64

    running := true
    event: sdl.Event

    for running {
        profiler_begin()
        defer profiler_end()

        {
            profiler_block_begin(.MESSAGE_HANDLING); defer profiler_block_end()

            // message handling, time handling
            for &button in mouse.buttons {
                button.was_down = button.is_down
            }
            
            // todo(isak): game input should happen in a separate thread for input resolution purposes

            for sdl.PollEvent(&event) {
                #partial switch event.type {
                case sdl.EventType.MOUSE_BUTTON_DOWN:
                    switch event.button.button {
                        case sdl.BUTTON_LEFT:
                            mouse.buttons[.LEFT].is_down = true
                            mouse.last_click_position[.LEFT] = {event.button.x, event.button.y}
                            mu.input_mouse_down(&window.ui_ctx, i32(event.button.x), i32(event.button.y), .LEFT)
                        case sdl.BUTTON_MIDDLE:
                            mouse.buttons[.MIDDLE].is_down = true
                            mouse.last_click_position[.MIDDLE] = {event.button.x, event.button.y}
                            mu.input_mouse_down(&window.ui_ctx, i32(event.button.x), i32(event.button.y), .MIDDLE)
                        case sdl.BUTTON_RIGHT:
                            mouse.buttons[.RIGHT].is_down = true
                            mouse.last_click_position[.RIGHT] = {event.button.x, event.button.y}
                            mu.input_mouse_down(&window.ui_ctx, i32(event.button.x), i32(event.button.y), .RIGHT)
                    }

                case sdl.EventType.MOUSE_BUTTON_UP:
                    switch event.button.button {
                        case sdl.BUTTON_LEFT:
                            mouse.buttons[.LEFT].is_down = false
                            mu.input_mouse_up(&window.ui_ctx, i32(event.button.x), i32(event.button.y), .LEFT)
                        case sdl.BUTTON_MIDDLE:
                            mouse.buttons[.MIDDLE].is_down = false
                            mu.input_mouse_up(&window.ui_ctx, i32(event.button.x), i32(event.button.y), .MIDDLE)
                        case sdl.BUTTON_RIGHT:
                            mouse.buttons[.RIGHT].is_down = false
                            mu.input_mouse_up(&window.ui_ctx, i32(event.button.x), i32(event.button.y), .RIGHT)
                    }
                    
                case sdl.EventType.WINDOW_RESIZED:
                    cleanup_textures_for_rendering()
                    window_resize(max(event.window.data1, 1), max(event.window.data2, 1))
                    prepare_textures_for_rendering()
                        
                case sdl.EventType.WINDOW_FOCUS_LOST:
                    window.ui_dragging = false
                    
                case sdl.EventType.QUIT:
                    running = false
                }

                /*if is_down(game.input.m1) {
                    rebind_input(event, &game.input.k1_key)
                }

                if is_down(game.input.m2) {
                    rebind_input(event, &game.input.k2_key)
                }*/
            }

            keyboard_next_frame()
            
            xi, yi: i32
            mouse_flags := sdl.GetGlobalMouseState(&mouse.pos.x, &mouse.pos.y)
            sdl.GetWindowPosition(window.handle, &xi, &yi)

            mouse.pos.x = mouse.pos.x - f32(xi)
            mouse.pos.y = mouse.pos.y - f32(yi)
            
            pf_mouse := vec2{mouse.pos.x, mouse.pos.y}
            pf_mouse.x -= (window.rect.w - window.rect.h) / 2
            
            game.input.mouse_pos = transform_point_space(pf_mouse,
                transform_to_mat3(window.screenspace_transform), 
                transform_to_mat3(game.playfield_transform)
            )
            
            mu.input_mouse_move(&window.ui_ctx, i32(mouse.pos.x), i32(mouse.pos.y))
        }

        {
            profiler_block_begin(.PREPARE_FRAME); defer profiler_block_end() 
            
            time_last_frame = time_current_frame
            time_current_frame = current_time_s()

            // prepare drawing
            begin_frame(renderer)
        }
        
        {   
            profiler_block_begin(.GAME_UPDATE); defer profiler_block_end()
            
            r_bind_layer_and_push_current_state(.DEBUG, transform = window.screenspace_transform)
            if window.ui_enabled {
                r_push_transform(window.screenspace_transform)
                mu.begin(&window.ui_ctx)
                write_debug_ui(&window.ui_ctx)
                mu.end(&window.ui_ctx)
                handle_debug_ui_events(&window.ui_ctx)
                render_debug_ui(renderer, &window.ui_ctx)
            }
            
            dt_ms := (time_current_frame - time_last_frame) * 1000

            r_bind_layer_and_push_current_state(.BACKGROUND, transform = window.screenspace_transform)
            osu_on_update(dt_ms)

            r_bind_layer_and_push_current_state(.UI, pipeline = {builtin_pipeline_slot(.QUAD)})
            
            r_push_transform(window.screenspace_transform)
            
            cursor_rect: Rect = { f32(mouse.pos.x), f32(mouse.pos.y), 80, 80 }
            r_draw_layout_rect(&renderer.quad_geometry, cursor_rect, .CENTER, color_white, skin_texture(.CURSOR),
                f32(time_s_since_beginning_of_program()*20))
            
            r_push_transform(transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio))
            
            pf_cur_rect: Rect = { game.input.mouse_pos.x, game.input.mouse_pos.y, 20, 20 }
            r_draw_layout_rect(&renderer.quad_geometry, pf_cur_rect, .CENTER, color_red, builtin_texture(.WHITE),
                f32(time_s_since_beginning_of_program()*20))
            r_draw_rect_outline(&renderer.quad_geometry, playfield_rect, with_alpha(color_white, 0.1), 2)
        }
        
        {
            /*
                todo(isak): state of the renderer:
                usage:
                - batch overrun has not been tested
                - transforms should be a dynamic stack that we just write as we process the frame; can save a bunch
                    of draw calls
            */
            profiler_block_begin(.GAME_DRAW); defer profiler_block_end()
            
            r_bind_layer_and_push_current_state(.DEBUG, transform = window.screenspace_transform)

            if app.debug_display_fontatlas {
                r_draw_rect(&renderer.quad_geometry,
                    {0, 0, f32(text_engine.ctx.width), f32(text_engine.ctx.height)},
                    color_white,
                    builtin_texture(.FONT_ATLAS))
            }

            if app.debug_display_frame_profiler {
                profiler_push_blocks_as_text(renderer, frame_count)
                profiler_push_quad(&renderer.quad_geometry, frame_count)
            }
            if app.debug_display_memory_profiler {
                profiler_push_memory_diag_text(renderer)
            }
            end_frame(renderer)
        }

        {
            profiler_block_begin(.SWAP_FRAME); defer profiler_block_end()
            sdl.GL_SwapWindow(window.handle)
        }
        
        {
            profiler_block_begin(.BETWEEN_FRAMES); defer profiler_block_end() 

            process_builtin_shader_changes(&shaders_watch)

            if app.debug_display_frame_profiler {
                profiler_write_texture_column(frame_count, window.profiler_texture)

                if frame_count % 100 == 0 {
                    fmt.println("ms:", profiler_get_fps())
                }
            }
            
            frame_count += 1
            
            vmem.arena_free_all(&memory.arenas[.FRAME])
            for layer in Layer {
                queue.clear(&window.renderer.layer_command_queues[layer])
            }
        }
    }
}

_debug_ui_initialized: int

write_debug_ui :: proc(ctx: ^mu.Context) {
    @static opts := mu.Options{.NO_CLOSE}
    init_opts := _debug_ui_initialized < 2 ? mu.Options{.AUTO_SIZE} : {}
    _debug_ui_initialized += 1
    
    if mu.window(ctx, "饕餮尤魔 :3", {}, opts + init_opts) {
        mu.layout_row(ctx, {54, -1}, 0)
        mu.label(ctx, "Time:")
        
        timer_str := time_ms_to_string(game.beatmap.music_time_ms)
        mu.label(ctx, timer_str)
        
        mu.layout_row(ctx, {54, -1}, 0)
        mu.label(ctx, "Time rate:")
        mu.label(ctx, fmt.tprintf("%f%s", game.time_rate * (game.paused ? 0 : 1), game.paused ? " (paused)": ""))
        
        mu.layout_row(ctx, {100, 10, -1}, 0)
        mu.label(ctx, "Visible hitobjects:")
        hobj_visibility := game.beatmap.visible_hit_object_state
        mu.label(ctx, fmt.tprintf("%i", hobj_visibility.latest_i - hobj_visibility.earliest_i - 1))
        
        mu.layout_row(ctx, {80, 10, -1}, 0)
        mu.label(ctx, "Mouse keys:")
        mu.label(ctx, game.input.mouse_keys_enabled ? "on" : "off")
    }
}

handle_debug_ui_events :: proc(ctx: ^mu.Context) {
    if is_key_pressed(.F1) {
        window.renderer.trace_frame = !window.renderer.trace_frame
    }
    if is_key_pressed(.F2) {
        app.debug_display_slider_bounds = !app.debug_display_slider_bounds
    }
    if is_key_pressed(.F3) {
        app.debug_display_frame_profiler = !app.debug_display_frame_profiler
    }
    if is_key_pressed(.F4) {
        app.debug_display_memory_profiler = !app.debug_display_memory_profiler
        
        track := &memory.tracker[.GLOBAL]
        if len(track.alloc.allocation_map) > 0 {
            fmt.eprintf("=== global allocator - %v allocations not freed: ===\n", len(track.alloc.allocation_map))
            for _, entry in track.alloc.allocation_map {
                fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
            }
        }
    }

    // note(isak): handle offscreen windows
    if ctx.focus_id > 0 && is_down(mouse.buttons[.LEFT]) {
        window.ui_dragging = true
    }
    if is_released(mouse.buttons[.LEFT]) {
        for container in ctx.root_list.items[:ctx.root_list.idx] {
            confined_rect := mu.Rect{ 
                0,
                0,
                max(i32(window.rect.w) - container.rect.w, 0), 
                max(i32(window.rect.h) - ctx.style.title_height, 0)
            }
            if container.rect.w > i32(window.rect.w) {
                container.rect.w = min(i32(window.rect.w), container.rect.w)
                container.rect.x = 0
            }
            if container.rect.h > i32(window.rect.h) {
                container.rect.h = min(i32(window.rect.h), container.rect.h)
                container.rect.y = 0
            }
            
            if container.rect.x < confined_rect.x {
                container.rect.x = max(confined_rect.x, container.rect.x)
            } else if container.rect.x > confined_rect.w {
                container.rect.x = min(confined_rect.w, container.rect.x)
            }

            if container.rect.y < confined_rect.y {
                container.rect.y = max(confined_rect.y, container.rect.y)
            } else if container.rect.y > confined_rect.h {
                container.rect.y = min(confined_rect.h, container.rect.y)
            }
        }
        window.ui_dragging = false
    }
    
    window.ui_hovered = false
    for container in ctx.root_list.items[:ctx.root_list.idx] {
        if mu.rect_overlaps_vec2(container.rect, ctx.mouse_pos) {
            window.ui_hovered = true
            break
        }
    }
    
    // note(isak): handle cursor visibility inside ui rects
    if window.cursor_hidden {
        for container in ctx.root_list.items[:ctx.root_list.idx] {
            if mu.rect_overlaps_vec2(container.rect, ctx.mouse_pos) {
                window.cursor_hidden = !sdl.ShowCursor()
                break
            }
        }
    } else {
        for container in ctx.root_list.items[:ctx.root_list.idx] {
            if mu.rect_overlaps_vec2(container.rect, ctx.mouse_pos) {
                continue
            }
            window.cursor_hidden = sdl.HideCursor()
        }
    }
}

render_debug_ui :: proc(renderer: ^Renderer, ctx: ^mu.Context) {
    push_icon :: proc(renderer: ^Renderer, rect, icon_rect: mu.Rect, color: Color) {
        pos := Rect{f32(rect.x + icon_rect.w/2), f32(rect.y + icon_rect.h/2), f32(icon_rect.w), f32(icon_rect.h)}
        uv := Rect{
            f32(icon_rect.x) / f32(window.ui_atlas_texture.w), 
            f32(icon_rect.y) / f32(window.ui_atlas_texture.h), 
            f32(icon_rect.w) / f32(window.ui_atlas_texture.w), 
            f32(icon_rect.h) / f32(window.ui_atlas_texture.h)
        }
        r_draw_rect_with_uv(&renderer.quad_geometry, pos, uv, color, builtin_texture(.UI_ATLAS))
    }

    command_backing: ^mu.Command
    for variant in mu.next_command_iterator(ctx, &command_backing) {
        #partial switch cmd in variant {
            case ^mu.Command_Text:
                push_text(renderer, cmd.str, {f32(cmd.pos.x), f32(cmd.pos.y)}, size = 16, align_v = .Top )
            case ^mu.Command_Clip:
                r_begin_scissor_mode_pixels(cmd.rect.x, cmd.rect.y, cmd.rect.w, i32(window.rect.h) - cmd.rect.h)
            case ^mu.Command_Rect:
                r_draw_rect(&renderer.quad_geometry, 
                    {f32(cmd.rect.x), f32(cmd.rect.y), f32(cmd.rect.w), f32(cmd.rect.h)}, 
                    transmute(Color)cmd.color)
            case ^mu.Command_Icon:
                icon_rect := mu.default_atlas[cmd.id]
                push_icon(renderer, cmd.rect, icon_rect, transmute(Color)cmd.color)
        }
    }
    r_reset_scissor_mode()
}

begin_frame :: proc(renderer: ^Renderer) {
    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })
    
    batch_begin(renderer)

    r_set_shader_globals({
        transform = identity_transform,
        circle_size_osupx = game.beatmap.circle_radius_osupx,
        time = f32(game.beatmap.music_time_ms)
    })

    r_bind_layer(.BACKGROUND)
    r_bind_pipeline({builtin_pipeline_slot(.QUAD)})
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(identity_transform)
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
        for &shader in window.shaders.data {
            shader_reinit(&shader)
        }
        fmt.println("reloaded builtin shaders")

        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.QUAD)], quad_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.SLIDER)], slider_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.TEXT)], text_pipeline_desc())
    }
}
