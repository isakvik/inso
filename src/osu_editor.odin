package notosu

import "core:math"

//////////////////////////////////////////////////////
// note(isak): editor mode stuff

// note(isak): jumps to the nearest bookmark strictly past the playhead in the given direction
editor_seek_bookmark :: proc(beatmap: ^Beatmap, direction: int) {
    bookmarks := game.active_map.bookmarks_ms
    eps := 1.0
    target: f64
    found: bool
    if direction > 0 {
        for b in bookmarks do if b > beatmap.music_time_ms + eps {
            target, found = b, true
            break
        }
    } else {
        #reverse for b in bookmarks do if b < beatmap.music_time_ms - eps {
            target, found = b, true
            break
        }
    }
    if found do editor_seek(beatmap, target)
}

// note(isak): snaps the playhead to the beat-divisor grid
editor_scrub_steps :: proc(beatmap: ^Beatmap, steps: int) {
    timing_point := &game.active_map.timing_points[beatmap.current_timing_point_index_uninherited]
    division_ms := timing_point.beat_length / EDITOR_BEAT_DIVISOR

    grid_pos := (beatmap.music_time_ms - timing_point.time) / division_ms
    eps := 1e-6
    target_grid: f64
    if steps > 0 {
        target_grid = math.floor(grid_pos + eps) + f64(steps)
    } else {
        target_grid = math.floor(grid_pos - eps) + f64(steps)
    }

    target := timing_point.time + target_grid * division_ms - f64(game.user_config.universal_offset_ms)
    target = clamp(target, beatmap.start_time_ms, beatmap.length_ms)

    editor_seek(beatmap, target)
}

editor_seek :: proc(beatmap: ^Beatmap, target: f64) {
    // note(isak): backward seeks must re-show expired objects and rewind the scheduled/fixed-update timeline
    seeking_backward := target < beatmap.music_time_ms
    if seeking_backward do beatmap_reset_object_state(beatmap)
    beatmap_seek(beatmap, target)
    if seeking_backward do beatmap_rewind_timeline(beatmap)
}
