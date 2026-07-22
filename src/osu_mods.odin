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
    .HALF_TIME   = { name = "Half time",   apply_to_map = half_time_apply_to_map },
    .HIDDEN      = { name = "Hidden",      apply_to_graphics = hidden_apply_to_graphics },
    .HARD_ROCK   = { name = "Hard rock",   apply_to_map = hard_rock_apply_to_map },
    .DOUBLE_TIME = { name = "Double time", apply_to_map = double_time_apply_to_map },
    
    .DIFFICULTY_ADJUST = { name = "Difficulty adjust", apply_to_map = difficulty_adjust_apply_to_map },
}

// note(isak): runs before the diff_* -> radius/preempt/window conversions and slider instance baking
mods_apply_to_map :: proc() {
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

half_time_apply_to_map :: proc() {
    game.time_rate = 0.75
}

double_time_apply_to_map :: proc() {
    game.time_rate = 1.5
}

// note(isak): osu stable hidden - no approach circle, circles fade in over the first 40% of the
// preempt and back out over the next 30%, gone before hit time. the hit expand animation is
// disabled too.
hidden_apply_to_graphics :: proc() {
    elements := &game.beatmap.elements
    anims    := &game.beatmap.animations
    lists    := &game.beatmap.animation_lists

    invisible := animation_new(anims, lists, Animation_Alpha{
        start_time = 0, end_time = 1,
        start_alpha = 0, end_alpha = 0,
    })

    elements.data[builtin_element_slot(.APPROACH_CIRCLE)].animation_list = invisible

    hit_pop_elements := [?]Element_Type{
        .CLICKED_HIT_CIRCLE, .CLICKED_HIT_CIRCLE_OVERLAY,
        .CLICKED_SLIDER_START_CIRCLE, .CLICKED_SLIDER_START_CIRCLE_OVERLAY,
        .FINISHED_SLIDER_END_CIRCLE, .FINISHED_SLIDER_END_CIRCLE_OVERLAY,
    }
    for el in hit_pop_elements {
        elements.data[builtin_element_slot(el)].animation_list = invisible
    }

    // note(isak): animation times are normalized against the circle drawable lifetime
    // (preempt + ok window), so per-object custom preempts from scripts get proportionally
    // scaled fades rather than the same timing
    preempt  := game.beatmap.preempt_ms
    lifetime := preempt + game.beatmap.timing_windows.ok
    fade_in_end  := preempt * 0.4 / lifetime
    fade_out_end := preempt * 0.7 / lifetime

    fade := animation_new(anims, lists,
        Animation_Alpha{
            start_time = 0, end_time = fade_in_end,
            start_alpha = 0, end_alpha = 1,
        },
        Animation_Alpha{
            start_time = fade_in_end, end_time = fade_out_end,
            start_alpha = 1, end_alpha = 0,
        },
    )

    fading_elements := [?]Element_Type{
        .HIT_CIRCLE, .HIT_CIRCLE_OVERLAY,
        .SLIDER_START_CIRCLE, .SLIDER_START_CIRCLE_OVERLAY,
    }
    for el in fading_elements {
        elements.data[builtin_element_slot(el)].animation_list = fade
    }
    for digit in 0..<10 {
        digit_el := Element_Type(int(Element_Type.COMBO_DIGIT_0) + digit)
        elements.data[builtin_element_slot(digit_el)].animation_list = fade
    }
}
