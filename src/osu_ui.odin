package notosu

import "core:math/ease"
import "core:math/linalg"


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
    
    if !window.ui_hovered && is_pressed(mouse.buttons[.LEFT]) && point_in_rect(mouse.last_click_position[.LEFT], timeline_hitbox) {
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

        if !is_down(mouse.buttons[.LEFT]) {
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

handle_and_render_timeline :: proc() {
    seek_to_fract: f64
    if ui_update_timeline(&game.ui_timeline, &seek_to_fract) {
        map_len_with_preempt := game.beatmap.length_ms + (-game.beatmap.start_time_ms)
        leadin_fract := -game.beatmap.start_time_ms / map_len_with_preempt
        
        if seek_to_fract < leadin_fract {
            game.beatmap.music_time_ms = game.beatmap.start_time_ms + seek_to_fract * map_len_with_preempt
        } else {
            seek_to_music_fract := (seek_to_fract - leadin_fract) * (1 / (1.0 - leadin_fract))
            sound_set_position_fract(&game.beatmap.music, seek_to_music_fract)
            game.beatmap.music_time_ms = beatmap_music_position_interpolated_ms(&game.beatmap)
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

render_input_display :: proc() {
    r_push_transform(window.screenspace_transform)
    
    render_input_key :: proc(key: Button_State, rect: Rect) {
        display_color := key.is_down ? color_light_gray : color_dark_gray
        r_draw_layout_rect(&window.renderer.quad_geometry, rect, .BOTTOM_RIGHT, display_color, builtin_texture(.WHITE))
    }

    render_input_key(game.input.k1, { window.rect.w, window.rect.h / 2 - 30, 30, 30 })
    render_input_key(game.input.k2, { window.rect.w, window.rect.h / 2,      30, 30 })
    render_input_key(game.input.m1, { window.rect.w, window.rect.h / 2 + 30, 30, 30 })
    render_input_key(game.input.m2, { window.rect.w, window.rect.h / 2 + 60, 30, 30 })
}
