package notosu

import "core:math/ease"
import "core:math/linalg"


UI_Timeline :: struct {
    h_px: f32,
    hitbox_h_px: f32,
    display_h_px: f32,

    dragging: bool,
    pause_on_release: bool,

    using Common: struct {
        ease: ease.Ease,
        animation_time: f64,
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
        animation_time = 0.35,
        ease = .Quintic_Out,
    }
}

// todo(isak): you can make a lot of this common for ui components, such as the hover state, and leave functionality
// to this method... need to rewrite a bit of the size handling then but it's not a problem
ui_update_timeline :: proc(ui: ^UI_Timeline) {
    timeline_hitbox := rect_from_points({0, window.rect.h - ui.hitbox_h_px}, {window.rect.w, window.rect.h})

    if !window.ui_hovered && is_pressed(mouse.buttons[.LEFT]) && point_in_rect(mouse.last_click_position[.LEFT], timeline_hitbox) {
        ui.dragging = true
        ui.pause_on_release = game.play_paused
    }

    change_state_on_release := false
    if ui.dragging {
        game.play_paused = true
        timeline_new_x := f64(clamp((mouse.pos.x + timeline_hitbox.x) / timeline_hitbox.w, 0, 1))

        cur_map := game.active_map
        map_len_with_preempt := cur_map.length_ms + cur_map.preempt_ms

        game.play_timer_ms = linalg.mix(0.0, map_len_with_preempt, timeline_new_x) - cur_map.preempt_ms
        cur_map.visible_hit_object_state = {}

        if !is_held(mouse.buttons[.LEFT]) {
            game.play_paused = ui.pause_on_release
            ui.dragging = false
            change_state_on_release = true
        }
    }

    ui.hover_state_change_timer += game.dt
    ui.hover_state_change_timer = min(ui.hover_state_change_timer, ui.animation_time)

    was_hovered := ui.hovered
    ui.hovered = point_in_rect(mouse.pos, timeline_hitbox)
    if (!ui.dragging && ui.hovered != was_hovered) || (change_state_on_release) {
        ui.done_on_stage_change = ui.hover_state_change_timer / ui.animation_time
        ui.hover_state_change_timer = 0
    }
    
    t := clamp(f32(ui.hover_state_change_timer), 0, f32(ui.animation_time))
    if ui.hovered || ui.dragging {
        h_at_state_change := linalg.mix(ui.hitbox_h_px, ui.h_px, ease.ease(ui.ease, f32(ui.done_on_stage_change)))
        ui.display_h_px = linalg.mix(h_at_state_change, ui.hitbox_h_px, ease.ease(ui.ease, t / f32(ui.animation_time)))
    } else {
        h_at_state_change := linalg.mix(ui.h_px, ui.hitbox_h_px, ease.ease(ui.ease, f32(ui.done_on_stage_change)))
        ui.display_h_px = linalg.mix(h_at_state_change, ui.h_px, ease.ease(ui.ease, t / f32(ui.animation_time)))
    }

}
