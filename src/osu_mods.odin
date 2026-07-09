package inso

Osu_Mod :: enum {
    EASY,
    HIDDEN,
    HARD_ROCK,
    DOUBLE_TIME,
}

Osu_Mods :: distinct bit_set[Osu_Mod]

// note(isak): mods hook into two points of beatmap_on_init: apply_to_map runs before the
// diff_* -> radius/preempt/window conversions and slider instance baking, apply_to_graphics
// after create_default_elements
Osu_Mod_Info :: struct {
    name: cstring,
    apply_to_map: proc(),
    apply_to_graphics: proc(),
}

osu_mod_table := [Osu_Mod]Osu_Mod_Info {
    .EASY        = { name = "Easy",        apply_to_map = easy_apply_to_difficulty },
    .HIDDEN      = { name = "Hidden",      apply_to_graphics = hidden_apply_to_graphics },
    .HARD_ROCK   = { name = "Hard rock",   apply_to_map = hard_rock_apply_to_map },
    .DOUBLE_TIME = { name = "Double time", apply_to_map = double_time_apply_to_map },
}

mods_apply_to_map :: proc() {
    for mod in game.mods {
        if apply := osu_mod_table[mod].apply_to_map; apply != nil do apply()
    }
}

mods_apply_to_graphics :: proc() {
    for mod in game.mods {
        if apply := osu_mod_table[mod].apply_to_graphics; apply != nil do apply()
    }
}

easy_apply_to_difficulty :: proc() {
    game.active_map.diff_circle_size        *= 0.5
    game.active_map.diff_approach_rate      *= 0.5
    game.active_map.diff_hp_drain           *= 0.5
    game.active_map.diff_overall_difficulty *= 0.5
}

hard_rock_apply_to_map :: proc() {
    game.active_map.diff_circle_size        = min(game.active_map.diff_circle_size * 1.3, 10)
    game.active_map.diff_approach_rate      = min(game.active_map.diff_approach_rate * 1.4, 10)
    game.active_map.diff_hp_drain           = min(game.active_map.diff_hp_drain * 1.4, 10)
    game.active_map.diff_overall_difficulty = min(game.active_map.diff_overall_difficulty * 1.4, 10)

    for &hobj in game.active_map.hitobjects {
        hobj.pos.y = 384 - hobj.pos.y
    }
    for &path in game.active_map.slider_paths {
        for &node in path.nodes {
            node.y = 384 - node.y
        }
    }
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

    invisible := animation_new(anims, Animation_Alpha{
        start_time = 0, end_time = 1,
        start_alpha = 0, end_alpha = 0,
    })

    elements.data[builtin_element_slot(.APPROACH_CIRCLE)].animations = invisible

    hit_pop_elements := [?]Element_Type{
        .CLICKED_HIT_CIRCLE, .CLICKED_HIT_CIRCLE_OVERLAY,
        .CLICKED_SLIDER_START_CIRCLE, .CLICKED_SLIDER_START_CIRCLE_OVERLAY,
        .FINISHED_SLIDER_END_CIRCLE, .FINISHED_SLIDER_END_CIRCLE_OVERLAY,
    }
    for el in hit_pop_elements {
        elements.data[builtin_element_slot(el)].animations = invisible
    }

    // note(isak): animation times are normalized against the circle drawable lifetime
    // (preempt + ok window), so per-object custom preempts from scripts get proportionally
    // scaled fades rather than exact stable timing
    preempt  := game.beatmap.preempt_ms
    lifetime := preempt + game.beatmap.timing_windows.ok
    fade_in_end  := preempt * 0.4 / lifetime
    fade_out_end := preempt * 0.7 / lifetime

    fade := animation_new(anims,
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
        elements.data[builtin_element_slot(el)].animations = fade
    }
    for digit in 0..<10 {
        digit_el := Element_Type(int(Element_Type.COMBO_DIGIT_0) + digit)
        elements.data[builtin_element_slot(digit_el)].animations = fade
    }
}
