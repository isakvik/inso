package inso

import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"

//////////////////////////////////////////////////////
// note(isak): editor mode stuff

// note(isak): jumps to the nearest bookmark past the playhead in the given direction
editor_seek_bookmark :: proc(beatmap: ^Beatmap, direction: int) {
    bookmarks := game.active_map.bookmarks_ms
    eps := 1.0
    target: f64
    found: bool
    now := beatmap_music_time_ms(beatmap)
    if direction > 0 {
        for b in bookmarks do if b > now + eps {
            target, found = b, true
            break
        }
    } else {
        #reverse for b in bookmarks do if b < now - eps {
            target, found = b, true
            break
        }
    }
    if found do editor_seek(beatmap, target)
}

EDITOR_GRID_SNAP_MS :: 2.0

// note(isak): snaps the playhead to the beat-divisor grid
editor_scrub_steps :: proc(beatmap: ^Beatmap, steps: int) {
    timing_point := &game.active_map.timing_points[beatmap.current_timing_point_index_uninherited]
    division_ms := timing_point.beat_length / EDITOR_BEAT_DIVISOR

    now := beatmap_music_time_ms(beatmap)
    grid_pos := (now - timing_point.time) / division_ms

    nearest := math.round(grid_pos)
    on_grid_line := abs((timing_point.time + nearest * division_ms) - now) < EDITOR_GRID_SNAP_MS

    current_grid := nearest if on_grid_line else (math.floor(grid_pos) if steps > 0 else math.ceil(grid_pos))
    target_grid := current_grid + f64(steps)

    target := timing_point.time + target_grid * division_ms
    target = clamp(target, beatmap.start_time_ms, beatmap.length_ms)

    editor_seek(beatmap, target)
}

// note(isak): ctrl+c on an object in the osu editor yields "00:00:949 (1) - "; ctrl+v here jumps to it
editor_seek_to_clipboard_timestamp :: proc(beatmap: ^Beatmap) {
    clipboard := sdl.GetClipboardText()
    defer sdl.free(clipboard)

    target, found := parse_osu_timestamp_ms(string(cstring(clipboard)))
    if !found {
        notify_warn("no timestamp in clipboard")
        return
    }
    editor_seek(beatmap, clamp(target, beatmap.start_time_ms, beatmap.length_ms))
}

editor_copy_playhead_ms :: proc(beatmap: ^Beatmap) {
    stamp := fmt.ctprintf("%v", math.round(beatmap_music_time_ms(beatmap)))
    sdl.SetClipboardText(stamp)
    notify_info("copied to clipboard: %s", stamp)
}

editor_copy_playhead_timestamp :: proc(beatmap: ^Beatmap) {
    total_ms := int(math.round(max(beatmap_music_time_ms(beatmap), 0)))
    minutes := total_ms / 60_000
    seconds := total_ms / 1_000 % 60
    millis  := total_ms % 1_000

    stamp := fmt.ctprintf("%02d:%02d:%03d", minutes, seconds, millis)
    sdl.SetClipboardText(fmt.ctprintf("%s - ", stamp))
    notify_info("copied %s", stamp)
}

parse_osu_timestamp_ms :: proc(text: string) -> (timestamp_ms: f64, found: bool) {
    is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
    number :: proc(s: string) -> (value: int) {
        for i in 0 ..< len(s) do value = value*10 + int(s[i] - '0')
        return
    }

    for start in 0 ..< len(text) {
        if !is_digit(text[start]) do continue
        if start > 0 && is_digit(text[start - 1]) do continue

        minute_end := start
        for minute_end < len(text) && is_digit(text[minute_end]) do minute_end += 1

        rest := text[minute_end:]
        if len(rest) < 7 do return // ":ss:mmm" can't fit here or anywhere later
        if rest[0] != ':' || rest[3] != ':' do continue
        if !is_digit(rest[1]) || !is_digit(rest[2]) do continue
        if !is_digit(rest[4]) || !is_digit(rest[5]) || !is_digit(rest[6]) do continue
        if len(rest) > 7 && is_digit(rest[7]) do continue

        minutes := number(text[start:minute_end])
        seconds := number(rest[1:3])
        millis  := number(rest[4:7])
        return f64(minutes*60_000 + seconds*1_000 + millis), true
    }
    return
}

editor_seek :: proc(beatmap: ^Beatmap, target: f64) {
    // note(isak): backward seeks must reset expired objects and rewind the scheduled/fixed-update timeline
    seeking_backward := target < beatmap_music_time_ms(beatmap)
    if seeking_backward do beatmap_reset_object_state(beatmap)
    beatmap_seek(beatmap, target)
    if seeking_backward do beatmap_rewind_timeline(beatmap)
}
