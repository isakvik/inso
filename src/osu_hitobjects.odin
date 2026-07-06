package notosu

import "core:time"
import "core:log"
import "core:container/queue"
import "core:math"

import sb "swap_buffer"

//////////////////////////////////////////////////////
// note(isak): judgements

judgement_new :: proc(hobj: ^Hitobject, type: Judgement_Type, time_error_ms: f64) {
    time := beatmap_music_time_ms(&game.beatmap)
    hobj.judgement_index = int(game.beatmap.judgements.len)
    queue.append(&game.beatmap.judgements, Judgement{ type, time })
    
    lua_beatmap_on_judgement(hobj.index, type, time_error_ms)
}

judgement_new_drawable :: proc(hobj: ^Hitobject) {
    if game.mode == .EDITOR do return
    
    if hobj.judgement_index > 0 {
        judgement := queue.get(&game.beatmap.judgements, hobj.judgement_index)

        el_type: Element_Type
        switch judgement.result {
        case .MISS:      el_type = .JUDGEMENT_MISS
        case .OK:        el_type = .JUDGEMENT_OK
        case .GOOD:      el_type = .JUDGEMENT_GOOD
        case .MARVELOUS: el_type = .JUDGEMENT_MARVELOUS
        case .SLIDER_SMALL_SCOREPOINT:  el_type = .LIGHTING
        case .SLIDER_LARGE_SCOREPOINT:  el_type = .LIGHTING

        case .NONE, .COMBO_BREAK, .IGNORED_HIT, .SLIDER_SCOREPOINT_MISS, 
            .SLIDER_HEAD_MISS, .SLIDER_HEAD_OK, .SLIDER_HEAD_GOOD, .SLIDER_HEAD_MARVELOUS:
            return
        }

        pos := hitobject_pos(hobj)
        if hobj.type == .SLIDER {
            path := &game.beatmap.slider_paths[hobj.slider_path_index]
            pos = path.pos if hobj.slider_state.path_travel_count % 2 == 0 else path.end_pos
        }

        cs := hitobject_radius_osupx(hobj)
        element_scale := (cs * 2) / game.active_skin.elements[.HITCIRCLE].metrics
        skin_el := skin_element_for_type_table[el_type]
        
        vel := judgement.result == .MISS ? vec2{0, 10} : vec2{0, 0}
        
        drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
            flags         = {.ACTIVE},
            element       = builtin_element_slot(el_type),
            layer         = .HITOBJECTS,
            pos           = pos,
            size          = element_scale * game.active_skin.elements[skin_el].metrics,
            anchor        = .CENTER,
            color         = color_white,
            
            vel           = vel,
            
            start_time_ms = judgement.time,
            end_time_ms   = judgement.time + 600,
        })
    }
    
}

//////////////////////////////////////////////////////
// note(isak): hitobject logic core

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
        hit_error_bar_record(&game.hit_error_bar, time_error_ms, result)

        if hobj.type == .SLIDER {
            slider_on_click(hobj, result, time_error_ms)
        } else {
            judgement_new(hobj, result, time_error_ms)
            hobj.flags |= {.HIT, .EXPIRED}
        }

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

    // todo(isak): move input resolution to its own thread. only one resolved note per press for now
    for valid_controller_press() {
        game.input.last_valid_press_at = map_time
        consume_controller_press()

        front, clicked: ^Hitobject
        for &hobj in visible_hobjs {
            if !hitobject_head_hittable(&hobj, map_time) do continue
            if front == nil do front = &hobj
            if point_in_circle(game.input.mouse_pos, hitobject_pos(&hobj), hitobject_radius_osupx(&hobj)) {
                clicked = &hobj
                break
            }
        }

        if clicked == nil do continue

        if clicked != front {
            clicked.notelock_shake_at_ms = map_time
            continue
        }

        judgement := hitobject_on_click(clicked, map_time)
        if judgement == .NONE {
            clicked.notelock_shake_at_ms = map_time
            continue
        }

        #partial switch clicked.type {
        case .CIRCLE:
            hitobject_emit_phase_transition(clicked, .HIT)
            judgement_new_drawable(clicked)
        case .SLIDER:
            hitobject_emit_phase_transition(clicked, .HOLD)
        }
    }
}

editor_auto_hit :: proc(visible_hobjs: []Hitobject, map_time: f64) {
    last_time := game.beatmap.auto_last_hit_time_ms
    for &hobj in visible_hobjs {
        if hobj.flags & {.HIT, .EXPIRED} != {} do continue
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
        case:
            expired = hitcircle_process_expiry(hobj, map_time)
        }
        
        if !expired {
            sb.append_next(expiring_hitobjects, hobj_index)
        }
    }
    sb.swap(expiring_hitobjects)
}

hitcircle_process_expiry :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    end_time := hobj.end_time_ms + game.beatmap.timing_windows.ok
    if end_time < map_time {
        judgement_new(hobj, .MISS, end_time - hobj.end_time_ms)
        judgement_new_drawable(hobj)
        hitobject_emit_phase_transition(hobj, .MISS)
        hobj.flags &~= {.VISIBLE}
        hobj.flags |= {.EXPIRED}
        expired = true
    }
    return expired
}

// note(isak): the play path mutates object state forward-only (phase, expiry, drawables), so seeking backward
// leaves finished objects deleted. these rewind only the transient render/gameplay state; map data (combo,
// hitsounds) and baked geometry/timing stay, so the normal spawn logic re-evaluates the object from scratch.
hitobject_reset_transient :: proc(hobj: ^Hitobject) {
    hitobject_clear_drawables(hobj)
    if hobj.type == .SLIDER do slider_reset_transient(hobj)

    hobj.phase = .NONE
    hobj.flags &~= {.VISIBLE, .HIT, .EXPIRED}
    hobj.judgement_index = 0
    hobj.notelock_shake_at_ms = 0
}

slider_reset_transient :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state
    slider_stop_slide_sounds(slider)
    slider_clear_handles(hobj)

    slider.flags = {}
    slider.down_key = 0
    slider.checked_repeats_count = 0
    slider.checked_path_ticks_count = 0
    slider.hit_judgement_count = 0
    slider.tracked_timestamp_at = 0
    slider.contingency_window_scorepoint_count = 0
    slider.contingency_window_scorepoints = {}
    for &hit in slider.tick_hits do hit = false
}

allocate_deferred_activations :: proc(beatmap: ^Beatmap) {
    max_preempt := beatmap.preempt_ms
    count := 0
    for &hobj in beatmap.hitobjects {
        if hobj.custom_preempt_ms != 0 {
            count += 1
            if hobj.custom_preempt_ms > max_preempt do max_preempt = hobj.custom_preempt_ms
        }
    }
    beatmap.max_preempt_ms = max_preempt
    beatmap.deferred_activations = make([dynamic]Deferred_Activation, 0, count, memory.allocators[.MAPSET])
}

build_deferred_activations :: proc(beatmap: ^Beatmap) {
    for &hobj in beatmap.hitobjects {
        if hobj.custom_preempt_ms != 0 {
            append(&beatmap.deferred_activations, Deferred_Activation{hobj.index, hobj.start_time_ms - hobj.custom_preempt_ms})
            hobj.deferred_activation_index = len(beatmap.deferred_activations) // index+1
        }
    }
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
        move_t := tween_apply(.QUAD_OUT, f32(clamp((map_time - fade_in_time) / FOLLOWPOINT_MOVE_MS, 0, 1)))
        slot   := fraction + FOLLOWPOINT_LEAD_FRACTION * 1 //(move_t - 1)
        scale  := f32(0.58)

        // note(isak): handle animation frames
        tex_override: u32
        if frame_count > 1 {
            progress := (map_time - fade_in_time) / FOLLOWPOINT_PREEMPT_MS
            frame    := clamp(int(progress * f64(frame_count)), 0, frame_count - 1)
            tex_override = skin_frame_texture(.FOLLOWPOINT, frame)
        }

        point := Drawable{
            flags         = {.ACTIVE},
            element       = builtin_element_slot(.FOLLOWPOINT),
            layer         = .HITOBJECTS,
            pos           = start_pos + delta * slot,
            size          = metrics * scale,
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


//////////////////////////////////////////////////////
// note(isak): slider logic core

SLIDER_FOLLOW_CIRCLE_DEFAULT_RADIUS_MULT :: 2.4
SLIDER_FOLLOW_CIRCLE_POP_MS :: 200
SLIDER_TICK_POP_MS :: 150 // note(isak): how long an individual tick's scale/fade pop-in plays once its turn arrives
SLIDER_TICK_AT_SLIDEREND_CHECK_LENIENCY_MS :: 3 // note(isak) don't make ticks within n ms of the sliderend
SLIDER_END_LENIENCY_MS :: 36

// note(isak): osu's default sliderball framerate (no AnimationFramerate in skin.ini) is the frame count,
// so the animation loops once per second regardless of how many frames the skin ships
SLIDER_BALL_ANIMATION_LOOP_MS :: f64(1000)

// note(isak): the looping slide sound is attenuated below the section volume so it doesn't drown out hits
SLIDER_SLIDE_VOLUME :: f32(0.5)

slider_snake_out_factor :: proc(hobj: ^Hitobject) -> f64 {
    preempt_ms := hitobject_preempt_ms(hobj)
    snake_duration_ms := preempt_ms * (1.0/3.0)
    time_into_preempt  := beatmap_music_time_ms(&game.beatmap) - hobj.start_time_ms + preempt_ms
    return clamp(time_into_preempt / snake_duration_ms, 0, 1)
}

// note(isak): returns the map time at which the tick should begin its popin for the given span
slider_tick_popin_time :: proc(hobj: ^Hitobject, tick_i, span: int) -> f64 {
    slider := &hobj.slider_state
    heading_back := span % 2 == 1
    span_start := hobj.start_time_ms + f64(span) * slider.duration_ms

    path_time := f64(tick_i) * slider.tick_interval_ms // when the ball passes this tick, measured from the head
    travel_time := heading_back ? slider.duration_ms - path_time : path_time
    travel_fraction := travel_time / slider.duration_ms

    snake_finished_at := hitobject_preempt_ms(hobj) * (2.0/3.0)
    if span == 0 {
        return span_start - snake_finished_at + travel_fraction * slider.duration_ms / 2
    }
    return span_start - min(snake_finished_at, 100) + travel_fraction * slider.duration_ms / 2
}

slider_path_pos_at :: proc(hobj: ^Hitobject, map_time: f64) -> vec2 {
    path := &game.beatmap.slider_paths[hobj.slider_path_index]

    return path_calculate_position_at(hobj, map_time, path) + hobj.script_pos_translation
}

// note(isak): direction the sliderball is travelling at map_time, in the renderer's angle convention
// (0 points right, same as osu)
slider_ball_angle_at :: proc(hobj: ^Hitobject, map_time: f64) -> f32 {
    for dt := 2.0; dt <= 64; dt *= 2 {
        ahead  := slider_path_pos_at(hobj, map_time + dt)
        behind := slider_path_pos_at(hobj, map_time - dt)
        delta  := ahead - behind
        if delta.x != 0 || delta.y != 0 {
            return math.atan2(delta.y, delta.x)
        }
    }
    return 0
}

slider_process :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    slider := &hobj.slider_state

    // note(isak): one-time head miss check once the miss window has passed without a click
    if .HEAD_HIT in slider.flags {
        slider.flags |= {.HEAD_CHECKED}
    }
    else if .HEAD_CHECKED not_in slider.flags && map_time > hobj.start_time_ms + game.beatmap.timing_windows.ok {
        slider.flags |= {.HEAD_CHECKED}
        judgement_new(hobj, .SLIDER_HEAD_MISS, game.beatmap.timing_windows.ok)
    }

    if map_time >= hobj.start_time_ms && .FINALIZED not_in slider.flags {
        slider_update(hobj, map_time)
    }

    // note(isak): score the slider at end_time, then keep it alive through the fade-out tail before teardown
    if .HEAD_CHECKED in slider.flags && map_time > hobj.end_time_ms {
        if .FINALIZED not_in slider.flags {
            slider_finalize(hobj)
        }
        if map_time > hobj.end_time_ms + OSU_HIT_ANIMATION_LENGTH {
            slider_clear_handles(hobj)
            hobj.flags &~= {.VISIBLE}
            hobj.flags |= {.EXPIRED}
            expired = true
        }
    }
    return expired
}

// note(isak): slider head click is recorded, final judgement is deferred to slider_finalize
slider_on_click :: proc(hobj: ^Hitobject, result: Judgement_Type, timing_error_ms: f64) {
    slider := &hobj.slider_state

    if result != .MISS {
        slider.flags |= {.HEAD_HIT, .HEAD_CHECKED}
        slider_start_slide_sounds(hobj, &game.active_map.timing_points[hobj.hitsound_timing_point_index])
    } else {
        slider.flags |= {.HEAD_CHECKED}
    }
    
    slider.down_key = pressed_controller_key()

    slider_head_judgement := result
    #partial switch result {
    case .MISS: slider_head_judgement = .SLIDER_HEAD_MISS
    case .OK: slider_head_judgement = .SLIDER_HEAD_OK
    case .GOOD: slider_head_judgement = .SLIDER_HEAD_GOOD
    case .MARVELOUS: slider_head_judgement = .SLIDER_HEAD_MARVELOUS
    }
    judgement_new(hobj, slider_head_judgement, timing_error_ms)
}

slider_update :: proc(hobj: ^Hitobject, map_time: f64) {
    slider := &hobj.slider_state
    slider_time_at := (map_time - hobj.start_time_ms)
    
    ball_pos      := slider_path_pos_at(hobj, map_time)
    ball_radius   := hitobject_radius_osupx(hobj)
    follow_radius := ball_radius * slider.follow_circle_radius_mult

    // note(isak): if a specific key hit the head, the opposite key being pressed frees tracking to any key
    if slider.down_key != 0 && controller_key_pressed(slider.down_key == 1 ? 2 : 1) {
        slider.down_key = 0
    }
    key_held := controller_key_down(1) || controller_key_down(2) if
        slider.down_key == 0 else
        controller_key_down(slider.down_key)
    
    is_over_sliderball := point_in_circle(game.input.mouse_pos, ball_pos, ball_radius)
    is_over_sliderfollowcircle := point_in_circle(game.input.mouse_pos, ball_pos, follow_radius)

    if game.mode == .EDITOR {
        key_held = true
        is_over_sliderball = true
        is_over_sliderfollowcircle = true
    }

    was_tracking := .TRACKING in slider.flags
    is_tracking := key_held && is_over_sliderfollowcircle && (was_tracking || is_over_sliderball)

    // note(isak): we want the slider tracking to activate late even in the case the cursor isn't over the sliderball
    // in the circumstance that the head is clicked in time and the sliderball hasn't moved the length of the follow
    // circle radius. this mirrors the sliderhead leniency that's now present in lazer, and missing it is the cause of
    // a good few frustrating slidertick misses in stable
    if .HEAD_CONTINGENCY_WINDOW_PASSED not_in slider.flags {
        if .HEAD_HIT in slider.flags && is_over_sliderfollowcircle && key_held {
            is_tracking = true
        }

        osupx_per_ms := slider.distance / slider.duration_ms
        follow_radius_travel_time := f64(follow_radius) / osupx_per_ms
        
        if .HEAD_HIT in slider.flags || 
            slider_time_at >= min(game.beatmap.timing_windows.ok, follow_radius_travel_time) {
            slider.flags |= {.HEAD_CONTINGENCY_WINDOW_PASSED}
        }
    }
    
    if is_tracking {
        slider.flags |= {.TRACKING}
        if !was_tracking {
            slider.tracked_timestamp_at = map_time
        }
    } 
    else {
        slider.flags &= ~{.TRACKING}
    } 
    
    if is_tracking && map_time >= hobj.end_time_ms - SLIDER_END_LENIENCY_MS {
        slider.flags |= {.END_TRACKED}
    }

    // note(isak): "contingency" check in the case of a late hit where ticks/repeats have passed before the
    // end of the timing window. we store them and process them in order once the timing window has passed.
    if .HEAD_CONTINGENCY_WINDOW_PASSED in slider.flags && slider.contingency_window_scorepoint_count > 0 {
        if .HEAD_HIT in slider.flags {
            contingency_repeat_edge := 1
            contingency_tick_index := 1
            for i in 0..<slider.contingency_window_scorepoint_count {
                is_repeat := slider.contingency_window_scorepoints & {i} > {}
                if is_repeat {
                    judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
                    slider.hit_judgement_count += 1
                    slider_play_edge_hitsound(hobj, contingency_repeat_edge)
                    contingency_repeat_edge += 1
                } else {
                    judgement_new(hobj, .SLIDER_SMALL_SCOREPOINT, 0)
                    slider.hit_judgement_count += 1
                    slider.tick_hits[contingency_tick_index - 1] = true
                    // note(isak): contingency ticks fit inside the head timing window, so they're all
                    // on the first (forward) traversal
                    slider_play_tick_hitsound(hobj, 0, contingency_tick_index)
                    contingency_tick_index += 1
                }
            }
        } else {
            for i in 0..<slider.contingency_window_scorepoint_count {
                judgement_new(hobj, .SLIDER_SCOREPOINT_MISS, 0)
            }
        }
        slider.contingency_window_scorepoint_count = 0
        slider.contingency_window_scorepoints = {}
    }
    
    
    slider_has_next_path_judgement :: proc(hobj: ^Hitobject) -> bool {
        slider := &hobj.slider_state
        return slider.checked_repeats_count < slider.path_travel_count - 1 || 
            slider.checked_path_ticks_count < slider.tick_count
    }
    
    slider_is_path_judgement_due :: proc(hobj: ^Hitobject, map_time: f64) -> bool {
        slider := &hobj.slider_state
        slider_time_at := (map_time - hobj.start_time_ms)
        if slider_time_at >= f64(slider.checked_repeats_count + 1) * slider.duration_ms {
            return true
        }

        if slider.checked_path_ticks_count < slider.tick_count {
            heading_back := slider.checked_repeats_count % 2 == 1
            first_tick_time := heading_back ? slider.duration_ms - slider.tick_interval_ms * f64(slider.tick_count) : slider.tick_interval_ms
            slider_path_time_at := slider_time_at - f64(slider.checked_repeats_count) * slider.duration_ms
            if slider_path_time_at >= first_tick_time + f64(slider.checked_path_ticks_count) * slider.tick_interval_ms {
                return true
            }
        }
        return false
    }
    
    // note(isak): we process hit ticks in this loop, essentially "consuming" time by incrementing the checked counters
    // so that we can hit multiple ticks in the same frame if we're tracking. order of processing is important!
    for slider_has_next_path_judgement(hobj) && slider_is_path_judgement_due(hobj, map_time) {
        heading_back := slider.checked_repeats_count % 2 == 1
        first_tick_time := heading_back ? slider.duration_ms - slider.tick_interval_ms * f64(slider.tick_count) : slider.tick_interval_ms
        slider_path_time_at := slider_time_at - f64(slider.checked_repeats_count) * slider.duration_ms

        for slider.checked_path_ticks_count < slider.tick_count && slider_path_time_at >= first_tick_time + f64(slider.checked_path_ticks_count) * slider.tick_interval_ms {
            slider.checked_path_ticks_count += 1
            
            if is_tracking && .HEAD_CHECKED in slider.flags {
                judgement_new(hobj, .SLIDER_SMALL_SCOREPOINT, 0)
                slider.hit_judgement_count += 1
                tick_geometric := heading_back ? slider.tick_count + 1 - slider.checked_path_ticks_count : slider.checked_path_ticks_count
                slider.tick_hits[tick_geometric - 1] = true
                slider_play_tick_hitsound(hobj, slider.checked_repeats_count, slider.checked_path_ticks_count)
            } else if .HEAD_CONTINGENCY_WINDOW_PASSED not_in slider.flags {
                if slider.contingency_window_scorepoint_count >= 64 {
                    notify_warn("contingency window included more than 64 scorepoints: %d", slider.contingency_window_scorepoint_count)
                }
                slider.contingency_window_scorepoint_count += 1
            } else {
                judgement_new(hobj, .SLIDER_SCOREPOINT_MISS, 0)
            }
        }
        
        if slider_path_time_at >= slider.duration_ms && slider.checked_repeats_count < (slider.path_travel_count - 1) {
            slider.checked_repeats_count += 1
            slider.checked_path_ticks_count = 0
            // note(isak): ticks reappear each traversal, so clear hit state for the new pass
            for &hit in slider.tick_hits do hit = false

            if is_tracking && .HEAD_CHECKED in slider.flags  {
                judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
                slider.hit_judgement_count += 1
                slider_play_edge_hitsound(hobj, slider.checked_repeats_count)
            } else if .HEAD_CONTINGENCY_WINDOW_PASSED not_in slider.flags {
                if slider.contingency_window_scorepoint_count >= 64 {
                    log.warn("contingency window included more than 64 scorepoints!", slider.contingency_window_scorepoint_count)
                } else {
                    slider.contingency_window_scorepoints |= {slider.contingency_window_scorepoint_count}
                }
                slider.contingency_window_scorepoint_count += 1
            } else {
                judgement_new(hobj, .SLIDER_SCOREPOINT_MISS, 0)
            }
        }
    }
    
    should_slide := .HEAD_CHECKED in slider.flags && is_tracking && !game.paused
    if should_slide {
        if slider.slide_sound == {} {
            // note(isak): re-tracking mid-slider isn't a beat-snapped event, so the live timing point
            // is the right one - no hitsound leniency involved
            slider_start_slide_sounds(hobj, &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited])
        }
        slider_renew_slide_sounds(slider, map_time)
    } else if slider.slide_sound != {} || slider.whistle_sound != {} {
        slider_stop_slide_sounds(slider)
    }
}

slider_finalize :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state

    if .END_TRACKED in slider.flags {
        // note(isak): the tail is the last edge, index path_travel_count
        slider_play_edge_hitsound(hobj, slider.path_travel_count)
        judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
        slider.hit_judgement_count += 1
    }

    slider_stop_slide_sounds(slider)

    all_hit := slider.hit_judgement_count + (.HEAD_HIT in slider.flags ? 1 : 0)

    total_tick_count := slider.tick_count * slider.path_travel_count
    total   := max(total_tick_count + slider.path_travel_count + 1, 1) // include tail

    result: Judgement_Type
    ratio := f64(all_hit) / f64(total)
    switch {
    case ratio >= 1.0: result = .MARVELOUS
    case ratio >= 0.5: result = .GOOD
    case ratio > 0:    result = .OK
    case:              result = .MISS
    }

    judgement_new(hobj, result, 0)
    judgement_new_drawable(hobj)
    hitobject_emit_phase_transition(hobj, result == .MISS ? .MISS : .HIT)
    slider.flags |= {.FINALIZED}
}

// note(isak): tick_ordinal is 1-based in temporal order within the traversal
slider_play_tick_hitsound :: proc(hobj: ^Hitobject, traversal: int, tick_ordinal: int) {
    if game.paused || game.ui_timeline.dragging || game.ui_timeline.released do return

    slider := &hobj.slider_state
    tp_index := slider.tick_timing_point_indices[traversal * slider.tick_count + tick_ordinal - 1]
    timing_point := &game.active_map.timing_points[tp_index]
    sample_play(resolve_hitsound(timing_point.sample_set, .SLIDERTICK, timing_point.sample_index), timing_point_volume(timing_point))
}

// note(isak): play the hitsound for one slider edge (head/repeat/tail). normal hit comes from the edge's
// normal set, the whistle/finish/clap additions from its addition set. falls back to a plain hit from the
// timing point set if the slider has no parsed edge data.
slider_play_edge_hitsound :: proc(hobj: ^Hitobject, edge_index: int) {
    if game.paused || game.ui_timeline.dragging || game.ui_timeline.released do return

    if edge_index < 0 || edge_index >= len(hobj.slider_edge_hitsounds) {
        timing_point := &game.active_map.timing_points[hobj.hitsound_timing_point_index]
        play_hit_hitsounds(timing_point, timing_point.sample_set, timing_point.sample_set, {})
        return
    }

    edge := hobj.slider_edge_hitsounds[edge_index]
    timing_point := &game.active_map.timing_points[edge.timing_point_index]
    normal_set   := osu_sample_set_to_skin(edge.normal_set, timing_point)
    addition_set := osu_sample_set_to_skin(edge.addition_set, timing_point)
    play_hit_hitsounds(timing_point, normal_set, addition_set, edge.hitsound)
}

slider_start_slide_sounds :: proc(hobj: ^Hitobject, timing_point: ^Timing_Point) {
    slider := &hobj.slider_state
    sample_set := timing_point.sample_set
    volume := timing_point_volume(timing_point) * SLIDER_SLIDE_VOLUME

    if slider.slide_sound == {} {
        slider.slide_sound = game_sound_play(resolve_hitsound(sample_set, .SLIDERSLIDE, timing_point.sample_index),
            loop = true, volume = volume, expires_at = hobj.end_time_ms)
    }
    if slider.whistle_sound == {} && .WHISTLE in hobj.hitsound_flags {
        slider.whistle_sound = game_sound_play(resolve_hitsound(sample_set, .SLIDERWHISTLE, timing_point.sample_index),
            loop = true, volume = volume, expires_at = hobj.end_time_ms)
    }
    slider_renew_slide_sounds(slider, beatmap_music_time_ms(&game.beatmap))
}

slider_renew_slide_sounds :: proc(slider: ^Slider_State, map_time: f64) {
    expiry_at := map_time + 1000
    game_sound_renew_expiry(slider.slide_sound, expiry_at)
    game_sound_renew_expiry(slider.whistle_sound, expiry_at)
}

slider_stop_slide_sounds :: proc(slider: ^Slider_State) {
    game_sound_stop(slider.slide_sound)
    slider.slide_sound = {}
    game_sound_stop(slider.whistle_sound)
    slider.whistle_sound = {}
}

slider_sounds_clear_loop_handles :: proc() {
    for &hobj in game.beatmap.hitobjects {
        if hobj.type == .SLIDER {
            hobj.slider_state.slide_sound = {}
            hobj.slider_state.whistle_sound = {}
        }
    }
}
