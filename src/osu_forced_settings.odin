package inso

import "core:mem"
import "core:strconv"

// note(isak): maps can force user settings for their lifetime through the .inso [ForceSettings]
// section, using the same keys as user.ini. forced values are written straight into
// game.user_config so every read site stays untouched; the user's own values live in a snapshot
// and beatmap_open transitions between force sets. config_without_forces keeps them out of user.ini.

Forceable_Setting :: enum {
    WINDOW_MODE,
    BG_DIM,
    SKIN_PATH,
    PLAYFIELD_BORDER_OPACITY,
    CURSOR_SIZE_MULTIPLIER,
    SNAKING_IN_SLIDERS_ENABLED,
    SNAKING_OUT_SLIDERS_ENABLED,
}

Forced_Settings :: struct {
    present: bit_set[Forceable_Setting],
    values:  [Forceable_Setting]string, // note(isak): raw .inso values, MAPSET arena
}

// note(isak): apply is only for settings with a side effect beyond the config write. polled
// settings, and ones beatmap_open re-applies on its own (bg_dim, the skin), leave it nil
Forceable_Setting_Desc :: struct {
    ini_key: string,
    offset:  uintptr,
    size:    int,
    parse:   proc(cfg: ^User_Configuration, value: string) -> bool,
    apply:   proc(),
}

forceable_setting_descs := [Forceable_Setting]Forceable_Setting_Desc {
    .WINDOW_MODE = {
        ini_key = "window_mode",
        offset  = offset_of(User_Configuration, window_mode),
        size    = size_of(Window_Mode),
        parse   = proc(cfg: ^User_Configuration, value: string) -> bool {
            for key, mode in window_mode_keys {
                if key == value {
                    cfg.window_mode = mode
                    return true
                }
            }
            return false
        },
        apply = proc() { window_set_mode_forced(game.user_config.window_mode) },
    },
    .BG_DIM = {
        ini_key = "bg_dim",
        offset  = offset_of(User_Configuration, bg_dim),
        size    = size_of(f32),
        parse   = proc(cfg: ^User_Configuration, value: string) -> bool {
            f, ok := strconv.parse_f32(value)
            if ok do cfg.bg_dim = clamp(f, 0, 1)
            return ok
        },
    },
    .SKIN_PATH = {
        ini_key = "skin_path",
        offset  = offset_of(User_Configuration, skin_path),
        size    = size_of(string),
        parse   = proc(cfg: ^User_Configuration, value: string) -> bool {
            cfg.skin_path = value
            return len(value) > 0
        },
    },
    .PLAYFIELD_BORDER_OPACITY = {
        ini_key = "playfield_border_opacity",
        offset  = offset_of(User_Configuration, playfield_border_opacity),
        size    = size_of(f32),
        parse   = proc(cfg: ^User_Configuration, value: string) -> bool {
            f, ok := strconv.parse_f32(value)
            if ok do cfg.playfield_border_opacity = clamp(f, 0, 1)
            return ok
        },
    },
    .CURSOR_SIZE_MULTIPLIER = {
        ini_key = "cursor_size_multiplier",
        offset  = offset_of(User_Configuration, cursor_size_multiplier),
        size    = size_of(f32),
        parse   = proc(cfg: ^User_Configuration, value: string) -> bool {
            f, ok := strconv.parse_f32(value)
            if !ok || f <= 0 do return false
            cfg.cursor_size_multiplier = f
            return true
        },
    },
    .SNAKING_IN_SLIDERS_ENABLED = {
        ini_key = "snaking_in_sliders_enabled",
        offset  = offset_of(User_Configuration, snaking_in_sliders_enabled),
        size    = size_of(bool),
        parse   = proc(cfg: ^User_Configuration, value: string) -> bool {
            return _parse_force_bool(value, &cfg.snaking_in_sliders_enabled)
        },
    },
    .SNAKING_OUT_SLIDERS_ENABLED = {
        ini_key = "snaking_out_sliders_enabled",
        offset  = offset_of(User_Configuration, snaking_out_sliders_enabled),
        size    = size_of(bool),
        parse   = proc(cfg: ^User_Configuration, value: string) -> bool {
            return _parse_force_bool(value, &cfg.snaking_out_sliders_enabled)
        },
    },
}

_parse_force_bool :: proc(value: string, target: ^bool) -> bool {
    switch value {
    case "1", "true":  target^ = true
    case "0", "false": target^ = false
    case: return false
    }
    return true
}

forceable_setting_from_ini_key :: proc(key: string) -> (Forceable_Setting, bool) {
    for desc, setting in forceable_setting_descs {
        if desc.ini_key == key do return setting, true
    }
    return {}, false
}

forced_config: struct {
    active:         bit_set[Forceable_Setting],
    snapshot:       User_Configuration, // the user's own values behind every active bit
    pre_transition: User_Configuration, // user_config as of the revert, for apply's change detection
}

_forced_field_copy :: proc(dst, src: ^User_Configuration, desc: Forceable_Setting_Desc) {
    mem.copy(rawptr(uintptr(dst) + desc.offset), rawptr(uintptr(src) + desc.offset), desc.size)
}

_forced_field_differs :: proc(a, b: ^User_Configuration, desc: Forceable_Setting_Desc) -> bool {
    a_field := (^byte)(rawptr(uintptr(a) + desc.offset))
    b_field := (^byte)(rawptr(uintptr(b) + desc.offset))
    return mem.compare_byte_ptrs(a_field, b_field, desc.size) != 0
}

// note(isak): beatmap_open calls this before tearing the old mapset down - forced strings live
// in the MAPSET arena, so they must be out of user_config before the arena resets
config_force_revert :: proc() {
    forced_config.pre_transition = game.user_config
    for setting in forced_config.active {
        _forced_field_copy(&game.user_config, &forced_config.snapshot, forceable_setting_descs[setting])
    }
    forced_config.active = {}
}

// note(isak): runs once the new mapset's .inso is parsed. side-effect hooks only fire where the
// effective value differs from before the transition, so retries and same-force map switches
// don't churn the window
config_force_apply :: proc(forces: Forced_Settings) {
    forced_config.snapshot = game.user_config

    for setting in forces.present {
        desc := forceable_setting_descs[setting]
        if !desc.parse(&game.user_config, forces.values[setting]) {
            notify_warn("inso [ForceSettings]: invalid value '%s' for '%s'", forces.values[setting], desc.ini_key)
            continue
        }
        forced_config.active += {setting}
    }

    for setting in Forceable_Setting {
        desc := forceable_setting_descs[setting]
        if desc.apply == nil do continue
        if _forced_field_differs(&game.user_config, &forced_config.pre_transition, desc) {
            desc.apply()
        }
    }
}

// note(isak): the user's own configuration - active map forces replaced by the values they shadow.
// config_save writes this so a mid-map shutdown never persists forced settings
config_without_forces :: proc() -> (cfg: User_Configuration) {
    cfg = game.user_config
    for setting in forced_config.active {
        _forced_field_copy(&cfg, &forced_config.snapshot, forceable_setting_descs[setting])
    }
    return
}
