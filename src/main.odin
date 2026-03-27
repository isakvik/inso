package notosu

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:time"
import vmem "core:mem/virtual"

import gl "vendor:OpenGL"
import imgui "imgui"
import imgui_gl3 "imgui/imgui_impl_opengl3"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"

/*
todo(isak):


eventual YEAST on-scene features:
local networking
    multiple client sync
    potentially display other client cursors? w

*/

Memory_Arena_Type :: enum {
    // note(isak): never cleared. used instead of odin's regular arena to keep track of our allocations
    GLOBAL,
    
    // note(isak): this is to be used for mapset runtime data, such as timing state, judgements, etc. (fill in)
    // cleared on mapset reload/unload
    MAPSET,
    
    // note(isak): this is to be used for graphical entity data, "unbounded" since it's written to by
    // game logic and scripts. cleared on mapset reload/unload
    DRAWABLES,
    
    // note(isak): judgements (unbounded). cleared on mapset reload/unload
    JUDGEMENTS,
    
    // note(isak): skin data (names, paths)
    // cleared on skin unload
    SKIN,

    // note(isak): active sound channels (Sound_Channel slotmap). freed and reinited on game_clear_sounds
    SOUND,

    // note(isak): temporary allocator. cleared on frame end
    FRAME,
}

memory_arena_names := [?]string {
    "Global",
    "Mapset",
    "Entities",
    "Judgements",
    "Skin",
    "Sound",
    "Frame",
    "Command buffer[BACKGROUND]",
    "Command buffer[FOREGROUND]",
    "Command buffer[HITOBJECT]",
    "Command buffer[OVERLAY]",
    "Command buffer[UI]",
    "Command buffer[DEBUG]",
}

memory: struct {
    allocators: [Memory_Arena_Type]runtime.Allocator,
    arenas: [Memory_Arena_Type]vmem.Arena,
    
    backing_alloc: [Memory_Arena_Type]runtime.Allocator,
    tracker: [Memory_Arena_Type]Guarding_Allocator,
    
    command_buffer_allocators: [Layer]runtime.Allocator,
    command_buffer_arenas: [Layer]vmem.Arena,
}

// note(isak): this should take care of error printing
memory_init :: proc() -> runtime.Allocator_Error {
    arenas := &memory.arenas
    allocators := &memory.allocators
    
    for t in Memory_Arena_Type {
        init_tracked_growing_arena(&arenas[t], &allocators[t], &memory.backing_alloc[t], &memory.tracker[t]) or_return
    }
    for layer in Layer {
        init_growing_arena(&memory.command_buffer_arenas[layer], &memory.command_buffer_allocators[layer]) or_return
    }
    return .None
}

debug_ui_init :: proc() {
    imgui.CHECKVERSION()
    imgui.CreateContext()
    io := imgui.GetIO()
    io.ConfigFlags += {.NavEnableKeyboard}
    imgui.FontAtlas_AddFontFromFileTTF(io.Fonts, "data/segoeui.ttf", 16)
    imgui_gl3.Init("#version 460")
    
    window.map_dropdown = Debug_Dropdown{
        label    = "Map",
        items    = &app.map_reference_names,
        selected = 0,
    }
}

debug_ui_cleanup :: proc() {
    imgui_gl3.Shutdown()
    imgui.DestroyContext()
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

    window_init({w = 1280, h = 720})
    window.ui_enabled = true
    defer window_cleanup()
    
    audio_init()
    assert(audio.ready)
    defer audio_cleanup()
    
    audio_set_volume(0.05)

    renderer_init()
    renderer := &window.renderer
    defer renderer_cleanup()

    window_on_resize(i32(window.rect.w), i32(window.rect.h))

    debug_ui_init()
    defer debug_ui_cleanup()
    text_init()
    keyboard_init()
    
    game.active_skin = skin_load("skins/gn/")

    shaders_watch := win32_init_directory_watch("shaders/")

    songs_discover_maps("songs/")

    //-- @temp
    {
        ok: bool
        initial_map_ref := 
            len(app.map_references) > 0 ? app.map_references[0] : Map_Reference{ folder_path = "songs/test/" }

        game.active_mapset, ok = mapset_open_for_editing(initial_map_ref.folder_path, initial_map_ref.osu_filename)
        game.active_notosu_map = &game.active_mapset.notosu_map
        game.active_map = &game.active_mapset.osu_map
        game.active_map_ref = initial_map_ref
        
        if !ok {
            log.error("tried to open mapset, but failed:", initial_map_ref.folder_path)
        }

        prepare_textures_for_rendering()
    }
    //--

    osu_on_init()

    time_current_frame := current_time_s()
    time_first_frame := time_current_frame
    time_last_frame := time_current_frame
    frame_count: u64

    running := true
    event: sdl.Event
    
    app.debug_display_game_cursor = true

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
                    io := imgui.GetIO()
                    switch event.button.button {
                        case sdl.BUTTON_LEFT:
                            mouse.buttons[.LEFT].is_down = true
                            mouse.last_click_position[.LEFT] = {event.button.x, event.button.y}
                            imgui.IO_AddMouseButtonEvent(io, 0, true)
                        case sdl.BUTTON_MIDDLE:
                            mouse.buttons[.MIDDLE].is_down = true
                            mouse.last_click_position[.MIDDLE] = {event.button.x, event.button.y}
                            imgui.IO_AddMouseButtonEvent(io, 2, true)
                        case sdl.BUTTON_RIGHT:
                            mouse.buttons[.RIGHT].is_down = true
                            mouse.last_click_position[.RIGHT] = {event.button.x, event.button.y}
                            imgui.IO_AddMouseButtonEvent(io, 1, true)
                    }

                case sdl.EventType.MOUSE_BUTTON_UP:
                    io := imgui.GetIO()
                    switch event.button.button {
                        case sdl.BUTTON_LEFT:
                            mouse.buttons[.LEFT].is_down = false
                            imgui.IO_AddMouseButtonEvent(io, 0, false)
                        case sdl.BUTTON_MIDDLE:
                            mouse.buttons[.MIDDLE].is_down = false
                            imgui.IO_AddMouseButtonEvent(io, 2, false)
                        case sdl.BUTTON_RIGHT:
                            mouse.buttons[.RIGHT].is_down = false
                            imgui.IO_AddMouseButtonEvent(io, 1, false)
                    }

                case sdl.EventType.MOUSE_WHEEL:
                    imgui.IO_AddMouseWheelEvent(imgui.GetIO(), event.wheel.x, event.wheel.y)

                case sdl.EventType.KEY_DOWN:
                    imgui.IO_AddKeyEvent(imgui.GetIO(), sdl_scancode_to_imgui(event.key.scancode), true)
                case sdl.EventType.KEY_UP:
                    imgui.IO_AddKeyEvent(imgui.GetIO(), sdl_scancode_to_imgui(event.key.scancode), false)
                case sdl.EventType.TEXT_INPUT:
                    imgui.IO_AddInputCharactersUTF8(imgui.GetIO(), event.text.text)

                case sdl.EventType.WINDOW_RESIZED:
                    cleanup_textures_for_rendering()
                    window_on_resize(max(event.window.data1, 1), max(event.window.data2, 1))
                    prepare_textures_for_rendering()

                case sdl.EventType.WINDOW_FOCUS_LOST:
                    imgui.IO_AddFocusEvent(imgui.GetIO(), false)

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

            imgui.IO_AddMousePosEvent(imgui.GetIO(), mouse.pos.x, mouse.pos.y)
        }

        {
            profiler_block_begin(.PREPARE_FRAME); defer profiler_block_end()

            time_last_frame = time_current_frame
            time_current_frame = current_time_s()

            io := imgui.GetIO()
            io.DisplaySize = {window.rect.w, window.rect.h}
            io.DeltaTime   = f32(time_current_frame - time_last_frame)

            // prepare drawing
            begin_frame(renderer)
        }

        {
            profiler_block_begin(.GAME_UPDATE); defer profiler_block_end()
            
            handle_debug_ui_events(&window.map_dropdown)
            
            r_bind_layer_and_push_current_state(.DEBUG, transform = window.screenspace_transform)
            
            dt_ms := (time_current_frame - time_last_frame) * 1000

            r_bind_layer_and_push_current_state(.BACKGROUND, transform = window.screenspace_transform)
            osu_on_update(dt_ms)

            r_bind_layer_and_push_current_state(.UI, pipeline = {builtin_pipeline_slot(.QUAD)})
            
            r_push_transform(window.screenspace_transform)
            
            cursor_rect: Rect = { f32(mouse.pos.x), f32(mouse.pos.y), 80, 80 }
            r_draw_layout_rect(&renderer.quad_geometry, cursor_rect, .CENTER, color_white, skin_texture(.CURSOR),
                f32(time_s_since_beginning_of_program()))
            
            if app.debug_display_game_cursor {
                r_push_transform(game.playfield_transform)
                pf_cur_rect: Rect = { game.input.mouse_pos.x, game.input.mouse_pos.y, 20, 20 }
                r_draw_layout_rect(&renderer.quad_geometry, pf_cur_rect, .CENTER, color_red, builtin_texture(.WHITE),
                    f32(time_s_since_beginning_of_program()))
            }
            
            r_push_transform(game.playfield_transform)
            
            cs := game.beatmap.circle_radius_osupx
            pf_outline := Rect{
                -cs, -cs, playfield_size_osupx+2*cs, (playfield_size_osupx*3/4)+2*cs
            }
            r_draw_rect_outline(&renderer.quad_geometry, pf_outline, with_alpha(color_white, 0.1), 2)
        }
        
        {
            /*
                todo(isak): state of the renderer:
                usage:
                - batch overrun has not been tested (although an infinite loop crashes, which is expected) @beta
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
            
            if window.ui_enabled {
                imgui.Render()
                imgui_gl3.RenderDrawData(imgui.GetDrawData())
            }
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

begin_frame :: proc(renderer: ^Renderer) {
    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })

    batch_begin(renderer)

    r_set_shader_globals({
        transform = identity_transform,
        circle_size_osupx = game.beatmap.circle_radius_osupx,
        time = f32(beatmap_music_time_ms(&game.beatmap))
    })

    r_bind_layer(.BACKGROUND)
    r_bind_pipeline({builtin_pipeline_slot(.QUAD)})
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(identity_transform)
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_reset_scissor_mode()

    renderer.transform_queue.len = 0

    if window.ui_enabled {
        imgui_gl3.NewFrame()
        imgui.NewFrame()
        write_debug_ui(&window.map_dropdown)
    }
}

end_frame :: proc(renderer: ^Renderer) {
    text_submit_geometry(renderer)
    profiler_collect_command_buffer_memory_data()
    batch_end(renderer)
}


write_debug_ui :: proc(map_dropdown: ^Debug_Dropdown) {
    imgui.Begin("Info")
    defer imgui.End()

    timer_str := strings.clone_to_cstring(time_ms_to_string(beatmap_music_time_ms(&game.beatmap)), context.temp_allocator)
    imgui.Text("Time: %s", timer_str)
    imgui.Text("Time rate: %.3f%s",
        game.time_rate * (game.paused ? f32(0) : f32(1)),
        game.paused ? cstring(" (paused)") : cstring(""))

    hobj_visibility := game.beatmap.visible_hitobject_state
    imgui.Text("Visible hitobjects: %d", i32(hobj_visibility.latest_i - hobj_visibility.earliest_i - 1))
    imgui.Text("Mouse keys: %s", game.input.mouse_keys_enabled ? cstring("on") : cstring("off"))
    imgui.Text("Universal offset: %d ms", i32(game.universal_offset_ms))
    
    
    imgui.Text("Music pos: %f ms", f32(game.beatmap.music_time_ms))
    imgui.Text("Sound pos: %f ms", f32(sound_get_position_ms(&game.beatmap.music)))
    
    
    
    
    imgui.Separator()
    debug_dropdown_update(map_dropdown)
}

handle_debug_ui_events :: proc(map_dropdown: ^Debug_Dropdown) {
    if map_dropdown.changed && map_dropdown.selected < len(app.map_references) {
        osu_switch_map(app.map_references[map_dropdown.selected])
    }
    if is_key_pressed(.F1) {
        window.renderer.trace_frame = !window.renderer.trace_frame
    }
    if is_key_pressed(.F2) {
        app.debug_display_slider_bounds = !app.debug_display_slider_bounds
        app.debug_display_game_cursor = !app.debug_display_game_cursor
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

    // note(isak): cursor visibility - show OS cursor when imgui wants the mouse
    want_mouse := imgui.GetIO().WantCaptureMouse
    if window.cursor_hidden && want_mouse {
        window.cursor_hidden = !sdl.ShowCursor()
    } else if !window.cursor_hidden && !want_mouse {
        window.cursor_hidden = sdl.HideCursor()
    }
}

process_builtin_shader_changes :: proc(watch: ^Win32_Directory_Watch) {
    updated_systems := mapset_check_system_file_watch(watch)
    if updated_systems[.SHADERS] {
        for &shader in window.shaders.data[:len(Builtin_Pipeline_Slot)] {
            shader_reinit(&shader)
        }
        // note(isak): mapset custom shaders may share a builtin VS, so reinit them too
        mapset_reinit_custom_shaders(game.active_mapset)
        
        fmt.println("reloaded mapset shaders")

        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.QUAD)], quad_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.SLIDER)], slider_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.TEXT)], text_pipeline_desc())

    }
}

sdl_scancode_to_imgui :: proc(sc: sdl.Scancode) -> imgui.Key {
    #partial switch sc {
    case .TAB:        return .Tab
    case .LEFT:       return .LeftArrow
    case .RIGHT:      return .RightArrow
    case .UP:         return .UpArrow
    case .DOWN:       return .DownArrow
    case .PAGEUP:     return .PageUp
    case .PAGEDOWN:   return .PageDown
    case .HOME:       return .Home
    case .END:        return .End
    case .INSERT:     return .Insert
    case .DELETE:     return .Delete
    case .BACKSPACE:  return .Backspace
    case .SPACE:      return .Space
    case .RETURN:     return .Enter
    case .ESCAPE:     return .Escape
    case .LCTRL:      return .LeftCtrl
    case .LSHIFT:     return .LeftShift
    case .LALT:       return .LeftAlt
    case .RCTRL:      return .RightCtrl
    case .RSHIFT:     return .RightShift
    case .RALT:       return .RightAlt
    case .A:          return .A
    case .C:          return .C
    case .V:          return .V
    case .X:          return .X
    case .Y:          return .Y
    case .Z:          return .Z
    }
    return .None
}
