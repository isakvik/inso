package inso

Osu_Mod :: enum {
    EASY,
    HALF_TIME,
    HIDDEN,
    HARD_ROCK,
    DOUBLE_TIME,

    DIFFICULTY_ADJUST,
}

Osu_Mods :: distinct bit_set[Osu_Mod]

Osu_Mod_Info :: struct {
    name: cstring,
    apply_to_map: proc(),
    apply_to_graphics: proc(),
}

osu_mod_table := [Osu_Mod]Osu_Mod_Info {
    .EASY        = { name = "Easy",        apply_to_map = easy_apply_to_map },
    .HALF_TIME   = { name = "Half time" },
    .HIDDEN      = { name = "Hidden",      apply_to_graphics = hidden_apply_to_graphics },
    .HARD_ROCK   = { name = "Hard rock",   apply_to_map = hard_rock_apply_to_map },
    .DOUBLE_TIME = { name = "Double time" },
    
    .DIFFICULTY_ADJUST = { name = "Difficulty adjust", apply_to_map = difficulty_adjust_apply_to_map },
}


// note(isak): runs before the diff_* -> radius/preempt/window conversions and slider instance writes
mods_apply_to_map :: proc() {
    game.time_rate = mod_time_rate()
    for mod in game.mods {
        if apply := osu_mod_table[mod].apply_to_map; apply != nil do apply()
    }
}
// note(isak): runs after create_default_elements
mods_apply_to_graphics :: proc() {
    for mod in game.mods {
        if apply := osu_mod_table[mod].apply_to_graphics; apply != nil do apply()
    }
}

half_time_rate:   f32 = 0.75
double_time_rate: f32 = 1.5

mod_time_rate :: proc() -> f32 {
    rate := f32(1)
    if .HALF_TIME in game.mods do rate *= half_time_rate
    if .DOUBLE_TIME in game.mods do rate *= double_time_rate
    return rate
}

time_rate_recompute :: proc() {
    game.time_rate = mod_time_rate()
    sound_set_speed(&game.beatmap.music, game.time_rate)
}

Difficulty_Setting :: enum {
    CIRCLE_SIZE,
    APPROACH_RATE,
    HP_DRAIN,
    OVERALL_DIFFICULTY,
}

difficulty_setting_names := [Difficulty_Setting]cstring {
    .CIRCLE_SIZE        = "Circle size",
    .APPROACH_RATE      = "Approach rate",
    .HP_DRAIN           = "HP drain",
    .OVERALL_DIFFICULTY = "Overall difficulty",
}

map_difficulty_setting :: proc(osu_map: ^Osu_Map, setting: Difficulty_Setting) -> ^f64 {
    switch setting {
    case .CIRCLE_SIZE:        return &osu_map.diff_circle_size
    case .APPROACH_RATE:      return &osu_map.diff_approach_rate
    case .HP_DRAIN:           return &osu_map.diff_hp_drain
    case .OVERALL_DIFFICULTY: return &osu_map.diff_overall_difficulty
    }
    unreachable()
}

difficulty_adjust_settings: [Difficulty_Setting]f64
map_difficulty_defaults:    [Difficulty_Setting]f64

difficulty_adjust_apply_to_map :: proc() {
    for setting in Difficulty_Setting {
        map_difficulty_setting(game.active_map, setting)^ = difficulty_adjust_settings[setting]
    }
}

easy_apply_to_map :: proc() {
    for setting in Difficulty_Setting {
        map_difficulty_setting(game.active_map, setting)^ *= 0.5
    }
}

hard_rock_apply_to_map :: proc() {
    factors := [Difficulty_Setting]f64 {
        .CIRCLE_SIZE        = 1.3,
        .APPROACH_RATE      = 1.4,
        .HP_DRAIN           = 1.4,
        .OVERALL_DIFFICULTY = 1.4,
    }
    for setting in Difficulty_Setting {
        stat := map_difficulty_setting(game.active_map, setting)
        stat^ = min(stat^ * factors[setting], 10)
    }

    for &hobj in game.active_map.hitobjects {
        hobj.pos.y = 384 - hobj.pos.y
    }
    for &path in game.active_map.slider_paths {
        for &node in path.nodes {
            node.y = 384 - node.y
        }
    }
}

hidden_apply_to_graphics :: proc() {
    for &hobj in game.beatmap.hitobjects {
        hobj.flags |= {.HIDDEN_FADES}
    }
}

// note(isak): circles fade in over the first 40% of the preempt and back out over the next 30%,
// gone before hit time. times are normalized against the circle drawable lifetime (preempt + ok
// window), so per-object custom preempts from scripts get proportionally scaled fades rather
// than the same timing
hidden_fade_animation_new :: proc(beatmap: ^Beatmap) -> Animation_List_ID {
    preempt  := beatmap.preempt_ms
    lifetime := preempt + beatmap.timing_windows.ok
    fade_in_end  := preempt * 0.4 / lifetime
    fade_out_end := preempt * 0.7 / lifetime

    return animation_new(&beatmap.animations, &beatmap.animation_lists,
        Animation_Alpha{
            start_time = 0, end_time = fade_in_end,
            start_alpha = 0, end_alpha = 1,
        },
        Animation_Alpha{
            start_time = fade_in_end, end_time = fade_out_end,
            start_alpha = 1, end_alpha = 0,
        },
    )
}
