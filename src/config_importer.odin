package inso

import "core:encoding/ini"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

// note(isak): difference between lazer and stable offset, as noted by lazer's FramedBeatmapClock
STABLE_FEEL_OFFSET_MS :: 15

// note(isak): maps relevant settings from the newest osu!.*.cfg into inso's config keys. this
// is implemented mostly for the surprise factor, but is useful for letting our tournament players
// set up/warm up on stable, and load their configs without having them get used to a new UI
config_import_from_osu :: proc(osu_install_path: string) {
    cfg_path, found := _osu_config_find_active_profile_cfg(osu_install_path)
    if !found {
        notify_warn("osu import: no osu!.*.cfg found under '%s'", osu_install_path)
        return
    }

    m, _, ok := ini.load_map_from_path(cfg_path, context.temp_allocator)
    if !ok {
        notify_warn("osu import: couldn't read '%s'", cfg_path)
        return
    }

    pairs := m[""]

    get :: proc(pairs: map[string]string, key: string) -> (string, bool) {
        v, ok := pairs[key]
        return strings.trim_space(v), ok && len(strings.trim_space(v)) > 0
    }
    get_percent :: proc(pairs: map[string]string, key: string) -> (f32, bool) {
        if v, ok := get(pairs, key); ok {
            if n, ok2 := strconv.parse_f32(v); ok2 do return clamp(n / 100.0, 0, 1), true
        }
        return 0, false
    }
    get_bool :: proc(pairs: map[string]string, key: string) -> (bool, bool) {
        if v, ok := get(pairs, key); ok {
            return v == "1" || v == "true", true
        }
        return false, false
    }

    cfg := &game.user_config

    if v, ok := get_percent(pairs, "VolumeUniversal"); ok do cfg.master_volume = v
    if v, ok := get_percent(pairs, "VolumeMusic");     ok do cfg.music_volume = v
    if v, ok := get_percent(pairs, "VolumeEffect");    ok do cfg.hitsound_volume = v

    if fullscreen, ok := get_bool(pairs, "Fullscreen"); ok {
        cfg.window_mode = .EXCLUSIVE_FULLSCREEN if fullscreen else .WINDOWED
        if v, ok := get(pairs, "Width");  ok do if n, ok2 := strconv.parse_f32(v); ok2 do cfg.window_width  = clamp(n, 320, 7680)
        if v, ok := get(pairs, "Height"); ok do if n, ok2 := strconv.parse_f32(v); ok2 do cfg.window_height = clamp(n, 240, 4320)
    }

    if v, ok := get(pairs, "Offset"); ok {
        if n, ok2 := strconv.parse_int(v); ok2 {
            // note(isak): in addition to the perceived lazer/stable difference constant, we also add
            // the device buffer size difference because we subtract output latency from the music 
            // clock in inso
            feel_correction := STABLE_FEEL_OFFSET_MS + int(audio.output_latency_ms + 0.5)
            cfg.universal_offset_ms = n + feel_correction
            log.infof("osu import: offset %v -> %v (stable feel +%v, device buffer +%.1fms)",
                n, cfg.universal_offset_ms, STABLE_FEEL_OFFSET_MS, audio.output_latency_ms)
        }
    }
    if v, ok := get_percent(pairs, "DimLevel"); ok do cfg.bg_dim = v
    if v, ok := get(pairs, "CursorSize"); ok {
        if n, ok2 := strconv.parse_f32(v); ok2 do cfg.cursor_size_multiplier = clamp(n, 0.1, 2.0)
    }
    if v, ok := get(pairs, "MouseSpeed"); ok {
        if n, ok2 := strconv.parse_f32(v); ok2 do cfg.cursor_sensitivity = clamp(n, 0.1, 5.0)
        // note(isak): raw input is the only path that owns cursor position
        if cfg.cursor_sensitivity != 1.0 {
            cfg.raw_input_enabled = true
        }
    }

    if v, ok := get_bool(pairs, "SnakingSliders");    ok do cfg.snaking_in_sliders_enabled = v
    if v, ok := get_bool(pairs, "SnakingOutSliders"); ok do cfg.snaking_out_sliders_enabled = v

    // note(isak): osu's MouseDisableButtons is inverted from our mouse_keys_enabled (1 = disabled)
    if v, ok := get_bool(pairs, "MouseDisableButtons"); ok do cfg.mouse_keys_enabled = !v

    if v, ok := get(pairs, "Skin"); ok && v != "default" && v != "-1" {
        install := osu_install_path
        for len(install) > 0 && (install[len(install) - 1] == '/' || install[len(install) - 1] == '\\') {
            install = install[:len(install) - 1]
        }
        skin_dir := strings.concatenate({install, "/Skins/", v, "/"})
        if os.exists(skin_dir) && os.is_dir(skin_dir) {
            cfg.skin_path = skin_dir
        } else {
            log.warnf("osu import: skin '%s' has no folder, keeping current skin", v)
        }
    }

    if v, ok := get(pairs, "keyOsuLeft"); ok {
        if sc, ok2 := _osu_import_keybind(v); ok2 do cfg.keys[.K1] = sc
    }
    if v, ok := get(pairs, "keyOsuRight"); ok {
        if sc, ok2 := _osu_import_keybind(v); ok2 do cfg.keys[.K2] = sc
    }

    notify_info("imported osu settings from '%s'", cfg_path)
}

_osu_config_find_active_profile_cfg :: proc(osu_install_path: string) -> (path: string, found: bool) {
    handle, err := os.open(osu_install_path)
    if err != nil {
        notify_warn("osu import: can't open '%s'", osu_install_path)
        return
    }
    defer os.close(handle)

    entries, _ := os.read_dir(handle, 1024, context.temp_allocator)

    newest: i64 = -1
    for entry in entries {
        if entry.type == .Directory do continue
        if entry.name == "osu!.cfg" do continue
        if !strings.has_prefix(entry.name, "osu!.") do continue
        if !strings.has_suffix(entry.name, ".cfg") do continue

        stamp := entry.modification_time._nsec
        if stamp > newest {
            newest = stamp
            path = strings.concatenate({osu_install_path, "/", entry.name}, context.temp_allocator)
            found = true
        }
    }
    return
}

_osu_import_keybind :: proc(name: string) -> (sdl.Scancode, bool) {
    sc, mapped := scancode_from_keys_name(name)
    if !mapped {
        log.warnf("osu import: unmapped keybind '%s' (mouse buttons aren't supported), keeping current bind", name)
    }
    return sc, mapped
}

// note(isak): osu serializes binds as .NET System.Windows.Forms.Keys names
scancode_from_keys_name :: proc(name: string) -> (sdl.Scancode, bool) {
    // single letter A..Z
    if len(name) == 1 && name[0] >= 'A' && name[0] <= 'Z' {
        return sdl.Scancode(int(sdl.Scancode.A) + int(name[0] - 'A')), true
    }

    if digit, ok := suffix_int(name, "NumPad"); ok && digit >= 0 && digit <= 9 {
        if digit == 0 do return .KP_0, true
        return sdl.Scancode(int(sdl.Scancode.KP_1) + (digit - 1)), true
    }
    if digit, ok := suffix_int(name, "D"); ok && digit >= 0 && digit <= 9 {
        if digit == 0 do return ._0, true
        return sdl.Scancode(int(sdl.Scancode._1) + (digit - 1)), true
    }
    if n, ok := suffix_int(name, "F"); ok && n >= 1 && n <= 24 {
        if n <= 12 do return sdl.Scancode(int(sdl.Scancode.F1) + (n - 1)), true
        return sdl.Scancode(int(sdl.Scancode.F13) + (n - 13)), true
    }

    switch name {
    case "Space":       return .SPACE, true
    case "Tab":         return .TAB, true
    case "Return", "Enter": return .RETURN, true
    case "Escape":      return .ESCAPE, true
    case "Back":        return .BACKSPACE, true
    case "ShiftKey", "LShiftKey": return .LSHIFT, true
    case "RShiftKey":   return .RSHIFT, true
    case "ControlKey", "LControlKey": return .LCTRL, true
    case "RControlKey": return .RCTRL, true
    case "Menu", "LMenu": return .LALT, true
    case "RMenu":       return .RALT, true
    case "Left":        return .LEFT, true
    case "Up":          return .UP, true
    case "Right":       return .RIGHT, true
    case "Down":        return .DOWN, true
    case "Oem1", "OemSemicolon":     return .SEMICOLON, true
    case "Oemplus":                  return .EQUALS, true
    case "Oemcomma":                 return .COMMA, true
    case "OemMinus":                 return .MINUS, true
    case "OemPeriod":                return .PERIOD, true
    case "Oem2", "OemQuestion":      return .SLASH, true
    case "Oem3", "Oemtilde":         return .GRAVE, true
    case "Oem4", "OemOpenBrackets":  return .LEFTBRACKET, true
    case "Oem5", "OemPipe":          return .BACKSLASH, true
    case "Oem6", "OemCloseBrackets": return .RIGHTBRACKET, true
    case "Oem7", "OemQuotes":        return .APOSTROPHE, true
    case "Oem102", "OemBackslash":   return .NONUSBACKSLASH, true
    }

    return .UNKNOWN, false
}

// note(isak): parses the trailing integer of a .NET Keys name like "D1" or "NumPad3", returning
// false unless the name is exactly the prefix followed by digits (so "Down" won't match "D")
suffix_int :: proc(name, prefix: string) -> (int, bool) {
    if !strings.has_prefix(name, prefix) do return 0, false
    rest := name[len(prefix):]
    if len(rest) == 0 do return 0, false
    for c in rest {
        if c < '0' || c > '9' do return 0, false
    }
    return strconv.parse_int(rest)
}
