package inso

import "core:math"

Osu_Mod :: enum {
    EASY,
    HALF_TIME,
    HIDDEN,
    HARD_ROCK,
    DOUBLE_TIME,
    FLASHLIGHT,

    DIFFICULTY_ADJUST,
    PRACTICE,
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
    .FLASHLIGHT  = { name = "Flashlight",  apply_to_graphics = flashlight_reset },

    .DIFFICULTY_ADJUST = { name = "Difficulty adjust", apply_to_map = difficulty_adjust_apply_to_map },
    .PRACTICE          = { name = "Practice" },
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

PRACTICE_MISS_LENIENCY_MS :: 1000

// note(isak): the play session's start is wherever we last switched into PLAY, so a restart
// lands on the same timestamp it came from
practice_restart_on_miss :: proc() {
    if .PRACTICE not_in game.mods || game.mode != .PLAY || game.mode_switching_to != .NONE do return

    if practice_in_leniency_window() do return
    game_switch_mode(.PLAY, game.mode_seek_time_on_switch)
}

practice_in_leniency_window :: proc() -> bool {
    if .PRACTICE not_in game.mods do return false
    return beatmap_music_time_ms(&game.beatmap) < game.mode_seek_time_on_switch + PRACTICE_MISS_LENIENCY_MS
}

// note: the combo a full combo would be sitting at when practice starts
practice_combo_before_start :: proc() -> (combo: int) {
    practice_start_ms := game.mode_seek_time_on_switch
    for &hobj in game.beatmap.hitobjects {
        if hobj.start_time_ms >= practice_start_ms do break
        switch hobj.type {
        case .CIRCLE:
            combo += 1
        case .SLIDER:
            slider := &hobj.slider_state
            head_and_tail := 2
            repeats := slider.path_travel_count - 1
            combo += head_and_tail + repeats + slider.tick_count * slider.path_travel_count
        case .SPINNER, .NONE:
        }
    }
    return combo
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


FLASHLIGHT_RADIUS_OSUPX      :: 125
FLASHLIGHT_FOLLOW_DELAY_MS   :: 120
FLASHLIGHT_RESIZE_DURATION_S :: 0.8
FLASHLIGHT_BREAK_SCALE       :: 2.5
FLASHLIGHT_SLIDER_DIM        :: 0.8

Flashlight_State :: struct {
    follow_from_px, follow_to_px: vec2,
    follow_start_time_s: f64,
    scale_from, scale_to: f32,
    scale_change_time_s: f64,

    // note: combo the light counts on top of score.combo; practice starts with what a full combo
    // would have reached, and combo broken inside the practice leniency window is kept here
    practice_carried_combo: int,
}

flashlight: Flashlight_State

flashlight_reset :: proc() {
    flashlight.practice_carried_combo = practice_combo_before_start() if .PRACTICE in game.mods else 0
    scale := flashlight_target_scale(beatmap_music_time_ms(&game.beatmap))
    flashlight.follow_from_px = mouse.pos
    flashlight.follow_to_px = mouse.pos
    flashlight.follow_start_time_s = 0
    flashlight.scale_from = scale
    flashlight.scale_to = scale
    flashlight.scale_change_time_s = 0
}

flashlight_combo_scale :: proc(combo: int) -> f32 {
    if combo >= 200 do return 0.625
    if combo >= 100 do return 0.8125
    return 1
}

flashlight_target_scale :: proc(map_time: f64) -> f32 {
    if beatmap_in_break(&game.beatmap, map_time) do return FLASHLIGHT_BREAK_SCALE
    return flashlight_combo_scale(game.beatmap.score.combo + flashlight.practice_carried_combo)
}

flashlight_on_combo_break :: proc(lost: int) {
    if practice_in_leniency_window() {
        flashlight.practice_carried_combo += lost
    } else {
        flashlight.practice_carried_combo = 0
    }
}

flashlight_current_scale :: proc() -> f32 {
    progress := clamp(f32((game.frame_clock_s - flashlight.scale_change_time_s) / FLASHLIGHT_RESIZE_DURATION_S), 0, 1)
    return math.lerp(flashlight.scale_from, flashlight.scale_to, progress)
}

flashlight_current_pos_px :: proc() -> vec2 {
    progress := clamp(f32((game.frame_clock_s - flashlight.follow_start_time_s) * 1000 / FLASHLIGHT_FOLLOW_DELAY_MS), 0, 1)
    eased := progress * (2 - progress)
    return math.lerp(flashlight.follow_from_px, flashlight.follow_to_px, eased)
}

flashlight_update :: proc(map_time: f64) {
    target_scale := flashlight_target_scale(map_time)
    if target_scale != flashlight.scale_to {
        flashlight.scale_from = flashlight_current_scale()
        flashlight.scale_to = target_scale
        flashlight.scale_change_time_s = game.frame_clock_s
    }

    if mouse.pos != flashlight.follow_to_px {
        flashlight.follow_from_px = flashlight_current_pos_px()
        flashlight.follow_to_px = mouse.pos
        flashlight.follow_start_time_s = game.frame_clock_s
    }
}

flashlight_any_slider_tracking :: proc(visible_hobjs: []Hitobject, map_time: f64) -> bool {
    for &hobj in visible_hobjs {
        if hobj.type != .SLIDER || .TRACKING not_in hobj.slider_state.flags do continue
        if hobj.start_time_ms <= map_time && map_time < hobj.end_time_ms do return true
    }
    return false
}

flashlight_draw :: proc(visible_hobjs: []Hitobject, map_time: f64) {
    r_bind_layer_and_push_current_state(.OVERLAY,
        transform = window.screenspace_transform,
        pipeline = { pipeline = builtin_pipeline_slot(.FLASHLIGHT) })

    pos_px := flashlight_current_pos_px()
    radius_px := FLASHLIGHT_RADIUS_OSUPX * flashlight_current_scale() * playfield_px_per_osupx()
    screen_size := vec2{window.rect.w, window.rect.h}
    r_draw_quad_with_uv(&window.renderer.quad_geometry,
        pos_min = {0, 0},
        pos_max = screen_size,
        uv_min  = -pos_px / radius_px,
        uv_max  = (screen_size - pos_px) / radius_px,
        color = color_black,
        tex_index = builtin_texture(.WHITE))

    r_bind_pipeline({ pipeline = builtin_pipeline_slot(.QUAD) })
    if flashlight_any_slider_tracking(visible_hobjs, map_time) {
        r_draw_rect(&window.renderer.quad_geometry, {0, 0, screen_size.x, screen_size.y},
            with_alpha(color_black, FLASHLIGHT_SLIDER_DIM), builtin_texture(.WHITE))
    }
}
