package inso

import "core:fmt"

NOTIFY_RING_CAP    :: 512
NOTIFY_MSG_CAP     :: 256
NOTIFY_DISPLAY_S   :: 5.0
NOTIFY_FADE_S      :: 1.0
NOTIFY_FONT_SIZE   :: 20
NOTIFY_LINE_HEIGHT :: 20
NOTIFY_MARGIN_X    :: 10
NOTIFY_MARGIN_Y    :: 10
NOTIFY_BG_PADDING  :: 4
NOTIFY_BG_ALPHA    :: 140

Notify_Level :: enum {
    INFO,
    WARN,
    ERROR,
}

Notification :: struct {
    msg:    [NOTIFY_MSG_CAP]u8,
    len:    int,
    level:  Notify_Level,
    time_s: f64,
}

notify: struct {
    ring:         [NOTIFY_RING_CAP]Notification,
    head:         int,
    count:        int,
    hidden_count: int,
    show_all:     bool,
}

_notify_alpha :: 255
_notify_level_rgb := [Notify_Level][3]u8 {
    .INFO  = {220, 220, 220},
    .WARN  = {255, 200, 60},
    .ERROR = {255, 80,  80},
}

_notify_is_hidden :: proc() -> bool {
    return game.mode == .PLAY
}

// note(isak): i counts back from the newest entry
_notify_nth_newest :: proc(i: int) -> ^Notification {
    idx := ((notify.head - 1 - i) + NOTIFY_RING_CAP * 2) % NOTIFY_RING_CAP
    return &notify.ring[idx]
}

// note(isak): entries pushed while hidden start their display time when they first reach the screen
_notify_reveal_hidden :: proc() {
    now := time_s_since_beginning_of_program()
    for i in 0..<notify.hidden_count {
        _notify_nth_newest(i).time_s = now
    }
    notify.hidden_count = 0
}

_notify_push :: proc(level: Notify_Level, fmt_str: string, args: ..any) {
    entry := &notify.ring[notify.head]
    entry.level  = level
    entry.time_s = time_s_since_beginning_of_program()
    written := fmt.bprintf(entry.msg[:NOTIFY_MSG_CAP-1], fmt_str, ..args)
    entry.len = len(written)
    notify.head  = (notify.head + 1) % NOTIFY_RING_CAP
    notify.count = min(notify.count + 1, NOTIFY_RING_CAP)

    if _notify_is_hidden() {
        notify.hidden_count = min(notify.hidden_count + 1, NOTIFY_RING_CAP)
    }
}

notify_info  :: proc(fmt_str: string, args: ..any) { _notify_push(.INFO,  fmt_str, ..args) }
notify_warn  :: proc(fmt_str: string, args: ..any) { _notify_push(.WARN,  fmt_str, ..args) }
notify_error :: proc(fmt_str: string, args: ..any) { _notify_push(.ERROR, fmt_str, ..args) }

notify_draw_notifications :: proc(renderer: ^Renderer) {
    if _notify_is_hidden() do return
    _notify_reveal_hidden()

    now         := time_s_since_beginning_of_program()
    line_height := to_ui_scale(NOTIFY_LINE_HEIGHT)
    base_y      := window.rect.h - to_ui_scale(NOTIFY_MARGIN_Y)
    drawn       := 0

    for i in 0..<notify.count {
        entry := _notify_nth_newest(i)
        age   := now - entry.time_s

        alpha: u8
        if notify.show_all {
            alpha = _notify_alpha
        } else {
            if age >= NOTIFY_DISPLAY_S do continue
            fade_start := NOTIFY_DISPLAY_S - NOTIFY_FADE_S
            if age > fade_start {
                t     := (age - fade_start) / NOTIFY_FADE_S
                alpha  = u8(f64(_notify_alpha) * (1.0 - t))
            } else {
                alpha = _notify_alpha
            }
        }

        text := string(entry.msg[:entry.len])
        pos  := [2]f32{window.rect.w - to_ui_scale(NOTIFY_MARGIN_X), f32(base_y) - f32(drawn) * line_height}

        rgb   := _notify_level_rgb[entry.level]
        width: f32
        push_text(renderer, text,
            pos     = pos,
            size    = to_ui_scale(NOTIFY_FONT_SIZE),
            color   = {rgb[0], rgb[1], rgb[2], alpha},
            align_h = .Right,
            align_v = .Bottom,
            x_inc   = &width,
        )

        bg_padding := to_ui_scale(NOTIFY_BG_PADDING)
        bg := Rect{
            pos.x - width - bg_padding,
            pos.y - line_height,
            width + bg_padding * 2,
            line_height,
        }
        bg_alpha := u8(f64(NOTIFY_BG_ALPHA) * f64(alpha) / 255.0)
        r_draw_rect(&renderer.quad_geometry, bg, {0, 0, 0, bg_alpha})
        drawn += 1
    }
}
