package notosu

import "core:encoding/ini"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"


// note(isak): user config is saved to a .ini file, just like osu
User_Configuration :: struct {
    universal_offset_ms: int,
    master_volume: f32,
    music_volume: f32,
    hitsound_volume: f32,
    vsync_enabled: bool,
    skin_path: string,
    primary_mouse_hwid: string,
    secondary_mouse_hwid: string,
    cursor_size_multiplier: f32,
    cursor_sensitivity: f32,
    bg_dim: f32, // note(isak): 0 = background fully visible, 1 = fully black
}

config_load :: proc(path: string) -> (result: User_Configuration) {
    result = config_supply_default()

    m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
    if !ok do return

    get :: proc(pairs: map[string]string, key: string) -> (string, bool) {
        v, ok := pairs[key]
        return strings.trim_space(v), ok && len(v) > 0
    }

    // note(isak): top level is sectionless
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
        if v, ok := get(gen, "vsync_enabled"); ok {
            result.vsync_enabled = v == "true"
        }
        if v, ok := get(gen, "skin_path"); ok {
            result.skin_path = strings.clone(v)
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
        if v, ok := get(gen, "bg_dim"); ok {
            if f, ok2 := strconv.parse_f32(v); ok2 do result.bg_dim = f
        }
    }
    return
}

config_save :: proc(path: string) {
    sb := strings.builder_make(context.temp_allocator)
    w  := strings.to_writer(&sb)

    ini.write_pair(w, "universal_offset_ms",    game.user_config.universal_offset_ms)
    ini.write_pair(w, "vsync_enabled",          game.user_config.vsync_enabled)
    ini.write_pair(w, "master_volume",          game.user_config.master_volume)
    ini.write_pair(w, "music_volume",           game.user_config.music_volume)
    ini.write_pair(w, "hitsound_volume",        game.user_config.hitsound_volume)
    ini.write_pair(w, "skin_path",              game.user_config.skin_path)
    ini.write_pair(w, "primary_mouse_hwid",     game.user_config.primary_mouse_hwid)
    ini.write_pair(w, "secondary_mouse_hwid",   game.user_config.secondary_mouse_hwid)
    ini.write_pair(w, "cursor_size_multiplier", game.user_config.cursor_size_multiplier)
    ini.write_pair(w, "cursor_sensitivity",     game.user_config.cursor_sensitivity)
    ini.write_pair(w, "bg_dim",                 game.user_config.bg_dim)

    err := os.write_entire_file(path, transmute([]byte)strings.to_string(sb))
    if err != os.General_Error.None {
        log.error("error while writing to settings file!", err)
        bkp_path := strings.concatenate({path, ".tmp"})
        bkp_err := os.write_entire_file(bkp_path, transmute([]byte)strings.to_string(sb))
        if bkp_err != os.General_Error.None {
            log.error("couldn't write backup path file either!", bkp_err)
        }
    }
    
    assert(err == os.General_Error.None, "config_save :: error while writing to settings file!")
}

config_supply_default :: proc() -> (result: User_Configuration) {
    return {
        universal_offset_ms = -28,
        vsync_enabled       = false,
        master_volume       = 0.5,
        music_volume        = 0.5,
        hitsound_volume     = 0.8,
        skin_path              = "skins/gn/",
        cursor_size_multiplier = 1.0,
        cursor_sensitivity     = 1.0,
    }
}
