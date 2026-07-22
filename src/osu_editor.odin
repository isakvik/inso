package inso

import "core:math"

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

// note(isak): the seek round-trip parks the playhead a sub-ms hair below the grid line it snapped
// to, so a grid line is anything within this window - keeps floor() from dropping a division and
// stalling forward scrubs (fraction-of-a-beat sensitive, so it only bit at high bpm)
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

editor_seek :: proc(beatmap: ^Beatmap, target: f64) {
    // note(isak): backward seeks must re-show expired objects and rewind the scheduled/fixed-update timeline
    seeking_backward := target < beatmap_music_time_ms(beatmap)
    if seeking_backward do beatmap_reset_object_state(beatmap)
    beatmap_seek(beatmap, target)
    if seeking_backward do beatmap_rewind_timeline(beatmap)
}
