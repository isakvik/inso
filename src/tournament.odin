package inso

// note(isak): a tournament client arms the map at startup - fully loaded, on_init already run,
// drawables and post passes registered - then parks it paused at an empty lead-in. the synchronized
// start is the cheapest operation available (a plain unpause), so every lan client agrees on the
// moment within receipt jitter. all the variable-cost work already happened at arm time.

TOURNAMENT_LEAD_IN_MS :: f64(1500)

tournament_arm_beatmap :: proc(beatmap: ^Beatmap) {
    beatmap_reset_object_state(beatmap)
    beatmap_pause(beatmap, true)

    sound_set_position_ms(&beatmap.music, 0)
    // seeded offset-behind so the master clock reads -lead_in on every box at the deadline;
    // each box's audio then starts its own universal_offset later.
    beatmap_set_time(beatmap, -TOURNAMENT_LEAD_IN_MS)

    game.tournament_waiting_to_start = true
    game.tournament_start_deadline_s = 0
}

// note(isak): delay_ms is slack for the network path so the packet lands on every box
// before it fires; the local RETURN fallback passes 0.
tournament_request_start :: proc(delay_ms: f64 = 0) {
    if !game.tournament_waiting_to_start do return
    game.tournament_start_deadline_s = game.frame_clock_s + delay_ms / 1000
}

tournament_update :: proc() {
    if !game.tournament_waiting_to_start do return
    if game.tournament_start_deadline_s <= 0 || game.frame_clock_s < game.tournament_start_deadline_s {
        return
    }

    // the unpause fires on the first frame past the deadline, and beatmap_on_update then adds this
    // frame's full dt. credit only the slice past the deadline, so every box lands on the same
    // timeline regardless of frame phase.
    overshoot_ms := (game.frame_clock_s - game.tournament_start_deadline_s) * 1000
    game.beatmap.music_time_ms += (overshoot_ms - game.dt) * f64(game.time_rate)

    game.tournament_waiting_to_start = false

    // note(isak): a plain unpause, NOT beatmap_pause - the map is parked at a negative lead-in, so the
    // audio must stay paused until beatmap_on_update counts the clock past zero and resumes it there.
    game.paused = false
    if lua_cares_about_event(.ON_PAUSE_CHANGE) {
        lua_beatmap_on_pause_change(false)
    }
}
