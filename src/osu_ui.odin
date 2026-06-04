package notosu

import "core:fmt"
import "core:math/ease"
import "core:math/linalg"

//////////////////////////////////////////////////////
// note(isak): hit error bar

HIT_ERROR_BAR_CAPACITY :: 96
HIT_ERROR_TICK_FADE_MS : f64 : 4000

HIT_COLOR_MISS :: color_red
HIT_COLOR_OK :: color_orange
HIT_COLOR_GOOD :: color_lime_green
HIT_COLOR_MARVELOUS :: color_light_blue

Hit_Error_Entry :: struct {
    error_ms:    f64, // click_time - object_time; negative = early, positive = late
    time_at:     f64, // music time when recorded, for fade-out
    judgement:   Judgement_Type,
}

// note(isak): simple ring buffer
Hit_Error_Bar :: struct {
    entries: [HIT_ERROR_BAR_CAPACITY]Hit_Error_Entry,
    next:    int,
    count:   int,
}

hit_error_bar_reset :: proc(hit_error_bar: ^Hit_Error_Bar) {
    hit_error_bar^ = {}
}

hit_error_bar_record :: proc(hit_error_bar: ^Hit_Error_Bar, error_ms: f64, judgement: Judgement_Type) {
    hit_error_bar.entries[hit_error_bar.next] = {
        error_ms    = error_ms,
        time_at = game.beatmap.music_time_ms,
        judgement   = judgement,
    }
    hit_error_bar.next  = (hit_error_bar.next + 1) % HIT_ERROR_BAR_CAPACITY
    hit_error_bar.count = min(hit_error_bar.count + 1, HIT_ERROR_BAR_CAPACITY)
}

hit_error_bar_draw :: proc(hit_error_bar: ^Hit_Error_Bar) {
    if game.mode != .PLAY do return
    tw := game.beatmap.timing_windows
    if tw.ok <= 0 do return

    bar_h := f32(26)
    cx := window.rect.w / 2
    cy := window.rect.h - bar_h / 2
    tick_h: f32 = 26
    
    px_per_ms := f32(1) * (window.rect.h / f32(720))
    bar_w := px_per_ms * f32(tw.ok) * 2
    
    now := game.beatmap.music_time_ms

    r_draw_rect(&window.renderer.quad_geometry, 
                {cx - bar_w / 2, cy - bar_h / 2, bar_w, bar_h}, with_alpha(color_black, 0.2))
    
    hit_error_zone(cx, cy, f32(tw.ok)        * px_per_ms, 6, with_alpha(HIT_COLOR_OK, 0.85))
    hit_error_zone(cx, cy, f32(tw.good)      * px_per_ms, 6, with_alpha(HIT_COLOR_GOOD, 0.85))
    hit_error_zone(cx, cy, f32(tw.marvelous) * px_per_ms, 6, with_alpha(HIT_COLOR_MARVELOUS, 0.85))

    // perfect-timing center line
    r_draw_rect(&window.renderer.quad_geometry, {cx - 1, cy - tick_h / 2, 2, tick_h}, color_white)

    sum, shown := 0.0, 0
    for i in 0 ..< hit_error_bar.count {
        e := hit_error_bar.entries[i]
        age := now - e.time_at
        if age < 0 || age > HIT_ERROR_TICK_FADE_MS do continue

        alpha := f32(1 - age / HIT_ERROR_TICK_FADE_MS)
        x := clamp(cx + f32(e.error_ms) * px_per_ms, cx - bar_w / 2, cx + bar_w)
        
        r_draw_rect(&window.renderer.quad_geometry, {x - 1, cy - tick_h / 2, 2, tick_h},
            with_alpha(hit_error_color(e.judgement), alpha))

        sum   += e.error_ms
        shown += 1
    }

    if shown > 0 {
        mean := sum / f64(shown)
        sign := mean >= 0 ? "+" : ""
        push_text(&window.renderer, fmt.tprintf("%s%.0f ms", sign, mean),
            pos     = {cx, cy - 20},
            size    = 14,
            color   = color_white,
            align_h = .Center,
            align_v = .Baseline)
    }
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
    timeline_hitbox := rect_from_points({0, window.rect.h - ui.hitbox_h_px}, {window.rect.w, window.rect.h})

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
        h_at_state_change := linalg.mix(ui.hitbox_h_px, ui.h_px, ease.ease(ui.ease, f32(ui.done_on_stage_change)))
        ui.display_h_px = linalg.mix(h_at_state_change, ui.hitbox_h_px, ease.ease(ui.ease, t / f32(ui.animation_time_s)))
    } else {
        h_at_state_change := linalg.mix(ui.h_px, ui.hitbox_h_px, ease.ease(ui.ease, f32(ui.done_on_stage_change)))
        ui.display_h_px = linalg.mix(h_at_state_change, ui.h_px, ease.ease(ui.ease, t / f32(ui.animation_time_s)))
    }
    return result
}

handle_and_render_timeline :: proc() {
    seek_to_fract: f64
    if ui_update_timeline(&game.ui_timeline, &seek_to_fract) {
        map_len_with_preempt := game.beatmap.length_ms + (-game.beatmap.start_time_ms)
        leadin_fract := -game.beatmap.start_time_ms / map_len_with_preempt
        
        if seek_to_fract < leadin_fract {
            game.beatmap.music_time_ms = game.beatmap.start_time_ms + seek_to_fract * map_len_with_preempt
        } else {
            seek_to_music_fract := (seek_to_fract - leadin_fract) * (1 / (1.0 - leadin_fract))
            
            seek_to_ms := seek_to_music_fract * sound_get_length_ms(&game.beatmap.music)
            beatmap_seek(&game.beatmap, seek_to_ms)
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
    
    map_len_with_preempt := game.beatmap.length_ms + (-game.beatmap.start_time_ms)
    map_time_with_preempt := game.beatmap.music_time_ms + (-game.beatmap.start_time_ms)
    
    beatmap_leadin_fract := f32((-game.beatmap.preempt_ms - game.beatmap.music_time_ms) / -game.beatmap.start_time_ms)
    beatmap_finish_fract := f32(map_time_with_preempt / map_len_with_preempt)
    
    render_timeline(&game.ui_timeline, beatmap_leadin_fract, beatmap_finish_fract)
}

render_timeline :: proc(ui: ^UI_Timeline, beatmap_leadin_fract, beatmap_finish_fract: f32) {
    r_push_transform(clipspace_transform)
    
    r_draw_layout_rect(&window.renderer.quad_geometry, {0, 1, 1, ui.display_h_px / window.rect.h}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.1))
    r_draw_layout_rect(&window.renderer.quad_geometry, {0, 1, beatmap_finish_fract, ui.display_h_px / window.rect.h}, 
                     .BOTTOM_LEFT, with_alpha(color_white, 0.4))
    if beatmap_leadin_fract > 0 {
        r_draw_layout_rect(&window.renderer.quad_geometry, {0, 1, beatmap_leadin_fract, ui.display_h_px / window.rect.h}, 
                         .BOTTOM_LEFT, with_alpha(color_lime_green, 0.2))
    }
}

//////////////////////////////////////////////////////
// note(isak): input display

input_display_draw :: proc() {
    render_input_key :: proc(key: Button_State, rect: Rect, lit_color: Color) {
        display_color := key.is_down ? lit_color : color_dark_gray
        r_draw_layout_rect(&window.renderer.quad_geometry, rect, .BOTTOM_RIGHT, display_color, builtin_texture(.WHITE))
    }

    render_input_key(game.input.k1, { window.rect.w, window.rect.h / 2 - 30, 30, 30 }, color_dim_yellow)
    render_input_key(game.input.k2, { window.rect.w, window.rect.h / 2,      30, 30 }, color_dim_yellow)

    lit_color := app.mouse_input_mode == .DOUBLE_MOUSE_INPUT ? color_sky_blue :  color_magenta
    render_input_key(game.input.m1, { window.rect.w, window.rect.h / 2 + 30, 30, 30 }, lit_color)
    render_input_key(game.input.m2, { window.rect.w, window.rect.h / 2 + 60, 30, 30 }, lit_color)

    if app.mouse_input_mode == .DOUBLE_MOUSE_INPUT {
        render_input_key(game.input.ms1, { window.rect.w, window.rect.h / 2 + 30, 30, 15 }, color_dim_orange)
        render_input_key(game.input.ms2, { window.rect.w, window.rect.h / 2 + 60, 30, 15 }, color_dim_orange)
    }
}
