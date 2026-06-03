package notosu

import "core:fmt"

NOTIFY_RING_CAP    :: 512
NOTIFY_MSG_CAP     :: 256
NOTIFY_DISPLAY_S   :: 5.0
NOTIFY_FADE_S      :: 1.0
NOTIFY_FONT_SIZE   :: 20
NOTIFY_LINE_HEIGHT :: 20
NOTIFY_MARGIN_X    :: 10
NOTIFY_MARGIN_Y    :: 10

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
    ring:     [NOTIFY_RING_CAP]Notification,
    head:     int,
    count:    int,
    show_all: bool,
}

_notify_alpha :: 255
_notify_level_rgb := [Notify_Level][3]u8 {
    .INFO  = {220, 220, 220},
    .WARN  = {255, 200, 60},
    .ERROR = {255, 80,  80},
}

notify_push :: proc(level: Notify_Level, fmt_str: string, args: ..any) {
    entry := &notify.ring[notify.head]
    entry.level  = level
    entry.time_s = time_s_since_beginning_of_program()
    written := fmt.bprintf(entry.msg[:NOTIFY_MSG_CAP-1], fmt_str, ..args)
    entry.len = len(written)
    notify.head  = (notify.head + 1) % NOTIFY_RING_CAP
    notify.count = min(notify.count + 1, NOTIFY_RING_CAP)
}

notify_info  :: proc(fmt_str: string, args: ..any) { notify_push(.INFO,  fmt_str, ..args) }
notify_warn  :: proc(fmt_str: string, args: ..any) { notify_push(.WARN,  fmt_str, ..args) }
notify_error :: proc(fmt_str: string, args: ..any) { notify_push(.ERROR, fmt_str, ..args) }

notifications_draw :: proc(renderer: ^Renderer) {
    now    := time_s_since_beginning_of_program()
    base_y := window.rect.h - NOTIFY_MARGIN_Y
    drawn  := 0

    for i in 0..<notify.count {
        // walk ring newest-first
        idx   := ((notify.head - 1 - i) + NOTIFY_RING_CAP * 2) % NOTIFY_RING_CAP
        entry := &notify.ring[idx]
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

        rgb := _notify_level_rgb[entry.level]
        push_text(renderer, string(entry.msg[:entry.len]),
            pos     = {window.rect.w - NOTIFY_MARGIN_X, f32(base_y) - f32(drawn) * NOTIFY_LINE_HEIGHT},
            size    = NOTIFY_FONT_SIZE,
            color   = {rgb[0], rgb[1], rgb[2], alpha},
            align_h = .Right,
            align_v = .Bottom,
        )
        drawn += 1
    }
}
