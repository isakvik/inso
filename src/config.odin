package inso

import "core:encoding/ini"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"


// note(isak): user config is saved to a .ini file, just like osu
User_Configuration :: struct {
    universal_offset_ms: int,
    
    master_volume: f32,
    music_volume: f32,
    hitsound_volume: f32,
    hitsound_volume_follows_music: bool,
    
    vsync_enabled: bool,
    fps_limiter: i32, // 0 = uncapped

    gpu_profiler_enabled: bool,

    // note(isak): config_importer resolve path
    osu_install_path: string,

    skin_path: string,
    use_beatmap_skin: bool,
    use_beatmap_hitsounds: bool,

    use_beatmap_combo_color_skips: bool,

    window_width: f32,
    window_height: f32,
    window_mode: Window_Mode,
    
    primary_mouse_hwid: string,
    secondary_mouse_hwid: string,
    cursor_size_multiplier: f32,
    cursor_sensitivity: f32,
    raw_input_enabled: bool,
    mouse_keys_enabled: bool,
    
    bg_dim: f32, // note(isak): 0 = background fully visible, 1 = fully black
    playfield_border_opacity: f32,
    ui_scale: f32,
    accuracy_display_size: f32,
    snaking_in_sliders_enabled: bool,
    snaking_out_sliders_enabled: bool,
    
    keys: [Rebindable_Input_Key]sdl.Scancode,
}

config_load :: proc(path: string) -> (result: User_Configuration) {
    result = config_supply_default()

    m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
    if !ok do return

    get :: proc(pairs: map[string]string, key: string) -> (string, bool) {
        v, ok := pairs[key]
        return strings.trim_space(v), ok && len(v) > 0
    }

    // note(isak): our config top level is sectionless
    if gen, ok := m[""]; ok {
        if v, ok := get(gen, "universal_offset_ms"); ok {
            result.universal_offset_ms, ok = strconv.parse_int(v)
        }
        if v, ok := get(gen, "master_volume"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.master_volume = f
        }
        if v, ok := get(gen, "music_volume"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.music_volume = f
        }
        if v, ok := get(gen, "hitsound_volume"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.hitsound_volume = f
        }
        if v, ok := get(gen, "hitsound_volume_follows_music"); ok {
            result.hitsound_volume_follows_music = v == "true"
        }
        if v, ok := get(gen, "vsync_enabled"); ok {
            result.vsync_enabled = v == "true"
        }
        if v, ok := get(gen, "fps_limiter"); ok {
            if n, ok2 := strconv.parse_int(v); ok2 do result.fps_limiter = i32(max(n, 0))
        }
        if v, ok := get(gen, "gpu_profiler_enabled"); ok {
            result.gpu_profiler_enabled = v == "true"
        }
        if v, ok := get(gen, "osu_install_path"); ok {
            result.osu_install_path = strings.clone(v)
        }
        if v, ok := get(gen, "skin_path"); ok {
            result.skin_path = strings.clone(v)
        }
        if v, ok := get(gen, "use_beatmap_skin"); ok {
            result.use_beatmap_skin = v == "true"
        }
        if v, ok := get(gen, "use_beatmap_hitsounds"); ok {
            result.use_beatmap_hitsounds = v == "true"
        }
        if v, ok := get(gen, "use_beatmap_combo_color_skips"); ok {
            result.use_beatmap_combo_color_skips = v == "true"
        }
        if v, ok := get(gen, "window_width"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.window_width = f
        }
        if v, ok := get(gen, "window_height"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.window_height = f
        }
        if v, ok := get(gen, "window_mode"); ok {
            result.window_mode = window_mode_from_string(v)
        }
        if v, ok := get(gen, "primary_mouse_hwid"); ok {
            result.primary_mouse_hwid = strings.clone(v)
        }
        if v, ok := get(gen, "secondary_mouse_hwid"); ok {
            result.secondary_mouse_hwid = strings.clone(v)
        }
        if v, ok := get(gen, "cursor_size_multiplier"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.cursor_size_multiplier = f
        }
        if v, ok := get(gen, "cursor_sensitivity"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.cursor_sensitivity = f
        }
        if v, ok := get(gen, "raw_input_enabled"); ok {
            result.raw_input_enabled = v == "true"
        }
        if v, ok := get(gen, "mouse_keys_enabled"); ok {
            result.mouse_keys_enabled = v == "true"
        }
        if v, ok := get(gen, "bg_dim"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.bg_dim = f
        }
        if v, ok := get(gen, "playfield_border_opacity"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.playfield_border_opacity = f
        }
        if v, ok := get(gen, "ui_scale"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.ui_scale = f
        }
        if v, ok := get(gen, "accuracy_display_size"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.accuracy_display_size = f
        }
        if v, ok := get(gen, "snaking_in_sliders_enabled"); ok {
            result.snaking_in_sliders_enabled = v == "true"
        }
        if v, ok := get(gen, "snaking_out_sliders_enabled"); ok {
            result.snaking_out_sliders_enabled = v == "true"
        }
        for key in Rebindable_Input_Key {
            if key == .NONE do continue
            if v, ok := get(gen, rebindable_input_key_names[key]); ok {
                if n, ok2 := strconv.parse_int(v); ok2 do result.keys[key] = sdl.Scancode(n)
            }
        }
    }
    return
}

config_apply :: proc() {
    window_apply_vsync(game.user_config.vsync_enabled)
    window_set_mode_forced(game.user_config.window_mode)
    audio_apply_config_volumes()

    game.input.keys = game.user_config.keys
    game.input.mouse_keys_enabled = game.user_config.mouse_keys_enabled
}

config_save :: proc(path: string) {
    sb := strings.builder_make(context.temp_allocator)
    w  := strings.to_writer(&sb)

    cfg := config_without_forces()

    ini.write_pair(w, "universal_offset_ms",           cfg.universal_offset_ms)
    ini.write_pair(w, "vsync_enabled",                 cfg.vsync_enabled)
    ini.write_pair(w, "fps_limiter",                   cfg.fps_limiter)
    ini.write_pair(w, "gpu_profiler_enabled",          cfg.gpu_profiler_enabled)
    ini.write_pair(w, "master_volume",                 cfg.master_volume)
    ini.write_pair(w, "music_volume",                  cfg.music_volume)
    ini.write_pair(w, "hitsound_volume",               cfg.hitsound_volume)
    ini.write_pair(w, "hitsound_volume_follows_music", cfg.hitsound_volume_follows_music)
    ini.write_pair(w, "osu_install_path",              cfg.osu_install_path)
    ini.write_pair(w, "skin_path",                     cfg.skin_path)
    ini.write_pair(w, "use_beatmap_skin",              cfg.use_beatmap_skin)
    ini.write_pair(w, "use_beatmap_hitsounds",         cfg.use_beatmap_hitsounds)
    ini.write_pair(w, "use_beatmap_combo_color_skips", cfg.use_beatmap_combo_color_skips)
    ini.write_pair(w, "window_width",                  cfg.window_width)
    ini.write_pair(w, "window_height",                 cfg.window_height)
    ini.write_pair(w, "window_mode",                   window_mode_keys[cfg.window_mode])
    ini.write_pair(w, "primary_mouse_hwid",            cfg.primary_mouse_hwid)
    ini.write_pair(w, "secondary_mouse_hwid",          cfg.secondary_mouse_hwid)
    ini.write_pair(w, "cursor_size_multiplier",        cfg.cursor_size_multiplier)
    ini.write_pair(w, "cursor_sensitivity",            cfg.cursor_sensitivity)
    ini.write_pair(w, "raw_input_enabled",             cfg.raw_input_enabled)
    ini.write_pair(w, "mouse_keys_enabled",            cfg.mouse_keys_enabled)
    ini.write_pair(w, "bg_dim",                        cfg.bg_dim)
    ini.write_pair(w, "playfield_border_opacity",      cfg.playfield_border_opacity)
    ini.write_pair(w, "ui_scale",                      cfg.ui_scale)
    ini.write_pair(w, "accuracy_display_size",         cfg.accuracy_display_size)
    ini.write_pair(w, "snaking_in_sliders_enabled",    cfg.snaking_in_sliders_enabled)
    ini.write_pair(w, "snaking_out_sliders_enabled",   cfg.snaking_out_sliders_enabled)
    for key in Rebindable_Input_Key {
        if key == .NONE do continue
        ini.write_pair(w, rebindable_input_key_names[key], int(cfg.keys[key]))
    }

    err := os.write_entire_file(path, transmute([]byte)strings.to_string(sb))
    if err != os.General_Error.None {
        log.error("error while writing to settings file!", err)
        bkp_path := strings.concatenate({path, ".tmp"})
        bkp_err := os.write_entire_file(bkp_path, transmute([]byte)strings.to_string(sb))
        if bkp_err != os.General_Error.None {
            log.error("couldn't write backup path file either!", bkp_err)
        }
    }
}

config_supply_default :: proc() -> (result: User_Configuration) {
    result = {
        universal_offset_ms      = 0,
        vsync_enabled            = false,
        gpu_profiler_enabled     = true,
        master_volume            = 0.5,
        music_volume             = 0.5,
        hitsound_volume          = 0.8,
        skin_path                = DEFAULT_SKIN_PATH,
        use_beatmap_skin         = true,
        use_beatmap_hitsounds    = true,
        window_width             = 1280,
        window_height            = 720,
        window_mode              = .WINDOWED,
        cursor_size_multiplier   = 1.0,
        cursor_sensitivity       = 1.0,
        playfield_border_opacity = 0.0,
        accuracy_display_size    = 48,
        bg_dim                   = 0.3,
        snaking_in_sliders_enabled = true,
        
        // note(isak): play mode settings unsupported by stable should have defaults that match its behavior
        ui_scale                 = 1.0,
        snaking_out_sliders_enabled = false,
        use_beatmap_combo_color_skips = true,
    }
    result.keys[.K1] = .Z
    result.keys[.K2] = .X
    return
}
