package inso

import "core:container/queue"
import "core:math"

import sb "swap_buffer"

//////////////////////////////////////////////////////
// note(isak): hitobject logic core

hitobject_pos :: proc(hobj: ^Hitobject) -> vec2 {
    return hobj.pos + hobj.script_pos_translation
}

hitobject_tail_pos :: proc(hobj: ^Hitobject) -> vec2 {
    path := &game.beatmap.slider_paths[hobj.slider_path_index]
    tail_pos := (path.pos if hobj.slider_state.path_travel_count % 2 == 0 else path.end_pos) + hobj.script_pos_translation
    return tail_pos
}

hitobject_duration :: proc(hobj: ^Hitobject) -> (result: f64) {
    return hobj.end_time_ms - hobj.start_time_ms
}

hitobject_head_hittable :: proc(hobj: ^Hitobject, map_time: f64) -> bool {
    if hobj.phase != .PREEMPT && hobj.phase != .POSTEMPT do return false
    if hobj.type != .CIRCLE && hobj.type != .SLIDER do return false
    return map_time <= hobj.start_time_ms + game.beatmap.timing_windows.ok
}

// note(isak): horizontal offset for the notelock shake. visual only
hitobject_notelock_shake_offset :: proc(hobj: ^Hitobject, map_time: f64) -> vec2 {
    if hobj.notelock_shake_at_ms == 0 do return {}
    t := map_time - hobj.notelock_shake_at_ms
    if t < 0 || t >= NOTELOCK_SHAKE_DURATION_MS do return {}

    progress := t / NOTELOCK_SHAKE_DURATION_MS
    envelope := f32(1 - progress)
    phase := f32(2 * math.PI * NOTELOCK_SHAKE_OSCILLATIONS * progress)
    return {NOTELOCK_SHAKE_AMPLITUDE_OSUPX * envelope * math.sin(phase), 0}
}

hitobject_preempt_ms :: proc(hobj: ^Hitobject) -> f64 {
    return hobj.custom_preempt_ms if hobj.custom_preempt_ms != 0 else game.beatmap.preempt_ms
}

hitobject_radius_osupx :: proc(hobj: ^Hitobject) -> f32 {
    return hobj.custom_radius_osupx if hobj.custom_radius_osupx != 0 else game.beatmap.circle_radius_osupx
}

// note(isak): uses max_preempt_ms (max of global and all per-object preempts) to keep visible
// start times sorted for the iterator while still including custom AR objects on time.
hitobject_visible_start_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    start_time := hobj.start_time_ms
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER, .SPINNER: start_time -= max(game.beatmap.max_preempt_ms, game.beatmap.timing_windows.miss)
    }
    return start_time
}

// note(isak): exact time an object enters PREEMPT and becomes hittable. gates on the object's own
// preempt, unlike the visible-window scan above which must widen by max_preempt_ms to stay sorted.
// the miss window floors it so low-preempt objects are still hittable through their full miss window.
hitobject_activation_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    result = hobj.start_time_ms
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER, .SPINNER: result -= max(hitobject_preempt_ms(hobj), game.beatmap.timing_windows.miss)
    }
    return result
}

hitobject_visible_end_time :: proc(hobj: ^Hitobject) -> (result: f64) {
    end_time := hobj.end_time_ms + game.beatmap.timing_windows.ok
    hit_anim_len := hobj.custom_hit_animation_len_ms != 0 ? hobj.custom_hit_animation_len_ms : OSU_HIT_ANIMATION_LENGTH
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER: end_time += hit_anim_len
    }
    return end_time
}

DEFAULT_COMBO_COLORS := [4]Color {
    {240, 150, 0, 0xFF},
    {5, 240, 5, 0xFF},
    {5, 5, 240, 0xFF},
    {240, 5, 5, 0xFF},
}

hitobject_combo_color :: proc(hobj: ^Hitobject) -> (result: Color) {
    combo := hobj.combo_color_index if game.user_config.use_beatmap_combo_color_skips else hobj.combo_index

    if game.user_config.use_beatmap_skin {
        if game.active_map.num_combo_colors > 0 {
            result = game.active_map.combo_colors[combo % game.active_map.num_combo_colors]
        } else {
            result = DEFAULT_COMBO_COLORS[combo % len(DEFAULT_COMBO_COLORS)]
        }
        return result
    }
    else {
        if game.active_skin.num_combo_colors > 0 {
            result = game.active_skin.combo_colors[combo % game.active_skin.num_combo_colors]
        } else {
            result = DEFAULT_COMBO_COLORS[combo % len(DEFAULT_COMBO_COLORS)]
        }
        return result
    }
}

hitobject_set_preempt :: proc(hobj: ^Hitobject, preempt: f64) {
    hobj.custom_preempt_ms = preempt
    if preempt > game.beatmap.max_preempt_ms {
        game.beatmap.max_preempt_ms = preempt
    }
}

hitobject_emit_phase_transition :: proc(hobj: ^Hitobject, to: Hitobject_Phase) {
    sb.append(&game.beatmap.phase_transitions, Phase_Transition{hobj.index, hobj.phase, to})
    hobj.phase = to
}


// note(isak): osu stores timing point hitsound volume as a 0-100 percentage
timing_point_volume :: proc(timing_point: ^Timing_Point) -> f32 {
    return f32(timing_point.volume) / 100
}

// note(isak): 0 = auto
osu_sample_set_to_skin :: proc(osu_set: u8, timing_point: ^Timing_Point) -> Skin_Sample_Set {
    switch osu_set {
    case 1:  return .NORMAL
    case 2:  return .SOFT
    case 3:  return .DRUM
    case:    return timing_point.sample_set
    }
}

play_hit_hitsounds :: proc(timing_point: ^Timing_Point, normal_set, addition_set: Skin_Sample_Set, hitsounds: Hitsound_Flags) {
    volume := timing_point_volume(timing_point)
    sample_play(resolve_hitsound(normal_set, .HITNORMAL, timing_point.sample_index), volume)
    if .WHISTLE in hitsounds do sample_play(resolve_hitsound(addition_set, .HITWHISTLE, timing_point.sample_index), volume)
    if .FINISH  in hitsounds do sample_play(resolve_hitsound(addition_set, .HITFINISH,  timing_point.sample_index), volume)
    if .CLAP    in hitsounds do sample_play(resolve_hitsound(addition_set, .HITCLAP,    timing_point.sample_index), volume)
}

resolve_hitsound :: proc(sample_set: Skin_Sample_Set, hitsound_type: Skin_Hitsound_Type, sample_index: u32) -> ^Sample {
    skin_hitsound := &game.active_skin.hitsounds[sample_set][hitsound_type]
    if !game.user_config.use_beatmap_hitsounds do return skin_hitsound
    if game.active_mapset == nil || sample_index == 0 do return skin_hitsound

    key := Hitsound_Key{sample_set, hitsound_type, sample_index}
    if slot, found := game.active_mapset.hitsound_slot_by_key[key]; found {
        return queue.get_ptr(&game.active_mapset.samples, slot)
    }
    return skin_hitsound
}

hitobject_on_click :: proc(hobj: ^Hitobject, click_time: f64) -> (result: Judgement_Type) {
    time_error_ms: f64
    
    #partial switch hobj.type {
    case .CIRCLE, .SLIDER:
        time_error_ms = click_time - hobj.start_time_ms
        if abs(time_error_ms) < game.beatmap.timing_windows.marvelous {
            result = .MARVELOUS
        } else if abs(time_error_ms) < game.beatmap.timing_windows.good {
            result = .GOOD
        } else if abs(time_error_ms) < game.beatmap.timing_windows.ok {
            result = .OK
        } else if -game.beatmap.timing_windows.miss < time_error_ms && time_error_ms < 0 {
            // note(isak): if we're outside the timing window on the late side, the hitobject's timing window 
            // has already expired, even if the on_click goes through (because of a potentially long postempt)
            result = .MISS
        }
    }
    
    if result != .NONE {
        if hobj.type == .SLIDER {
            result = slider_on_click(hobj, result, time_error_ms)
        } else {
            result = judgement_new(hobj, result, time_error_ms)
            hobj.flags |= {.HAS_RESULT, .EXPIRED}
        }

        // note(isak): the error bar reads the committed judgement back so a filter-replaced
        // timing error shows what was actually scored
        committed := queue.get(&game.beatmap.judgements, hobj.judgement_index)
        hit_error_bar_add(&game.hit_error_bar, committed.time_error_ms, result)

        if result != .MISS {
            if hobj.type == .SLIDER {
                // note(isak): the head is edge 0 - its sound and sample sets come from edgeSounds/edgeSets
                slider_play_edge_hitsound(hobj, 0)
            } else {
                // todo(isak): circles don't yet honor the per-object hitSample addition set, only the timing point
                timing_point := &game.active_map.timing_points[hobj.hitsound_timing_point_index]
                play_hit_hitsounds(timing_point, timing_point.sample_set, timing_point.sample_set, hobj.hitsound_flags)
            }
        }
    }
    return result
}

process_hitobject_hittesting :: proc(visible_hobjs: []Hitobject, map_time: f64) {
    defer game.beatmap.auto_last_hit_time_ms = map_time

    if game.mode == .EDITOR && !game.paused {
        editor_auto_hit(visible_hobjs, map_time)
        return
    }

    if app.input_thread_active && game.mode == .PLAY {
        process_hittesting_event_walk(visible_hobjs, map_time)
        return
    }

    for valid_controller_press() {
        consume_controller_press()
        check_controller_press(visible_hobjs, map_time, game.input.mouse_pos)
    }
}

check_controller_press :: proc(visible_hobjs: []Hitobject, press_time: f64, cursor_osupx: vec2) {
    game.input.last_valid_press_at = press_time

    front, clicked: ^Hitobject
    for &hobj in visible_hobjs {
        if !hitobject_head_hittable(&hobj, press_time) do continue
        if front == nil do front = &hobj
        if point_in_circle(cursor_osupx, hitobject_pos(&hobj), hitobject_radius_osupx(&hobj)) {
            clicked = &hobj
            break
        }
    }

    if clicked == nil do return

    // note(isak): stable's notelock only blocks while a strictly earlier note is still hittable,
    // so simultaneous notes are hittable in any order
    if clicked != front && front.start_time_ms < clicked.start_time_ms {
        clicked.notelock_shake_at_ms = press_time
        return
    }

    judgement := hitobject_on_click(clicked, press_time)
    if judgement == .NONE {
        clicked.notelock_shake_at_ms = press_time
        return
    }

    #partial switch clicked.type {
    case .CIRCLE:
        hitobject_emit_phase_transition(clicked, .HIT)
        judgement_new_drawable(clicked)
    case .SLIDER:
        hitobject_emit_phase_transition(clicked, .HOLD)
    }
}

editor_auto_hit :: proc(visible_hobjs: []Hitobject, map_time: f64) {
    last_time := game.beatmap.auto_last_hit_time_ms
    for &hobj in visible_hobjs {
        if hobj.flags & {.HAS_RESULT, .EXPIRED} != {} do continue
        if !(last_time < hobj.start_time_ms && hobj.start_time_ms <= map_time) do continue

        if hitobject_on_click(&hobj, hobj.start_time_ms) == .NONE do continue

        #partial switch hobj.type {
        case .CIRCLE:
            hitobject_emit_phase_transition(&hobj, .HIT)
            judgement_new_drawable(&hobj)
        case .SLIDER:
            hitobject_emit_phase_transition(&hobj, .HOLD)
        }
    }
}

process_expiring_hitobjects :: proc(expiring_hitobjects: ^sb.Swap_Buffer(int)) {
    map_time := beatmap_music_time_ms(&game.beatmap)

    for hobj_index in expiring_hitobjects.current {
        hobj := &game.beatmap.hitobjects[hobj_index]

        if .EXPIRED in hobj.flags do continue
        
        expired: bool
        #partial switch hobj.type {
        case .SLIDER:
            expired = slider_process(hobj, map_time)
        case .SPINNER:
            expired = spinner_process_expiry(hobj, map_time)
        case:
            expired = hitcircle_process_expiry(hobj, map_time)
        }
        
        if !expired {
            sb.append_next(expiring_hitobjects, hobj_index)
        }
    }
    sb.swap(expiring_hitobjects)
}

// todo(isak): spinners are unsupported for now
spinner_process_expiry :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    if hobj.end_time_ms < map_time {
        hobj.flags &~= {.VISIBLE}
        hobj.flags |= {.EXPIRED}
        expired = true
    }
    return expired
}

hitcircle_process_expiry :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    end_time := hobj.end_time_ms + game.beatmap.timing_windows.ok
    if end_time < map_time {
        final := judgement_new(hobj, .MISS, end_time - hobj.end_time_ms)
        judgement_new_drawable(hobj)
        hitobject_emit_phase_transition(hobj, final == .MISS ? .MISS : .HIT)
        hobj.flags &~= {.VISIBLE}
        hobj.flags |= {.EXPIRED}
        expired = true
    }
    return expired
}

hitobject_reset_transient :: proc(hobj: ^Hitobject) {
    hitobject_clear_drawables(hobj)
    if hobj.type == .SLIDER do slider_reset_transient(hobj)

    hobj.phase = .NONE
    hobj.flags &~= {.VISIBLE, .HAS_RESULT, .EXPIRED}
    hobj.judgement_index = 0
    hobj.notelock_shake_at_ms = 0
}

build_followpoint_connections :: proc(beatmap: ^Beatmap) {
    prev := -1
    for &hobj, i in beatmap.hitobjects {
        if hobj.type == .SPINNER {
            prev = -1
            continue
        }
        if prev >= 0 && .NEW_COMBO not_in hobj.flags {
            from := &beatmap.hitobjects[prev]
            append(&beatmap.followpoint_connections, Followpoint_Connection{
                from_index            = prev,
                to_index              = i,
                visible_start_time_ms = from.end_time_ms - FOLLOWPOINT_PREEMPT_MS,
            })
        }
        prev = i
    }
}


//////////////////////////////////////////////////////
// note(isak): followpoint logic core

FOLLOWPOINT_PREEMPT_MS    :: f64(800)
FOLLOWPOINT_SPACING_OSUPX :: f32(32)  // distance between adjacent points along the line
FOLLOWPOINT_FADE_MS       :: f64(300) // per-point fade in/out ramp
FOLLOWPOINT_MOVE_MS       :: FOLLOWPOINT_PREEMPT_MS * 0.5 // lead-in travel/scale window
FOLLOWPOINT_LEAD_FRACTION :: f32(0.0) // each point eases in from this fraction behind its slot

followpoint_from_pos :: proc(hobj: ^Hitobject) -> vec2 {
    return hitobject_tail_pos(hobj) if hobj.type == .SLIDER else hitobject_pos(hobj)
}

followpoint_first_active :: proc(beatmap: ^Beatmap, map_time: f64) -> int {
    conns := beatmap.followpoint_connections
    for beatmap.followpoint_cursor < len(conns) &&
        beatmap.hitobjects[conns[beatmap.followpoint_cursor].to_index].start_time_ms + FOLLOWPOINT_FADE_MS < map_time {
        beatmap.followpoint_cursor += 1
    }
    return beatmap.followpoint_cursor
}

// note(isak): immediate-mode draw of one connection at the current time
followpoint_emit :: proc(beatmap: ^Beatmap, conn: ^Followpoint_Connection, map_time: f64) {
    from := &beatmap.hitobjects[conn.from_index]
    to   := &beatmap.hitobjects[conn.to_index]

    if map_time < conn.visible_start_time_ms || map_time > to.start_time_ms + FOLLOWPOINT_FADE_MS do return
    if .HIDDEN_BY_SCRIPT in from.flags || .HIDDEN_BY_SCRIPT in to.flags do return
    if .NO_FOLLOWPOINT_OUT in from.flags || .NO_FOLLOWPOINT_IN in to.flags do return

    metrics := game.active_skin.elements[.FOLLOWPOINT].metrics
    if metrics.x <= 0 do return // note(isak): no followpoint texture

    start_pos := followpoint_from_pos(from)
    end_pos   := hitobject_pos(to)
    delta     := end_pos - start_pos
    distance  := math.sqrt(delta.x*delta.x + delta.y*delta.y)
    if distance < FOLLOWPOINT_SPACING_OSUPX * 2 do return
    if distance > FOLLOWPOINT_SPACING_OSUPX * 512 do return // note(isak): too long distance

    start_time := from.end_time_ms
    duration   := to.start_time_ms - start_time
    if duration <= 0 do return

    frame_count := game.active_skin.elements[.FOLLOWPOINT].frame_count

    for d := FOLLOWPOINT_SPACING_OSUPX * 1.49; d < distance - FOLLOWPOINT_SPACING_OSUPX; d += FOLLOWPOINT_SPACING_OSUPX {
        fraction      := d / distance
        fade_out_time := start_time + f64(fraction) * duration
        fade_in_time  := fade_out_time - FOLLOWPOINT_PREEMPT_MS
        if map_time < fade_in_time || map_time > fade_out_time + FOLLOWPOINT_FADE_MS do continue

        fade_in  := clamp((map_time - fade_in_time) / FOLLOWPOINT_FADE_MS, 0, 1)
        fade_out := clamp((fade_out_time + FOLLOWPOINT_FADE_MS - map_time) / FOLLOWPOINT_FADE_MS, 0, 1)
        alpha    := f32(min(fade_in, fade_out))

        // todo(isak): unused leadin animation (like the osu default skin. not sure if this is versioned...)
        //move_t := tween_apply(.QUAD_OUT, f32(clamp((map_time - fade_in_time) / FOLLOWPOINT_MOVE_MS, 0, 1)))
        slot   := fraction + FOLLOWPOINT_LEAD_FRACTION // * (move_t - 1)
        scale  := f32(0.58)

        // note(isak): handle animation frames
        tex_override: u32
        frame_metrics := metrics
        if frame_count > 1 {
            progress := (map_time - fade_in_time) / FOLLOWPOINT_PREEMPT_MS
            frame    := clamp(int(progress * f64(frame_count)), 0, frame_count - 1)
            tex_override  = skin_frame_texture(.FOLLOWPOINT, frame)
            frame_metrics = skin_frame_metrics(.FOLLOWPOINT, frame)
        }

        point := Drawable{
            flags         = {.ACTIVE},
            element       = builtin_element_slot(.FOLLOWPOINT),
            layer         = layer_id(.HITOBJECTS),
            pos           = start_pos + delta * slot,
            size          = frame_metrics * scale,
            angle_rad     = math.atan2(delta.y, delta.x),
            anchor        = .CENTER,
            color         = with_alpha(color_white, alpha),
            tex           = tex_override,
            start_time_ms = map_time,
            end_time_ms   = map_time + 1, // note(isak): don't expire
        }
        render_drawable(&point, map_time)
    }
}
