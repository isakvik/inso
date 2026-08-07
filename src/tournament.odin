package inso

import "core:log"

// note(isak): a tournament client arms the map at startup - fully loaded, on_init already run,
// drawables and post passes registered - then parks it paused at an empty lead-in. the synchronized
// start is the cheapest operation available (a plain unpause), so every lan client agrees on the
// moment within receipt jitter. all the variable-cost work already happened at arm time.

TOURNAMENT_LEAD_IN_MS :: f64(3000) // span of the countdown

tournament_arm_beatmap :: proc(beatmap: ^Beatmap) {
    beatmap_reset_object_state(beatmap)
    beatmap_pause(beatmap, true)

    sound_set_position_ms(&beatmap.music, 0)
    beatmap_set_time(beatmap, -TOURNAMENT_LEAD_IN_MS)

    beatmap.music_clock_source = .AUDIO

    beatmap.wall_servo_error_ms = 0
    beatmap.wall_snap_cooldown_until_ms = 0
    sound_set_rate_trim(&beatmap.music, 0)

    game.tournament_waiting_to_start = true
    game.tournament_start_deadline_s = 0
}

// note(isak): delay_ms is wait time for the network path so the packet lands on every box
// before it fires; the local RETURN fallback passes 0.
tournament_request_start :: proc(delay_ms: f64 = 0) {
    if !game.tournament_waiting_to_start do return
    game.tournament_start_deadline_s = game.frame_clock_s + delay_ms / 1000
}

// note(isak): fired mid-frame from tournament_socket_poll, which runs before tournament_update and
// beatmap_on_update. same safe point the file-watcher reload uses
tournament_abort :: proc() {
    if game.tournament_waiting_to_start {
        game.tournament_start_deadline_s = 0
        notify_warn("tournament: scheduled start canceled by production")
        return
    }

    beatmap_open(game.beatmap.map_reference)
    tournament_arm_beatmap(&game.beatmap)
    notify_warn("tournament: map aborted by production")
}

tournament_update :: proc() {
    if !game.tournament_waiting_to_start do return
    if game.tournament_start_deadline_s <= 0 || game.frame_clock_s < game.tournament_start_deadline_s {
        return
    }

    beatmap := &game.beatmap
    overshoot_ms := (game.frame_clock_s - game.tournament_start_deadline_s) * 1000
    beatmap.music_clock_source        = .WALL
    beatmap.wall_anchor_music_time_ms = beatmap.music_time_ms + overshoot_ms
    beatmap.wall_anchor_tsc           = game.frame_clock_tsc

    game.tournament_waiting_to_start = false

    // note(isak): a plain unpause, NOT beatmap_pause - the map is parked at a negative lead-in, so the
    // audio must stay paused until beatmap_on_update counts the clock past zero and resumes it there.
    game.paused = false
    if lua_cares_about_event(.ON_PAUSE_CHANGE) {
        lua_beatmap_on_pause_change(false)
    }
}

TOURNAMENT_SERVO_MAX_RATE_TRIM :: 0.005 // ~8.6 cents of pitch, should be imperceptible
TOURNAMENT_SERVO_FULL_TRIM_AT_MS :: 10.0
TOURNAMENT_SERVO_SMOOTH_HALF_LIFE_MS :: 200.0
TOURNAMENT_SERVO_SNAP_MS :: 25.0
TOURNAMENT_SERVO_SNAP_COOLDOWN_MS :: 250.0

// note(isak): converge audio towards wall clock time
tournament_audio_servo :: proc(beatmap: ^Beatmap) {
    if !audio.ready || beatmap.music_time_ms < 0 || sound_is_finished(&beatmap.music) {
        beatmap.wall_servo_error_ms = 0
        sound_set_rate_trim(&beatmap.music, 0)
        return
    }

    audio_behind_ms := beatmap.music_time_ms - sound_get_audible_position_ms(&beatmap.music)
    beatmap.wall_servo_error_ms = damp_continuously(beatmap.wall_servo_error_ms, audio_behind_ms,
        TOURNAMENT_SERVO_SMOOTH_HALF_LIFE_MS, game.dt)

    // note(isak): seek the audio onto the clock if we're beyond the snap threshold
    if abs(beatmap.wall_servo_error_ms) > TOURNAMENT_SERVO_SNAP_MS &&
       beatmap.music_time_ms >= beatmap.wall_snap_cooldown_until_ms {
        log.warnf("tournament: servo error %.0fms is beyond rate recovery, snapping audio to the clock",
            beatmap.wall_servo_error_ms)
        sound_set_position_ms(&beatmap.music, beatmap.music_time_ms)
        beatmap.wall_servo_error_ms = 0
        beatmap.wall_snap_cooldown_until_ms = beatmap.music_time_ms + TOURNAMENT_SERVO_SNAP_COOLDOWN_MS
        sound_set_rate_trim(&beatmap.music, 0)
        return
    }

    trim := clamp(beatmap.wall_servo_error_ms / TOURNAMENT_SERVO_FULL_TRIM_AT_MS, -1, 1) * TOURNAMENT_SERVO_MAX_RATE_TRIM
    sound_set_rate_trim(&beatmap.music, trim)
}
