package inso

import "core:sort"
VERSION :: #config(VERSION, "dev (unversioned)")

import "base:runtime"
import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "bass"
import imgui "imgui"
import imgui_gl3 "imgui/imgui_impl_opengl3"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"


Memory_Arena_Type :: enum {
    // note(isak): never cleared. used instead of odin's regular arena to keep track of our allocations
    GLOBAL,
    
    // note(isak): this is to be used for mapset runtime data, such as timing state, judgements, etc.
    // cleared on mapset reload/unload
    MAPSET,

    // note(isak): everything derived from the .osu file (hitobjects, slider paths, timing points).
    // mods and stacking mutate this in place, so mod toggles/retries re-parse into a fresh arena
    // while assets in MAPSET stay resident. cleared on map data regen and mapset reload/unload
    MAP_DATA,


    // note(isak): this is to be used for graphical entity data, "unbounded" since it's written to by
    // game logic and scripts. cleared on mapset reload/unload
    DRAWABLES,
    
    // note(isak): judgements (unbounded). cleared on mapset reload/unload
    JUDGEMENTS,
    
    // note(isak): skin data (names, paths). cleared on skin unload
    SKIN,

    // note(isak): active sound channels (Sound_Channel slotmap). freed and reinited on game_sounds_clear
    SOUND,

    // note(isak): per-hitobject custom drawables assigned by lua scripts. cleared on mapset reload and lua hot-reload
    SCRIPT_ELEMENTS,

    // note(isak): temporary allocator. cleared on frame end
    FRAME,
}

memory_arena_names := [?]string {
    "Global",
    "Mapset",
    "Map data",
    "Drawables",
    "Judgements",
    "Skin",
    "Sound",
    "Script elements",
    "Frame",
    "Command buffer[BACKGROUND]",
    "Command buffer[FOREGROUND]",
    "Command buffer[HITOBJECTS]",
    "Command buffer[OVERLAY]",
    "Command buffer[UI]",
    "Command buffer[CURSOR]",
    "Command buffer[TOP]",
    "Command buffer[PLATFORM]",
}

memory: struct {
    allocators: [Memory_Arena_Type]runtime.Allocator,
    arenas: [Memory_Arena_Type]vmem.Arena,
    
    backing_alloc: [Memory_Arena_Type]runtime.Allocator,
    tracker: [Memory_Arena_Type]Guarding_Allocator,
    
    command_buffer_allocators: [LAYER_SLOTS]runtime.Allocator,
    command_buffer_arenas: [LAYER_SLOTS]vmem.Arena,
}

// note(isak): this should take care of error printing
memory_init :: proc() -> runtime.Allocator_Error {
    arenas := &memory.arenas
    allocators := &memory.allocators
    
    for t in Memory_Arena_Type {
        init_tracked_growing_arena(&arenas[t], &allocators[t], &memory.backing_alloc[t], &memory.tracker[t]) or_return
    } 
    for slot in 0 ..< LAYER_SLOTS {
        init_growing_arena(&memory.command_buffer_arenas[slot], &memory.command_buffer_allocators[slot]) or_return
    }
    return .None
}


main :: proc() {
    _program_start_tsc = sdl.GetPerformanceCounter()

    for i := 0; i < len(os.args); i += 1 {
        arg := os.args[i]
        if arg == "--disable-raw-input" {
            app.disable_raw_input = true
        }
        if arg == "--gen-lua-docs" {
            lua_generate_docs()
            return
        }
        if arg == "--tournament" {
            game.tournament_client = true
            if i + 1 < len(os.args) && !strings.has_prefix(os.args[i + 1], "--") {
                game.startup_map_path = os.args[i + 1]
                i += 1
            }
        }
    }

    // note(isak): crash handler reruns the process, but doesn't forward the arguments we first launched with
    when #config(WITH_CRASH_HANDLER, false) {
        if !crash_handler_is_game_process() && !game.tournament_client {
            crash_handler_run()
            return
        }
    }

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

    game.user_config = config_load("user.ini")
    defer config_save("user.ini")

    window_init({w = game.user_config.window_width, h = game.user_config.window_height}, mode = game.user_config.window_mode)
    app.ui_enabled = true
    defer window_cleanup()
    
    audio_init()
    if !audio.ready {
        log.panic("BASS audio init error:", bass.ErrorGetCode())
    }
    defer audio_cleanup()

    renderer_init()
    renderer := &window.renderer
    defer renderer_cleanup()

    window_on_resize(i32(window.rect.w), i32(window.rect.h))

    imgui_init()
    defer imgui_cleanup()
    
    text_init()
    keyboard_init()
    mouse_init()
    
    config_apply()

    if !input_validate_mouse_hwid(.PRIMARY, game.user_config.primary_mouse_hwid) {
        game.user_config.primary_mouse_hwid = {}
    }
    if !input_validate_mouse_hwid(.SECONDARY, game.user_config.secondary_mouse_hwid) {
        game.user_config.secondary_mouse_hwid = {}
    }

    shaders_watch, skins_watch: Directory_Watch
    directory_watch_init(&shaders_watch, "shaders/")
    directory_watch_init(&skins_watch, "skins/")
    defer directory_watch_close(&skins_watch)

    // todo(isak): consider creating a song index (with allocator)
    discover_maps("songs/")
    discover_skins("skins/")

    // note(isak): the configured skin may live outside skins/ (e.g. an osu! skin folder), so
    // register it as an external reference to keep it in the dropdown
    if _, found := skin_reference_find(game.user_config.skin_path); !found && os.exists(game.user_config.skin_path) {
        skin_reference_add_external(game.user_config.skin_path)
    }
    
    inso_load_time := time_s_since_beginning_of_program()
    notify_info("inso loaded in %.3vs", inso_load_time)
    
    osu_on_init()
    
    notify_info("Press F8 to view previous notifications")

    time_current_frame_tsc := current_time_tsc()
    time_current_frame := tsc_to_s(time_current_frame_tsc)
    time_first_frame := time_current_frame
    time_last_frame := time_current_frame
    fps_limiter_target_s := time_current_frame
    frame_count: u64

    running := true
    event: sdl.Event
    
    for running {
        profiler_begin_frame()
        defer profiler_end_frame()

        {
            profiler_block_begin(.MESSAGE_HANDLING); defer profiler_block_end()

            // message handling, time handling
            for &mouse in mice {
                mouse.scroll_delta = 0
                for &button in mouse.buttons {
                    button.was_down = button.is_down
                }
            }
            
            // note(isak): raw mouse/keyboard arrives timestamped from the input thread (see
            // platform_input_thread_windows.odin) and is applied in the drain below. sdl events
            // remain the source for ui, text input and window state

            for sdl.PollEvent(&event) {
                #partial switch event.type {
                case sdl.EventType.MOUSE_BUTTON_DOWN:
                    io := imgui.GetIO()
                    switch event.button.button {
                        case sdl.BUTTON_LEFT:
                            if mouse_accepts_sdl_buttons() {
                                mouse.buttons[.LEFT].is_down = true
                            }
                            mouse.last_click_position[.LEFT] = {event.button.x, event.button.y}
                            imgui.IO_AddMouseButtonEvent(io, 0, true)
                        case sdl.BUTTON_MIDDLE:
                            if mouse_accepts_sdl_buttons() {
                                mouse.buttons[.MIDDLE].is_down = true
                            }
                            mouse.last_click_position[.MIDDLE] = {event.button.x, event.button.y}
                            imgui.IO_AddMouseButtonEvent(io, 2, true)
                        case sdl.BUTTON_RIGHT:
                            if mouse_accepts_sdl_buttons() {
                                mouse.buttons[.RIGHT].is_down = true
                            }
                            mouse.last_click_position[.RIGHT] = {event.button.x, event.button.y}
                            imgui.IO_AddMouseButtonEvent(io, 1, true)
                    }

                case sdl.EventType.MOUSE_BUTTON_UP:
                    io := imgui.GetIO()
                    switch event.button.button {
                        case sdl.BUTTON_LEFT:
                            if mouse_accepts_sdl_buttons() {
                                mouse.buttons[.LEFT].is_down = false
                            }
                            imgui.IO_AddMouseButtonEvent(io, 0, false)
                        case sdl.BUTTON_MIDDLE:
                            if mouse_accepts_sdl_buttons() {
                                mouse.buttons[.MIDDLE].is_down = false
                            }
                            imgui.IO_AddMouseButtonEvent(io, 2, false)
                        case sdl.BUTTON_RIGHT:
                            if mouse_accepts_sdl_buttons() {
                                mouse.buttons[.RIGHT].is_down = false
                            }
                            imgui.IO_AddMouseButtonEvent(io, 1, false)
                    }

                case sdl.EventType.MOUSE_WHEEL:
                    mouse.scroll_delta += event.wheel.y
                    imgui.IO_AddMouseWheelEvent(imgui.GetIO(), event.wheel.x, event.wheel.y)

                case sdl.EventType.KEY_DOWN:
                    imgui.IO_AddKeyEvent(imgui.GetIO(), sdl_scancode_to_imgui(event.key.scancode), true)
                    if event.key.scancode == .RETURN && (event.key.mod & sdl.KMOD_ALT) != {} {
                        window_cycle_mode(window.mode)
                        game.input.captured_scancode = .RETURN
                    }
                    
                    if game.input.rebinding_key != .NONE {
                        defer game.input.rebinding_key = .NONE

                        game.input.keys[game.input.rebinding_key] = event.key.scancode
                        game.user_config.keys[game.input.rebinding_key] = event.key.scancode
                        game.input.captured_scancode = event.key.scancode
                    }
                    
                case sdl.EventType.KEY_UP:
                    imgui.IO_AddKeyEvent(imgui.GetIO(), sdl_scancode_to_imgui(event.key.scancode), false)
                case sdl.EventType.TEXT_INPUT:
                    imgui.IO_AddInputCharactersUTF8(imgui.GetIO(), event.text.text)

                case sdl.EventType.WINDOW_RESIZED:
                    cleanup_textures_for_rendering()
                    window_on_resize(max(event.window.data1, 1), max(event.window.data2, 1))
                    prepare_textures_for_rendering()

                case sdl.EventType.WINDOW_PIXEL_SIZE_CHANGED:
                    window.pixel_density = sdl.GetWindowPixelDensity(window.handle)

                case sdl.EventType.WINDOW_FOCUS_GAINED:
                    window.focused = true
                    imgui.IO_AddFocusEvent(imgui.GetIO(), true)
                case sdl.EventType.WINDOW_FOCUS_LOST:
                    window.focused = false
                    imgui.IO_AddFocusEvent(imgui.GetIO(), false)

                case sdl.EventType.WINDOW_MOUSE_ENTER:
                    window.mouse_inside = true
                case sdl.EventType.WINDOW_MOUSE_LEAVE:
                    window.mouse_inside = false

                case sdl.EventType.WINDOW_MINIMIZED:
                    window.minimized = true
                case sdl.EventType.WINDOW_RESTORED:
                    window.minimized = false

                case sdl.EventType.QUIT:
                    running = false
                }
            }

            // the frame-start snapshot lets the hittesting event walk re-integrate cursor motion
            // to the position each press actually happened at
            game.input.frame_start_mouse_screen = mouse.pos
            game.input.frame_events = input_thread_drain()
            input_thread_apply_events(game.input.frame_events)

            keyboard_next_frame()

            // note(isak): disable keybind from rebind
            if game.input.captured_scancode != .UNKNOWN {
                keyboard.buttons_prev_frame[game.input.captured_scancode] = true
                game.input.captured_scancode = .UNKNOWN
            }

            mouse_sync_cursor_with_os()

            imgui.IO_AddMousePosEvent(imgui.GetIO(), mouse.pos.x, mouse.pos.y)
            app.ui_wants_mouse = imgui.GetIO().WantCaptureMouse
        }

        {
            profiler_block_begin(.PREPARE_FRAME); defer profiler_block_end()

            time_last_frame = time_current_frame
            time_current_frame_tsc = current_time_tsc()
            time_current_frame = tsc_to_s(time_current_frame_tsc)

            max_frame_time_s :: 1.0
            if time_current_frame - time_last_frame > max_frame_time_s {
                // todo(isak): lagspike integrity check goes here
            }

            io := imgui.GetIO()
            io.DisplaySize = {window.rect.w, window.rect.h}
            io.DeltaTime = f32(time_current_frame - time_last_frame)

            if game.mode != .EDITOR {
                imgui.GetIO().WantCaptureMouse = false
            }
            app.ui_enabled = game.mode == .EDITOR
            if window.resized && game.mode == .EDITOR {
                beatmap_open(game.beatmap.map_reference, true)
            }
            window.resized = false
            
            // prepare drawing
            begin_frame(renderer)
        }

        {
            profiler_block_begin(.GAME_UPDATE); defer profiler_block_end()
            
            handle_debug_ui_events()
            file_dialog_poll()
            if audio_handle_device_change() {
                // note(isak): session volume is remembered per-device by windows, so re-apply ours
                audio_set_volume(game.user_config.master_volume)
            }
            if key_is_down(.LCTRL) && key_is_pressed(.F5) {
                discover_maps("songs/")
                discover_skins("skins/")
            }
            
            dt_ms := window_snap_frame_delta_ms((time_current_frame - time_last_frame) * 1000)

            r_bind_layer_and_push_current_state(.BACKGROUND, transform = window.screenspace_transform)
            osu_on_update(dt_ms, i64(time_current_frame_tsc))
        }
        
        {
            profiler_block_begin(.GAME_DRAW); defer profiler_block_end()
            
            r_bind_layer_and_push_current_state(.PLATFORM, transform = window.screenspace_transform)

            debug_visuals_draw(renderer, frame_count)
            notify_draw_notifications(renderer)

            end_frame(renderer)

            if app.ui_enabled {
                imgui.Render()
                imgui_gl3.RenderDrawData(imgui.GetDrawData())
            }
        }

        {
            profiler_block_begin(.SWAP_FRAME); defer profiler_block_end()
            sdl.GL_SwapWindow(window.handle)

            if frame_count == 0 do window_refresh_transparency_composition()
        }
        
        {
            profiler_block_begin(.SLEEP); defer profiler_block_end()
            if !window.focused && game.paused {
                sdl.Delay(30) // note(isak): ~30fps cap
            } else if game.user_config.fps_limiter > 0 {
                now_s := tsc_to_s(current_time_tsc())
                fps_limiter_target_s = max(fps_limiter_target_s + 1.0 / f64(game.user_config.fps_limiter), now_s)
                remaining_s := fps_limiter_target_s - now_s
                if remaining_s > 0 do sdl.DelayPrecise(u64(remaining_s * 1e9))
            }
        }
        
        {
            profiler_block_begin(.BETWEEN_FRAMES); defer profiler_block_end() 

            process_builtin_shader_changes(&shaders_watch)
            process_skins_watch(&skins_watch)

            if app.debug_display_frame_graph || app.debug_display_frame_profiler {
                profiler_write_texture_column(frame_count, window.profiler_texture)
            }
            
            crash_stats_write(frame_count, (time_current_frame - time_last_frame) * 1000)
            
            frame_count += 1

            free_all(memory.allocators[.FRAME])
            for slot in 0 ..< LAYER_SLOTS {
                queue.clear(&window.renderer.layer_command_queues[slot])
            }
        }
    }
}

begin_frame :: proc(renderer: ^Renderer) {
    profiler_gpu_new_frame()

    sg.begin_pass({ action = window.pass_action, swapchain = window.swapchain })

    batch_begin(renderer)

    slider_border := color_white
    if game.active_skin != nil && game.active_skin.slider_border.a != 0 {
        slider_border = game.active_skin.slider_border
    }

    r_set_shader_globals({
        transform = identity_transform,
        playfield_transform = game.playfield_transform,
        time = f32(beatmap_music_time_ms(&game.beatmap)),
        circle_size_osupx = game.beatmap.circle_radius_osupx,
        cursor_pos = mouse.pos,
        resolution = vec2{window.rect.w, window.rect.h},
        slider_border_color = color_to_vec(with_alpha(slider_border, 1.0)),
    })

    r_bind_layer(.BACKGROUND)
    r_bind_pipeline({ pipeline = builtin_pipeline_slot(.QUAD) })

    // note(isak): clear map-dependent extra targets
    if game.active_mapset != nil {
        for &rt, i in game.active_mapset.render_targets.data {
            if rt.clear_every_frame {
                r_bind_framebuffer({ write = user_framebuffer(u32(i)) })
                r_clear(with_alpha(color_black, 0.0))
            }
        }
        if game.active_mapset.inso_map.use_backbuffer {
            r_bind_framebuffer({ write = builtin_framebuffer(.BACKBUFFER) })
            r_clear(with_alpha(color_black, 0.0))
        }
    }

    main_framebuffer := builtin_framebuffer(.BACKBUFFER) if render_to_backbuffer_active() else builtin_framebuffer(.DEFAULT)
    r_bind_framebuffer({read = main_framebuffer, write = main_framebuffer})
    r_push_transform(identity_transform)
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_reset_scissor_mode()

    for &layer_state in window.renderer.layer_state {
        layer_state.scissor = Command_Scissor_Mode{0, 0, i32(window.rect.w), i32(window.rect.h)}
    }

    if app.ui_enabled {
        imgui_gl3.NewFrame()
        imgui.NewFrame()
        imgui_update()
    }
}

end_frame :: proc(renderer: ^Renderer) {
    text_submit_geometry(renderer)

    window_wants_opaque := !window.transparent || game.tournament_waiting_to_start
    if window_wants_opaque && !window_is_exclusive_fullscreen() {
        // note(isak): windows window with transparency captures the alpha of the last drawn pixels and uses that for
        // the window's opacity value. when we don't want transparency, clear alpha of every pixel to 1.0.
        r_check_and_bind_layer(max(Layer))
        r_bind_pipeline({ pipeline = builtin_pipeline_slot(.QUAD) })
        r_push_transform(window.screenspace_transform)
        r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
        r_bind_framebuffer({0, 0})
        r_color_mask(false, false, false, true)
        r_draw_layout_rect(&window.renderer.quad_geometry, {0, 0, window.rect.w, window.rect.h }, .TOP_LEFT, color_black)
        r_color_mask(true, true, true, true)
    }

    if game.active_mapset != nil {
        for &pass in game.active_mapset.post_passes {
            r_post_pass(Command_Post_Pass{
                pipeline   = pass.pipeline,
                dst        = pass.dst,
                quad_index = pass.quad_index,
                src        = pass.src,
                src_count  = pass.src_count,
            }, pass.after)
        }
    }

    profiler_collect_command_buffer_memory_data()
    batch_end(renderer)

    sg.end_pass()
    sg.commit()
}


open_external_map :: proc(external_map_path: string) -> (success: bool) {
    idx := strings.last_index_any(external_map_path, "/\\")
    hash := hash.fnv64a(transmute([]u8)external_map_path)
    
    for ref in app.map_references {
        if ref.hash == hash {
            return false
        }
    }

    append(&app.map_references, Map_Reference {
        folder_path = external_map_path[:idx + 1],
        osu_filename = filepath.base(external_map_path),
        hash = hash,
        external = true,
    })
    ref := app.map_references[len(app.map_references) - 1]
    ref_display_cstr  := fmt.caprintf("%s", ref.osu_filename)
    append(&app.map_reference_names, ref_display_cstr)
    
    beatmap_open(ref)

    app.external_map_open = true
    return true
}

open_external_skin :: proc(external_skin_path: string) -> (success: bool) {
    folder_path := external_skin_path
    if !strings.has_suffix(folder_path, "/") && !strings.has_suffix(folder_path, "\\") {
        folder_path = strings.concatenate({folder_path, "/"}, memory.allocators[.GLOBAL])
    }

    if _, found := skin_reference_find(folder_path); !found {
        skin_reference_add_external(folder_path)
    }
    skin_rebind(folder_path)
    game.user_config.skin_path = folder_path
    return true
}

imgui_update :: proc() {
    imgui.Begin("Editor options")
    defer imgui.End()
    
    imgui_dropdown_draw(&app.map_dropdown)
    if imgui.SmallButton("open external") {
        file_dialog_open_osu()
    }
    imgui.Separator()

    if imgui.SmallButton("play") {
        game_switch_mode(.PLAY, beatmap_music_time_ms(&game.beatmap))
    }
    if imgui.SmallButton("play from beginning") {
        game_switch_mode(.PLAY, game.beatmap.start_time_ms)
    }
    if imgui.SmallButton("play from first object") {
        seek_time := game.beatmap.start_time_ms
        if len(game.beatmap.hitobjects) > 0 {
            seek_time = game.beatmap.hitobjects[0].start_time_ms - beatmap_lead_in_ms(&game.beatmap)
        }
        game_switch_mode(.PLAY, seek_time)
    }
    
    imgui.Separator()
    
    imgui_dropdown_draw(&app.skin_dropdown)
    if imgui.SmallButton("open external##skin") {
        file_dialog_open_skin_folder()
    }

    if imgui.Button("x##cursor_reset") do game.user_config.cursor_size_multiplier = 1.0
    imgui.SameLine()
    imgui.SliderFloat("Cursor size##mouse", &game.user_config.cursor_size_multiplier, 0.1, 2.0)

    imgui.Separator()

    timer_str := strings.clone_to_cstring(time_ms_to_string(beatmap_music_time_ms(&game.beatmap)), context.temp_allocator)
    
    imgui.Text("FPS: %f", imgui.GetIO().Framerate)
    imgui.Text("Time: %s", timer_str)
    imgui.Text("Time rate: %.3f%s", game.time_rate,
        game.paused ? cstring(" (paused)") : cstring(""))

    hobj_visibility := game.beatmap.visible_hitobject_state
    imgui.Text("Visible hitobjects: %d", i32(hobj_visibility.latest_i - hobj_visibility.earliest_i - 1))
    imgui.Text("Mouse keys: %s", game.input.mouse_keys_enabled ? cstring("on") : cstring("off"))
    if imgui.Button("Offset") do app.offset_window_open = true
    imgui.SameLine()
    imgui.Text("%d ms", i32(game.user_config.universal_offset_ms))

    //imgui.Text("Music pos: %f ms", f32(game.beatmap.music_time_ms))
    //imgui.Text("Sound pos: %f ms", f32(sound_get_position_ms(&game.beatmap.music)))
    
    imgui.Separator()
    if imgui.CollapsingHeader("Game") {
        imgui.SliderFloat("Playfield border opacity##vol", &game.user_config.playfield_border_opacity, 0, 1)

        if imgui.SliderFloat("Background dim##bgdim", &game.user_config.bg_dim, 0, 1) {
            bg_dim_apply(game.user_config.bg_dim)
        }

        if imgui.Checkbox("Use beatmap skin", &game.user_config.use_beatmap_skin) {
            beatmap_open(game.beatmap.map_reference, keep_position = true, reload_assets = false)
        }

        imgui.Checkbox("Use beatmap hitsounds", &game.user_config.use_beatmap_hitsounds)
        if imgui.Checkbox("Use beatmap combo color skips", &game.user_config.use_beatmap_combo_color_skips) {
            beatmap_open(game.beatmap.map_reference, keep_position = true, reload_assets = false)
        }

        imgui.Checkbox("Snaking in sliders", &game.user_config.snaking_in_sliders_enabled)
        imgui.Checkbox("Snaking out sliders", &game.user_config.snaking_out_sliders_enabled)
        
        if imgui.BeginTable("mods", 2, imgui.TableFlags_RowBg | imgui.TableFlags_SizingFixedFit) {
            for mod in Osu_Mod {
                enabled := mod in game.mods

                imgui.TableNextRow()
                imgui.TableSetColumnIndex(0)
                if imgui.Selectable(osu_mod_table[mod].name, enabled, {.SpanAllColumns}) {
                    game.mods ~= {mod}

                    if (mod == .DOUBLE_TIME || mod == .HALF_TIME) && enabled {
                        game.time_rate = 1.0
                    }
                    beatmap_open(game.beatmap.map_reference, true)
                }
                imgui.TableSetColumnIndex(1)
                if enabled {
                    imgui.TextColored({0.4, 1.0, 0.55, 1.0}, "on")
                } else {
                    imgui.TextDisabled("off")
                }
            }
            imgui.EndTable()
        }
        
        if .DIFFICULTY_ADJUST in game.mods {
            DIFFICULTY_ADJUST_RELOAD_DELAY_S :: 0.25
            @static reload_deadline_s: f64

            difficulty_adjust_touch :: proc() {
                reload_deadline_s = time_s_since_beginning_of_program() + DIFFICULTY_ADJUST_RELOAD_DELAY_S
            }
            difficulty_adjust_reload_when_settled :: proc(reload_deadline_s: f64) -> (reloaded: bool) {
                if reload_deadline_s != 0 && time_s_since_beginning_of_program() >= reload_deadline_s {
                    beatmap_open(game.beatmap.map_reference, true)
                    return true
                }
                return false
            }

            temp_settings := difficulty_adjust_settings
            for &setting, i in difficulty_adjust_settings {
                if imgui.Button(fmt.ctprint("x##", difficulty_setting_names[i])) {
                    setting = map_difficulty_defaults[i]
                    difficulty_adjust_touch()
                }
                imgui.SameLine()
                setting_slider: f32 = f32(setting)
                if imgui.SliderFloat(fmt.ctprint(difficulty_setting_names[i]), &setting_slider, -10, 10) {
                    setting = f64(setting_slider)
                    difficulty_adjust_touch()
                }
                // a held slider postpones a pending reload even while the value sits still
                if reload_deadline_s != 0 && imgui.IsItemActive() {
                    difficulty_adjust_touch()
                }
            }
            
            if difficulty_adjust_reload_when_settled(reload_deadline_s) {
                reload_deadline_s = 0
            }
        }
    }
    if imgui.CollapsingHeader("Display") {
        if imgui.BeginCombo("Window mode", window_mode_display_names[window.mode]) {
            for mode in Window_Mode {
                is_selected := mode == window.mode
                if imgui.Selectable(window_mode_display_names[mode], is_selected) && !is_selected {
                    window_set_mode(mode)
                }
                if is_selected do imgui.SetItemDefaultFocus()
            }
            imgui.EndCombo()
        }
        if imgui.Checkbox("VSync", &game.user_config.vsync_enabled) {
            window_apply_vsync(game.user_config.vsync_enabled)
        }
        
        @static fps_limiter_field: i32
        imgui.InputInt("FPS limiter (0 = off)", &fps_limiter_field, 0, 0, {.CharsDecimal})
        if imgui.IsItemDeactivatedAfterEdit() {
            game.user_config.fps_limiter = max(fps_limiter_field, 0)
        }
        if !imgui.IsItemActive() {
            fps_limiter_field = game.user_config.fps_limiter
        }
        
        if imgui.SliderFloat("UI scale", &game.user_config.ui_scale, 0.5, 2.0) {
            ui_scale_recompute()
        }
    }
    if imgui.CollapsingHeader("Audio") {
        if imgui.SliderFloat("Master##vol", &game.user_config.master_volume, 0, 1) {
            audio_set_volume(game.user_config.master_volume)
        }
        if imgui.SliderFloat("Music##vol", &game.user_config.music_volume, 0, 1) {
            audio_apply_config_volumes()
        }
        if game.user_config.hitsound_volume_follows_music {
            imgui.BeginDisabled()
            shown := game.user_config.music_volume
            imgui.SliderFloat("Hitsounds##vol", &shown, 0, 1)
            imgui.EndDisabled()
        } else if imgui.SliderFloat("Hitsounds##vol", &game.user_config.hitsound_volume, 0, 1) {
            audio_set_category_volume(.HITSOUND, game.user_config.hitsound_volume)
        }
    }
    if imgui.CollapsingHeader("Input") {
        if !app.disable_raw_input {
            raw_input := app.mouse_input_source == .RAW
            if imgui.Checkbox("Raw input", &raw_input) {
                if raw_input {
                    mouse_enable_raw_input_mode()
                } else {
                    mouse_disable_raw_input_mode()
                }
                game.user_config.raw_input_enabled = raw_input
            }
        } else {
            imgui.Text("Raw input disabled")
        }
                
        raw_active := is_raw_input_enabled()
        imgui.BeginDisabled(!raw_active)
        if imgui.Button("x##sensitivity_reset") do game.user_config.cursor_sensitivity = 1.0
        imgui.SameLine()
        imgui.SliderFloat("Cursor sensitivity##mouse", &game.user_config.cursor_sensitivity, 0.1, 5.0)
        imgui.EndDisabled()
        if !raw_active {
            imgui.TextDisabled("(cursor sensitivity requires raw input)")
        }
        
        imgui.Text("\nKey bindings (click to rebind)")
        if imgui.BeginTable("keybinds", 2, imgui.TableFlags_RowBg | imgui.TableFlags_SizingFixedFit) {
            for key in Rebindable_Input_Key {
                if key == .NONE do continue

                imgui.TableNextRow()
                imgui.TableSetColumnIndex(0)
                is_rebinding := game.input.rebinding_key == key
                row_label := fmt.ctprintf("%s##%s", rebindable_input_key_names[key], fmt.enum_value_to_string(key))
                if imgui.Selectable(row_label, is_rebinding, {.SpanAllColumns}) {
                    game.input.rebinding_key = key
                }
                imgui.TableSetColumnIndex(1)
                imgui.Text(fmt.ctprintf("%s", rebindable_input_key_code(key)))
            }
            imgui.EndTable()
        }
        
        /*
        imgui.Text("Rebind mice")
        if imgui.Button("primary") {
            app.mouse_rebind_target = .PRIMARY
        }
        imgui.SameLine()
        if imgui.Button("secondary") {
            app.mouse_rebind_target = .SECONDARY
        }
        */
    }
    if imgui.CollapsingHeader("Debug") {
        imgui.Checkbox("Log Lua GC", &app.debug_log_lua_gc)
    }

    write_offset_window()
}

write_offset_window :: proc() {
    if !app.offset_window_open do return

    imgui.SetNextWindowSize({220, 70}, .FirstUseEver)
    if imgui.Begin("Universal Offset", &app.offset_window_open) {
        offset := c.int(game.user_config.universal_offset_ms)
        imgui.SetNextItemWidth(-1)
        if imgui.InputInt("##offset", &offset, 1, 5) {
            game.user_config.universal_offset_ms = int(offset)
        }
    }
    imgui.End()
}

handle_debug_ui_events :: proc() {
    map_dropdown := &app.map_dropdown
    if map_dropdown.changed && map_dropdown.selected < len(app.map_references) {
        map_ref := app.map_references[map_dropdown.selected]
        beatmap_open(map_ref)
    }
    
    skin_dropdown := &app.skin_dropdown
    if skin_dropdown.changed && skin_dropdown.selected < len(app.skin_references) {
        skin_ref := app.skin_references[skin_dropdown.selected]
        skin_rebind(skin_ref.folder_path)
        game.user_config.skin_path = skin_ref.folder_path
    }
    
    if key_is_pressed(.F1) {
        window.renderer.trace_frame = !window.renderer.trace_frame
    }
    if key_is_pressed(.F2) {
        app.debug_display_frame_graph = !app.debug_display_frame_graph
        //app.debug_display_slider_bounds = !app.debug_display_slider_bounds
        //app.debug_display_playfield_cursor = app.debug_display_slider_bounds
    }
    if key_is_pressed(.F3) {
        app.debug_display_frame_profiler = !app.debug_display_frame_profiler
    }
    if key_is_pressed(.F4) {
        app.debug_display_memory_profiler = !app.debug_display_memory_profiler
        
        for arena in Memory_Arena_Type {
            track := memory.tracker[arena]
            
            fmt.println(fmt.enum_value_to_string(arena), " :: ",
                "cur ", track.alloc.current_memory_allocated, 
                ", peak ", track.alloc.peak_memory_allocated)
        }

        track := &memory.tracker[.GLOBAL]
        if len(track.alloc.allocation_map) > 0 {
            fmt.printf("=== global allocator - %v allocations not freed: ===\n", len(track.alloc.allocation_map))

            allocs := make([]mem.Tracking_Allocator_Entry, len(track.alloc.allocation_map), memory.allocators[.FRAME])
            i := 0
            for _, entry in track.alloc.allocation_map {
                allocs[i] = entry
                i += 1
            }
            sort.quick_sort_proc(allocs, proc(a, b: mem.Tracking_Allocator_Entry) -> int {
                return int(hash.fnv64a(transmute([]u8)a.location.file_path) - hash.fnv64a(transmute([]u8)b.location.file_path))
            })
            for entry in allocs {
                fmt.printf("- %v :: %v bytes\n", entry.location, entry.size)
            }
        }
    }
    if key_is_pressed(.F6) {
        app.debug_display_textures = !app.debug_display_textures
    }
    if key_is_pressed(.F8) {
        notify.show_all = !notify.show_all
    }

    // note(isak): cursor visibility - show OS cursor when imgui wants the mouse
    want_mouse := imgui.GetIO().WantCaptureMouse
    if window.cursor_hidden && want_mouse {
        window.cursor_hidden = !sdl.ShowCursor()
    } else if !window.cursor_hidden && !want_mouse {
        window.cursor_hidden = sdl.HideCursor()
    }
}

debug_visuals_draw :: proc(renderer: ^Renderer, frame_count: u64) {
    if app.debug_display_fontatlas {
        r_draw_rect(&renderer.quad_geometry,
            {0, 0, f32(text_engine.ctx.width), f32(text_engine.ctx.height)},
            color_white,
            builtin_texture(.FONT_ATLAS))
    }

    if app.debug_display_frame_profiler {
        profiler_push_blocks_as_text(renderer, frame_count)
        profiler_push_gpu_blocks_as_text(renderer)
    }
    if app.debug_display_frame_graph || app.debug_display_frame_profiler {
        profiler_push_quad(&renderer.quad_geometry, frame_count)
    }
    if app.debug_display_memory_profiler {
        profiler_push_memory_diag_text(renderer)
    }
    
    if app.debug_display_textures {
        /*for i in 0..<50 {
            r_draw_quad(&renderer.quad_geometry, 
                vec2{400 + 40*(f32(i%10)), 10 + 40*f32(i/10)},
                vec2{440 + 40*(f32(i%10)), 50 + 40*f32(i/10)},
                vec2{0,0}, vec2{1,1},
                color_white, 
                tex_index = u32(i)
            )
        }*/

        r_push_transform(window.screenspace_transform)
        r_draw_quad(&renderer.quad_geometry, 
            vec2{0, 0},
            vec2{f32(window.rect.w), f32(window.rect.h)},
            vec2{0,0}, vec2{1,1},
            color_black
        )
        r_draw_quad(&renderer.quad_geometry, 
            vec2{0, 0},
            vec2{f32(window.rect.w), f32(window.rect.h)},
            vec2{0,0}, vec2{1,1},
            color_white, 
            tex_index = builtin_texture(.SLIDER_FRAMEBUFFER)
        )
        push_text(renderer, "Slider texture buffer (press F6 to hide)",
            pos     = {window.rect.w / 2, 50},
            size    = 18,
            color   = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Bottom)
    }
    
    if app.debug_display_playfield_cursor {
        r_push_transform(game.playfield_transform)
        pf_cur_rect: Rect = { game.input.mouse_pos.x, game.input.mouse_pos.y, 20, 20 }
        r_draw_layout_rect(&renderer.quad_geometry, pf_cur_rect, .CENTER, color_red, builtin_texture(.WHITE),
            f32(time_s_since_beginning_of_program()))
    }
}

process_builtin_shader_changes :: proc(watch: ^Directory_Watch) {
    updated_systems := mapset_check_system_file_watch(watch)
    if updated_systems[.SHADERS] {
        for &shader in window.shaders.data[:len(Builtin_Shader_Slot)] {
            shader_reinit(&shader)
        }
        // note(isak): mapset custom shaders may share a builtin VS, so reinit them too
        mapset_reinit_custom_shaders(game.active_mapset)

        notify_info("reloaded mapset shaders")

        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.QUAD)], quad_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.QUAD_PREMULTIPLIED)], quad_pipeline_desc(.PREMULTIPLIED))
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.QUAD_PREMULTIPLIED_OVER)], quad_pipeline_desc(.PREMULTIPLIED_OVER))
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.SLIDER)], slider_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.SLIDER_PRESENT)], slider_present_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.SLIDER_PRESENT_PREMULTIPLIED)], slider_present_pipeline_desc(.PREMULTIPLIED))
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.TEXT)], text_pipeline_desc())
        pipeline_reinit(&window.pipelines.data[builtin_pipeline_slot(.TEXT_PREMULTIPLIED)], text_pipeline_desc(.PREMULTIPLIED))
    }
}

process_skins_watch :: proc(watch: ^Directory_Watch) {
    directory_watch_poll(watch)
    changed := false
    for _, ok := directory_watch_next_file(watch); ok; _, ok = directory_watch_next_file(watch) {
        changed = true
    }
    if changed {
        discover_skins("skins/")
    }
}
