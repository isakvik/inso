package inso

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import os "core:os"
import "core:strings"
import "core:time"

//////////////////////////////////////////////////////
// note(isak): ui scaling

UI_REFERENCE_HEIGHT :: 800

ui_scale_recompute :: proc() {
    game.ui_scale = (window.rect.h / UI_REFERENCE_HEIGHT) * game.user_config.ui_scale
}

to_ui_scale :: proc(v: f32) -> f32 {
    return v * game.ui_scale
}


//////////////////////////////////////////////////////
// note(isak): ui component relevance

UI_Component :: enum {
    PLAYFIELD_BORDER,
    TIMELINE,
    EDITOR_LABEL,
    HIT_ERROR_BAR,
    INPUT_DISPLAY,
    ACCURACY_COUNTER,
    RESULTS_SCREEN,
    REBIND_PROMPT,
    TOURNAMENT_WAITING_SCREEN,
    TOURNAMENT_COUNTDOWN,
}

ui_component_visible :: proc(c: UI_Component) -> bool {
    switch c {
    case .PLAYFIELD_BORDER: return game.mode == .EDITOR && game.user_config.playfield_border_opacity > 0
    case .TIMELINE:         return game.mode == .EDITOR
    case .EDITOR_LABEL:     return game.mode == .EDITOR
    case .HIT_ERROR_BAR:    return game.mode == .PLAY
    case .INPUT_DISPLAY:    return game.mode == .PLAY
    case .ACCURACY_COUNTER: return game.mode == .PLAY && game.user_config.accuracy_display_size > 0
    case .RESULTS_SCREEN:   return game.beatmap.score.completed
    case .REBIND_PROMPT:
        return game.input.rebinding_key != .NONE ||
            app.mouse_input_mode == .REBINDING_MOUSE_PRIMARY ||
            app.mouse_input_mode == .REBINDING_MOUSE_SECONDARY
    case .TOURNAMENT_WAITING_SCREEN: return game.tournament_waiting_to_start
    case .TOURNAMENT_COUNTDOWN:
        return game.tournament_client && !game.tournament_waiting_to_start &&
            game.beatmap_active && game.beatmap.music_time_ms < 0
    }
    return false
}

//////////////////////////////////////////////////////
// note(isak): hit error bar

HIT_ERROR_BAR_CAPACITY :: 96
HIT_ERROR_TICK_FADE_MS : f64 : 4000

HIT_COLOR_MISS :: color_red
HIT_COLOR_OK :: color_orange
HIT_COLOR_GOOD :: color_lime_green
HIT_COLOR_MARVELOUS :: color_light_blue

Hit_Error_Entry :: struct {
    error_ms:    f64, // note(isak): click_time - object_time; negative = early, positive = late
    time_at:     f64,
    judgement:   Judgement_Type,
}

// note(isak): simple ring buffer
Hit_Error_Bar :: struct {
    entries: [HIT_ERROR_BAR_CAPACITY]Hit_Error_Entry,
    next:    int,
    count:   int,
}

hit_error_bar_clear :: proc(hit_error_bar: ^Hit_Error_Bar) {
    hit_error_bar^ = {}
}

hit_error_bar_add :: proc(hit_error_bar: ^Hit_Error_Bar, error_ms: f64, judgement: Judgement_Type) {
    hit_error_bar.entries[hit_error_bar.next] = {
        error_ms    = error_ms,
        time_at = game.beatmap.music_time_ms,
        judgement   = judgement,
    }
    hit_error_bar.next  = (hit_error_bar.next + 1) % HIT_ERROR_BAR_CAPACITY
    hit_error_bar.count = min(hit_error_bar.count + 1, HIT_ERROR_BAR_CAPACITY)
}

hit_error_bar_draw_screenspace :: proc(hit_error_bar: ^Hit_Error_Bar) {
    if !ui_component_visible(.HIT_ERROR_BAR) do return

    tw := game.beatmap.timing_windows
    if tw.ok <= 0 do return
    
    r_push_transform(window.screenspace_transform)

    bar_h := to_ui_scale(26)
    cx := window.rect.w / 2
    cy := window.rect.h - bar_h / 2
    tick_h := to_ui_scale(26)

    px_per_ms := to_ui_scale(1)
    bar_w := px_per_ms * f32(tw.ok) * 2
    
    now := game.beatmap.music_time_ms

    r_draw_rect(&window.renderer.quad_geometry, 
                {cx - bar_w / 2, cy - bar_h / 2, bar_w, bar_h}, with_alpha(color_black, 0.2))
    
    hit_error_zone(cx, cy, f32(tw.ok)        * px_per_ms, to_ui_scale(6), with_alpha(HIT_COLOR_OK, 0.85))
    hit_error_zone(cx, cy, f32(tw.good)      * px_per_ms, to_ui_scale(6), with_alpha(HIT_COLOR_GOOD, 0.85))
    hit_error_zone(cx, cy, f32(tw.marvelous) * px_per_ms, to_ui_scale(6), with_alpha(HIT_COLOR_MARVELOUS, 0.85))

    // perfect-timing center line
    r_draw_rect(&window.renderer.quad_geometry, {cx - to_ui_scale(1), cy - tick_h / 2, to_ui_scale(2), tick_h}, color_white)

    sum, shown := 0.0, 0
    for i in 0 ..< hit_error_bar.count {
        e := hit_error_bar.entries[i]
        age := now - e.time_at
        if age < 0 || age > HIT_ERROR_TICK_FADE_MS do continue

        alpha := f32(1 - age / HIT_ERROR_TICK_FADE_MS)
        x := clamp(cx + f32(e.error_ms) * px_per_ms, cx - bar_w / 2, cx + bar_w)

        r_draw_rect(&window.renderer.quad_geometry, {x - to_ui_scale(1), cy - tick_h / 2, to_ui_scale(2), tick_h},
            with_alpha(hit_error_color(e.judgement), alpha))

        sum   += e.error_ms
        shown += 1
    }

    /* todo(isak): this shows mean error text - UR should be exposed through a config instead
    if shown > 0 {
        mean := sum / f64(shown)
        sign := mean >= 0 ? "+" : ""
        push_text(&window.renderer, fmt.tprintf("%s%.0f ms", sign, mean),
            pos     = {cx, cy - to_ui_scale(20)},
            size    = to_ui_scale(14),
            color   = color_white,
            align_h = .Center,
            align_v = .Baseline)
    }
    */
}

hit_error_zone :: proc(cx, cy, half_px, h: f32, color: Color) {
    r_draw_rect(&window.renderer.quad_geometry, {cx - half_px, cy - h / 2, half_px * 2, h}, color)
}

hit_error_color :: proc(j: Judgement_Type) -> Color {
    #partial switch j {
    case .MARVELOUS: return HIT_COLOR_MARVELOUS
    case .GOOD:      return HIT_COLOR_GOOD
    case .OK:        return HIT_COLOR_OK
    case:            return HIT_COLOR_MISS
    }
}

//////////////////////////////////////////////////////
// note(isak): timeline

UI_Timeline :: struct {
    h_px: f32,
    hitbox_h_px: f32,
    display_h_px: f32,

    clicked, released: bool,
    dragging: bool,
    pause_on_release: bool,

    using Common: struct {
        ease: ease.Ease,
        animation_time_s: f64,
        hovered: bool,
        hover_state_change_timer: f64,
        done_on_stage_change: f64,
    }
}

ui_init_timeline :: proc(ui: ^UI_Timeline) {
    ui^ = {
        h_px = 4,
        display_h_px = ui.h_px,
        hitbox_h_px = 48,

        done_on_stage_change = 0,
        animation_time_s = 0.35,
        ease = .Quintic_Out,
    }
}

// todo(isak): you can make a lot of this common for ui components, such as the hover state, and leave functionality
// to this method... need to rewrite a bit of the size handling then but it's not a problem
ui_update_timeline :: proc(ui: ^UI_Timeline, time_value: ^f64) -> (result: bool) {
    h_px := to_ui_scale(ui.h_px)
    hitbox_h_px := to_ui_scale(ui.hitbox_h_px)

    timeline_hitbox := rect_from_points({0, window.rect.h - hitbox_h_px}, {window.rect.w, window.rect.h})

    ui.clicked = false
    ui.released = false
    
    if !app.ui_wants_mouse && button_is_pressed(mouse.buttons[.LEFT]) && point_in_rect(mouse.last_click_position[.LEFT], timeline_hitbox) {
        ui.clicked = true
        ui.dragging = true
        ui.pause_on_release = game.paused
    }

    change_state_on_release := false
    if ui.dragging {
        game.paused = true
        time_value^ = f64(clamp((mouse.pos.x + timeline_hitbox.x) / timeline_hitbox.w, 0, 1))

        result = true
        
        game.beatmap.visible_hitobject_state = {}

        if !button_is_down(mouse.buttons[.LEFT]) {
            game.paused = ui.pause_on_release
            ui.released = true
            ui.dragging = false
            change_state_on_release = true
        }
    }

    ui.hover_state_change_timer += game.dt / 1000
    ui.hover_state_change_timer = min(ui.hover_state_change_timer, ui.animation_time_s)

    was_hovered := ui.hovered
    ui.hovered = point_in_rect(mouse.pos, timeline_hitbox)
    if (!ui.dragging && ui.hovered != was_hovered) || (!ui.hovered && change_state_on_release) {
        ui.done_on_stage_change = ui.hover_state_change_timer / ui.animation_time_s
        ui.hover_state_change_timer = 0
    }
    
    t := clamp(f32(ui.hover_state_change_timer), 0, f32(ui.animation_time_s))
    if ui.hovered || ui.dragging {
        h_at_state_change := linalg.mix(hitbox_h_px, h_px, ease.ease(ui.ease, f32(ui.done_on_stage_change)))
        ui.display_h_px = linalg.mix(h_at_state_change, hitbox_h_px, ease.ease(ui.ease, t / f32(ui.animation_time_s)))
    } else {
        h_at_state_change := linalg.mix(h_px, hitbox_h_px, ease.ease(ui.ease, f32(ui.done_on_stage_change)))
        ui.display_h_px = linalg.mix(h_at_state_change, h_px, ease.ease(ui.ease, t / f32(ui.animation_time_s)))
    }
    return result
}

timeline_update :: proc(ui: ^UI_Timeline) {
    seek_to_fract: f64
    if ui_update_timeline(&game.ui_timeline, &seek_to_fract) {
        map_len_with_preempt := game.beatmap.length_ms - game.beatmap.start_time_ms
        leadin_fract := -game.beatmap.start_time_ms / map_len_with_preempt

        seeking_backward: bool
        if seek_to_fract < leadin_fract {
            seek_to_ms := game.beatmap.start_time_ms + seek_to_fract * map_len_with_preempt
            seeking_backward = seek_to_ms < game.beatmap.music_time_ms
            game.beatmap.music_time_ms = seek_to_ms
        } else {
            seek_to_music_fract := (seek_to_fract - leadin_fract) / (1 - leadin_fract)

            seek_to_ms := seek_to_music_fract * sound_get_length_ms(&game.beatmap.music)
            seeking_backward = seek_to_ms < game.beatmap.music_time_ms
            // note(isak): the timeline lives in raw playhead space (see render_timeline_clipspace),
            // so seek the audio directly rather than through the master-time beatmap_seek
            sound_set_position_ms(&game.beatmap.music, seek_to_ms)
            game.beatmap.music_time_ms = beatmap_music_position_interpolated_ms(&game.beatmap)
        }

        // note(isak): same policy as editor_seek - backward seeks re-show expired objects
        // and rewind the scheduled/fixed-update timeline
        if seeking_backward {
            beatmap_reset_object_state(&game.beatmap)
            beatmap_rewind_timeline(&game.beatmap)
        }

        if game.ui_timeline.clicked {
            sound_pause(&game.beatmap.music)
        }
    }
    if game.beatmap.music_time_ms > 0 && game.ui_timeline.released && !game.ui_timeline.pause_on_release {
        if sound_is_paused(&game.beatmap.music) {
            sound_resume(&game.beatmap.music)
        }
    }
}

render_timeline_clipspace :: proc(ui: ^UI_Timeline) {
    map_len_with_preempt := game.beatmap.length_ms - game.beatmap.start_time_ms
    map_time_with_preempt := game.beatmap.music_time_ms - game.beatmap.start_time_ms
    
    beatmap_leadin_fract := f32((-game.beatmap.preempt_ms - game.beatmap.music_time_ms) / -game.beatmap.start_time_ms)
    beatmap_finish_fract := f32(map_time_with_preempt / map_len_with_preempt)
    
    r_push_transform(clipspace_transform)
    
    r_draw_layout_rect(&window.renderer.quad_geometry, {0, 1, 1, ui.display_h_px / window.rect.h}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.1))
    r_draw_layout_rect(&window.renderer.quad_geometry, {0, 1, beatmap_finish_fract, ui.display_h_px / window.rect.h}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.4))
    if beatmap_leadin_fract > 0 {
        r_draw_layout_rect(&window.renderer.quad_geometry, {0, 1, beatmap_leadin_fract, ui.display_h_px / window.rect.h},
                         .BOTTOM_LEFT, with_alpha(color_lime_green, 0.2))
    }

    line_w := to_ui_scale(2) / window.rect.w
    line_h := max(ui.display_h_px, to_ui_scale(10)) / window.rect.h
    for bookmark_ms in game.active_map.bookmarks_ms {
        fract := f32((bookmark_ms - game.beatmap.start_time_ms) / map_len_with_preempt)
        r_draw_layout_rect(&window.renderer.quad_geometry, {fract, 1, line_w, line_h},
            .BOTTOM_MIDDLE, with_alpha(color_dim_blue, 1))
    }
}

playfield_border_draw :: proc() {
    if !ui_component_visible(.PLAYFIELD_BORDER) do return

    r_push_transform(game.playfield_transform)
    cs := game.beatmap.circle_radius_osupx
    pf_outline := Rect{
        -cs, -cs, PLAYFIELD_SIZE_OSUPX + 2*cs, (PLAYFIELD_SIZE_OSUPX * 3/4) + 2*cs,
    }
    r_draw_rect_outline(&window.renderer.quad_geometry, pf_outline,
        with_alpha(color_white, game.user_config.playfield_border_opacity), 2)
}

timeline_draw :: proc() {
    if !ui_component_visible(.TIMELINE) do return
    timeline_update(&game.ui_timeline)
    render_timeline_clipspace(&game.ui_timeline)
}

edit_mode_label_draw :: proc() {
    if !ui_component_visible(.EDITOR_LABEL) do return
    push_text(&window.renderer, "Edit mode",
        pos     = {window.rect.w / 2, to_ui_scale(30)},
        size    = to_ui_scale(24),
        color   = {255, 255, 255, 150},
        align_h = .Center,
        align_v = .Bottom)
}

//////////////////////////////////////////////////////
// note(isak): input display

INPUT_DISPLAY_PRESS_SCALE :: 0.8
INPUT_DISPLAY_ANIM_S      :: 0.15

input_display_transitions: [6]Transition

input_display_draw_screenspace :: proc() {
    if !ui_component_visible(.INPUT_DISPLAY) do return
    r_push_transform(window.screenspace_transform)

    render_input_key :: proc(key: Button_State, tr: ^Transition, rect: Rect, lit_color: Color) {
        transition_update(tr, key.is_down, INPUT_DISPLAY_ANIM_S)
        scale := transition_mix(tr^, 1, INPUT_DISPLAY_PRESS_SCALE)

        // note(isak): (rect.x, rect.y) anchors the bottom-right corner, so shrinking about the
        // key's center pulls the corner inward by half the size delta
        scaled := Rect{
            rect.x - rect.w * (1 - scale) / 2,
            rect.y - rect.h * (1 - scale) / 2,
            rect.w * scale,
            rect.h * scale,
        }
        display_color := key.is_down ? lit_color : color_white
        r_draw_layout_rect(&window.renderer.quad_geometry, scaled, .BOTTOM_RIGHT, display_color, builtin_texture(.WHITE))
    }

    tr := &input_display_transitions
    key := to_ui_scale(30)
    y_step := to_ui_scale(4) + key
    half := to_ui_scale(15)
    cy := window.rect.h / 2

    render_input_key(game.input.k1, &tr[0], { window.rect.w, cy - y_step,   key, key }, color_dim_yellow)
    render_input_key(game.input.k2, &tr[1], { window.rect.w, cy,          key, key }, color_dim_yellow)

    lit_color := app.mouse_input_mode == .RAW_DOUBLE_MOUSE_INPUT ? color_sky_blue :  color_magenta
    render_input_key(game.input.m1, &tr[2], { window.rect.w, cy + y_step,   key, key }, lit_color)
    render_input_key(game.input.m2, &tr[3], { window.rect.w, cy + 2*y_step, key, key }, lit_color)

    if app.mouse_input_mode == .RAW_DOUBLE_MOUSE_INPUT {
        render_input_key(game.input.ms1, &tr[4], { window.rect.w, cy + y_step,   key, half }, color_dim_orange)
        render_input_key(game.input.ms2, &tr[5], { window.rect.w, cy + 2*y_step, key, half }, color_dim_orange)
    }
}


//////////////////////////////////////////////////////
// note(isak): accuracy counter

ACCURACY_ROLL_TAU_MS :: 50 // note(isak): smaller = faster roll toward the true accuracy

accuracy_display_draw_screenspace :: proc() {
    if !ui_component_visible(.ACCURACY_COUNTER) do return

    target := score_accuracy(&game.beatmap.score)
    alpha := 1 - math.exp(-game.dt / ACCURACY_ROLL_TAU_MS)
    game.accuracy_display += (target - game.accuracy_display) * alpha

    r_push_transform(window.screenspace_transform)
    accuracy_string := fmt.tprintf("%.2f%%", game.accuracy_display * 100)
    push_text(&window.renderer, accuracy_string,
        pos     = {window.rect.w / 2, to_ui_scale(12)},
        size    = to_ui_scale(game.user_config.accuracy_display_size),
        color   = color_black,
        blur    = 3,
        align_h = .Center,
        align_v = .Top)
    push_text(&window.renderer, accuracy_string,
        pos     = {window.rect.w / 2, to_ui_scale(12)},
        size    = to_ui_scale(game.user_config.accuracy_display_size),
        color   = color_white,
        align_h = .Center,
        align_v = .Top)
}


//////////////////////////////////////////////////////
// note(isak): results screen

RESULTS_GRACE_PERIOD_MS :: 1000

beatmap_last_scoring_hitobject :: proc(beatmap: ^Beatmap) -> ^Hitobject {
    #reverse for &hobj in beatmap.hitobjects {
        if hobj.type != .SPINNER do return &hobj
    }
    return nil
}

results_screen_update :: proc() {
    if game.mode != .PLAY || game.beatmap.score.completed do return

    last := beatmap_last_scoring_hitobject(&game.beatmap)
    if last == nil || last.judgement_index <= 0 do return
    // note(isak): the play clock free-runs past the audio end (see beatmap_on_update), so this threshold
    // is always reachable even when the track is shorter than the last object plus the grace period
    if beatmap_music_time_ms(&game.beatmap) < last.end_time_ms + RESULTS_GRACE_PERIOD_MS do return

    game.beatmap.score.completed = true
    score_write_results_file()
    lua_beatmap_on_map_complete()
}

results_screen_draw :: proc() {
    if !ui_component_visible(.RESULTS_SCREEN) do return

    s :: 1.5

    r_check_and_bind_layer(.TOP)
    r_push_transform(fullscreen_transform)
    r_draw_quad(&window.renderer.quad_geometry,
        vec2{0,0}, vec2{1,1},
        vec2{0,0}, vec2{1,1},
        with_alpha(color_black, 0.8))

    score := &game.beatmap.score
    center_x := window.rect.w / 2
    y := window.rect.h / 2 - to_ui_scale(130 * s)

    map_name := fmt.tprintf("%s - %s [%s]",
        game.active_map.artist, game.active_map.title, game.active_map.difficulty_name)
    push_text(&window.renderer, map_name,
        pos = {center_x, y}, size = to_ui_scale(20 * s),
        color = {255, 255, 255, 180}, align_h = .Center, align_v = .Middle)
    y += to_ui_scale(60 * s)

    push_text(&window.renderer, fmt.tprintf("%.2f%%", score_accuracy(score) * 100),
        pos = {center_x, y}, size = to_ui_scale(56 * s),
        color = color_white, align_h = .Center, align_v = .Middle)
    y += to_ui_scale(52 * s)

    push_text(&window.renderer, fmt.tprintf("%dx max combo", score.max_combo),
        pos = {center_x, y}, size = to_ui_scale(24 * s),
        color = {255, 255, 255, 220}, align_h = .Center, align_v = .Middle)
    y += to_ui_scale(44 * s)

    counts := fmt.tprintf("marvelous %d   good %d   ok %d   miss %d",
        score.hit_counts[.MARVELOUS], score.hit_counts[.GOOD],
        score.hit_counts[.OK], score.hit_counts[.MISS])
    push_text(&window.renderer, counts,
        pos = {center_x, y}, size = to_ui_scale(18 * s),
        color = {255, 255, 255, 180}, align_h = .Center, align_v = .Middle)
    y += to_ui_scale(30 * s)

    hit_errors := score_hit_error_stats()
    push_text(&window.renderer,
        fmt.tprintf("unstable rate %.1f   %.2f ms / +%.2f ms", hit_errors.unstable_rate, hit_errors.early_mean, hit_errors.late_mean),
        pos = {center_x, y}, size = to_ui_scale(18 * s),
        color = {255, 255, 255, 180}, align_h = .Center, align_v = .Middle)

    push_text(&window.renderer, "score saved to scores/",
        pos = {center_x, window.rect.h - to_ui_scale(64 * s)}, size = to_ui_scale(14 * s),
        color = {255, 255, 255, 120}, align_h = .Center, align_v = .Middle)
}

score_write_results_file :: proc() {
    now := time.now()
    year, month, day := time.date(now)
    hour, minute, second := time.clock_from_time(now)

    _ = os.make_directory("scores")
    path := fmt.tprintf("scores/%04d-%02d-%02d_%02d-%02d-%02d.txt",
        year, int(month), day, hour, minute, second)

    score := &game.beatmap.score
    hit_errors := score_hit_error_stats()

    judged := score_judged_object_count(score)
    total := score_total_scoring_objects()

    mods_text: strings.Builder
    strings.builder_init(&mods_text, context.temp_allocator)
    for mod in game.mods {
        if strings.builder_len(mods_text) > 0 do strings.write_string(&mods_text, ", ")
        strings.write_string(&mods_text, string(osu_mod_table[mod].name))
    }

    // note(isak): defaults are captured before mods apply, so any difference is an adjusted play
    difficulty_changes: strings.Builder
    strings.builder_init(&difficulty_changes, context.temp_allocator)
    difficulty_labels := [Difficulty_Setting]string {
        .CIRCLE_SIZE        = "circle size   ",
        .APPROACH_RATE      = "approach rate ",
        .HP_DRAIN           = "hp drain      ",
        .OVERALL_DIFFICULTY = "overall diff  ",
    }
    for setting in Difficulty_Setting {
        current := map_difficulty_setting(game.active_map, setting)^
        if current == map_difficulty_defaults[setting] do continue
        fmt.sbprintf(&difficulty_changes, "%s %.1f -> %.1f\n",
            difficulty_labels[setting], map_difficulty_defaults[setting], current)
    }

    content := fmt.tprintf(
        "%s - %s [%s]\n" +
        "played %04d-%02d-%02d %02d:%02d:%02d utc\n" +
        "\n" +
        "accuracy       %.2f%%\n" +
        "max combo      %dx\n" +
        "marvelous      %d\n" +
        "good           %d\n" +
        "ok             %d\n" +
        "miss           %d\n" +
        "unstable rate  %.1f\n" +
        "hit error      %.2f ms / +%.2f ms\n" +
        "\n" +
        "objects judged %d / %d%s\n" +
        "time rate      %.2fx%s\n" +
        "mods           %s\n" +
        "%s",
        game.active_map.artist, game.active_map.title, game.active_map.difficulty_name,
        year, int(month), day, hour, minute, second,
        score_accuracy(score) * 100,
        score.max_combo,
        score.hit_counts[.MARVELOUS], score.hit_counts[.GOOD],
        score.hit_counts[.OK], score.hit_counts[.MISS],
        hit_errors.unstable_rate,
        hit_errors.early_mean, hit_errors.late_mean,
        judged, total, judged < total ? " (partial play!)" : "",
        game.time_rate, game.time_rate == 1 ? "" : " (!)",
        strings.builder_len(mods_text) > 0 ? strings.to_string(mods_text) : "none",
        strings.to_string(difficulty_changes),
    )

    if err := os.write_entire_file(path, transmute([]byte)content); err != os.General_Error.None {
        notify_warn("couldn't write results file: %v", err)
        return
    }
    log.infof("results written to %s", path)
}

rebind_screen_draw :: proc() {
    if !ui_component_visible(.REBIND_PROMPT) do return

    if game.input.rebinding_key != .NONE {
        r_check_and_bind_layer(.PLATFORM)
        r_push_transform(fullscreen_transform)
        r_draw_quad(&window.renderer.quad_geometry,
            vec2{0,0}, vec2{1,1},
            vec2{0,0}, vec2{1,1},
            with_alpha(color_black, 0.7))
            
        prompt := strings.concatenate({"Rebinding: ", rebindable_input_key_names[game.input.rebinding_key]}, context.temp_allocator)
        push_text(&window.renderer, prompt,
            pos = {window.rect.w / 2, window.rect.h / 2 - to_ui_scale(24)},
            size = to_ui_scale(32),
            color = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Middle)
        push_text(&window.renderer, "Press any key...",
            pos = {window.rect.w / 2, window.rect.h / 2 + to_ui_scale(24)},
            size = to_ui_scale(32),
            color = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Middle)
        
    }
    
    if app.mouse_input_mode == .REBINDING_MOUSE_PRIMARY {
        r_check_and_bind_layer(.PLATFORM)        
        r_push_transform(fullscreen_transform)
        r_draw_quad(&window.renderer.quad_geometry,
            vec2{0,0}, vec2{1,1},
            vec2{0,0}, vec2{1,1},
            with_alpha(color_black, 0.5))
            
        push_text(&window.renderer, "Waiting for primary mouse input...",
            pos = {window.rect.w / 2, window.rect.h / 2},
            size = to_ui_scale(16),
            color = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Middle)
        
    } else if app.mouse_input_mode == .REBINDING_MOUSE_SECONDARY {
        r_check_and_bind_layer(.PLATFORM)
        r_push_transform(fullscreen_transform)
        r_draw_quad(&window.renderer.quad_geometry,
            vec2{0,0}, vec2{1,1},
            vec2{0,0}, vec2{1,1},
            with_alpha(color_black, 0.5))

        push_text(&window.renderer, "Waiting for secondary mouse input...",
            pos = {window.rect.w / 2, window.rect.h / 2},
            size = to_ui_scale(16),
            color = {255, 255, 255, 150},
            align_h = .Center,
            align_v = .Middle)
    }
}

tournament_waiting_screen_draw :: proc() {
    if !ui_component_visible(.TOURNAMENT_WAITING_SCREEN) do return
    
    r_check_and_bind_layer(.UI)
    r_push_transform(fullscreen_transform)
    r_draw_quad(&window.renderer.quad_geometry,
        vec2{0,0}, vec2{1,1},
        vec2{0,0}, vec2{1,1},
        color_black)

    push_text(&window.renderer, "Waiting for map start...",
        pos = {window.rect.w / 2, window.rect.h / 2},
        size = to_ui_scale(32),
        color = {255, 255, 255, 255},
        align_h = .Center,
        align_v = .Middle)

    if game.user_config.osu_install_path == {} {
        push_text(&window.renderer, "user config is missing osu_install_path",
            pos = {window.rect.w / 2, window.rect.h / 2 + to_ui_scale(48)},
            size = to_ui_scale(24),
            color = {255, 32, 32, 255},
            align_h = .Center,
            align_v = .Middle)
    }
}

TOURNAMENT_COUNTDOWN_REVEAL_FADE_MS :: f64(500)

tournament_countdown_draw :: proc() {
    if !ui_component_visible(.TOURNAMENT_COUNTDOWN) do return

    seconds_left := max(1, int(math.ceil(-game.beatmap.music_time_ms / 1000)))
    backdrop_alpha := f32(clamp(-game.beatmap.music_time_ms / TOURNAMENT_COUNTDOWN_REVEAL_FADE_MS, 0, 1))

    r_check_and_bind_layer(.UI)
    r_push_transform(fullscreen_transform)
    r_draw_quad(&window.renderer.quad_geometry,
        vec2{0,0}, vec2{1,1},
        vec2{0,0}, vec2{1,1},
        with_alpha(color_black, backdrop_alpha))

    push_text(&window.renderer, fmt.tprintf("starting in %d...", seconds_left),
        pos = {window.rect.w / 2, window.rect.h / 2},
        size = to_ui_scale(32),
        color = {255, 255, 255, 255},
        align_h = .Center,
        align_v = .Middle)
}

GAME_MODE_SWITCH_PRE_FADE_S :: 0.1
GAME_MODE_SWITCH_POST_FADE_S :: 0.2

fade_transition_draw :: proc() {
    switch_elapsed := game.frame_clock_s - game.last_mode_switch_time
    if game.last_mode_switch_time > 0 &&
            switch_elapsed <= GAME_MODE_SWITCH_PRE_FADE_S + GAME_MODE_SWITCH_POST_FADE_S {
        fade_in := f32(switch_elapsed / GAME_MODE_SWITCH_PRE_FADE_S)
        fade_out := f32((GAME_MODE_SWITCH_PRE_FADE_S + GAME_MODE_SWITCH_POST_FADE_S -
            switch_elapsed) / GAME_MODE_SWITCH_POST_FADE_S)
        fade_alpha := clamp(min(fade_in, fade_out), 0, 1)

        r_bind_layer_and_push_current_state(.PLATFORM, transform = clipspace_transform)
        r_draw_quad(&window.renderer.quad_geometry, 
            {0, 0}, {1, 1}, {0, 0}, {1, 1},
            with_alpha(color_black, fade_alpha))
    }
}
