package inso

import "core:log"
import "core:math"


SLIDER_FOLLOW_CIRCLE_DEFAULT_RADIUS_MULT :: 2.4
SLIDER_FOLLOW_CIRCLE_POP_MS :: 200
SLIDER_TICK_POP_MS :: 150 // note(isak): how long an individual tick's scale/fade pop-in plays once its turn arrives
SLIDER_TICK_AT_SLIDEREND_CHECK_LENIENCY_MS :: 3 // note(isak) don't make ticks within n ms of the sliderend
SLIDER_END_LENIENCY_MS :: 36

SLIDER_SLIDE_VOLUME :: f32(0.5)

// note(isak): the sliderball animates at up to 60fps, scaled down proportionally for sliders
// slower than 0.15 osu!px/ms (based on lazer's LegacySliderBall)
SLIDER_BALL_BASE_FRAME_MS :: f64(1000.0 / 60.0)
SLIDER_BALL_FULL_SPEED_VELOCITY :: f64(0.15) // osu!px per ms

slider_ball_frame_delay_ms :: proc(hobj: ^Hitobject) -> f64 {
    slider := &hobj.slider_state
    velocity := slider.distance / max(slider.duration_ms, 1)
    if velocity <= 0 do return SLIDER_BALL_BASE_FRAME_MS
    return max(SLIDER_BALL_FULL_SPEED_VELOCITY / velocity * SLIDER_BALL_BASE_FRAME_MS, SLIDER_BALL_BASE_FRAME_MS)
}


// note(isak): how far the body has grown out of the head during the approach, 0 to 1.
// 1 outright when snaking in is disabled, so dependent gfx (end circles, repeats) appear immediately
slider_snake_in_factor :: proc(hobj: ^Hitobject) -> f64 {
    if .SLIDER_SNAKE_IN not_in hobj.flags || !game.user_config.snaking_in_sliders_enabled {
        return 1
    }
    preempt_ms := hitobject_preempt_ms(hobj)
    snake_duration_ms := preempt_ms * (1.0/3.0)
    time_into_preempt  := beatmap_music_time_ms(&game.beatmap) - hobj.start_time_ms + preempt_ms
    return clamp(time_into_preempt / snake_duration_ms, 0, 1)
}

// note(isak): fraction of the path retracted behind the ball, 0 to 1; 0 until the final span starts.
// 0 outright when snaking out is disabled, so the body stays whole until it fades
slider_snake_out_factor :: proc(hobj: ^Hitobject) -> f64 {
    if .SLIDER_SNAKE_OUT not_in hobj.flags || !game.user_config.snaking_out_sliders_enabled {
        return 0
    }
    span_ms := max(hobj.slider_state.duration_ms, 1)
    final_span_start_ms := hobj.end_time_ms - span_ms
    return clamp((beatmap_music_time_ms(&game.beatmap) - final_span_start_ms) / span_ms, 0, 1)
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
        final_head := judgement_new(hobj, .SLIDER_HEAD_MISS, game.beatmap.timing_windows.ok)
        if final_head != .SLIDER_HEAD_MISS && final_head != .MISS {
            slider.flags |= {.HEAD_HIT}
        }
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

// note(isak): slider head click is recorded, final judgement is deferred to slider_finalize.
// the judgement commits before head state is set so the flags and slide sounds follow a
// filter-overwritten result; the return value is mapped back to circle-space for the caller
slider_on_click :: proc(hobj: ^Hitobject, result: Judgement_Type, timing_error_ms: f64) -> Judgement_Type {
    slider := &hobj.slider_state

    slider_head_judgement := result
    #partial switch result {
    case .MISS: slider_head_judgement = .SLIDER_HEAD_MISS
    case .OK: slider_head_judgement = .SLIDER_HEAD_OK
    case .GOOD: slider_head_judgement = .SLIDER_HEAD_GOOD
    case .MARVELOUS: slider_head_judgement = .SLIDER_HEAD_MARVELOUS
    }
    final := judgement_new(hobj, slider_head_judgement, timing_error_ms)

    if final != .SLIDER_HEAD_MISS && final != .MISS {
        slider.flags |= {.HEAD_HIT, .HEAD_CHECKED}
        slider_start_slide_sounds(hobj, &game.active_map.timing_points[hobj.hitsound_timing_point_index])
    } else {
        slider.flags |= {.HEAD_CHECKED}
    }

    slider.down_key = pressed_controller_key()

    #partial switch final {
    case .SLIDER_HEAD_MISS: return .MISS
    case .SLIDER_HEAD_OK: return .OK
    case .SLIDER_HEAD_GOOD: return .GOOD
    case .SLIDER_HEAD_MARVELOUS: return .MARVELOUS
    }
    return final
}

// note(isak): commits a scorepoint judgement and reports whether one actually landed - the lua
// filter can overturn it in either direction, so hit feedback keys off the committed result
slider_scorepoint_judge :: proc(hobj: ^Hitobject, intended: Judgement_Type) -> (hit: bool) {
    final := judgement_new(hobj, intended, 0)
    #partial switch final {
    case .SLIDER_SMALL_SCOREPOINT, .SLIDER_LARGE_SCOREPOINT:
        hobj.slider_state.hit_judgement_count += 1
        return true
    }
    return false
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
    
    // note(isak): for sliders shorter than twice the leniency, the end check moves up to the halfway point
    end_check_time := max(hobj.end_time_ms - SLIDER_END_LENIENCY_MS, (hobj.start_time_ms + hobj.end_time_ms) / 2)
    if is_tracking && map_time >= end_check_time {
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
                    if slider_scorepoint_judge(hobj, .SLIDER_LARGE_SCOREPOINT) {
                        slider_play_edge_hitsound(hobj, contingency_repeat_edge)
                    }
                    contingency_repeat_edge += 1
                } else {
                    if slider_scorepoint_judge(hobj, .SLIDER_SMALL_SCOREPOINT) {
                        slider.tick_hits[contingency_tick_index - 1] = true
                        // note(isak): contingency ticks fit inside the head timing window, so they're all
                        // on the first (forward) traversal
                        slider_play_tick_hitsound(hobj, 0, contingency_tick_index)
                    }
                    contingency_tick_index += 1
                }
            }
        } else {
            for i in 0..<slider.contingency_window_scorepoint_count {
                slider_scorepoint_judge(hobj, .SLIDER_SCOREPOINT_MISS)
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
                if slider_scorepoint_judge(hobj, .SLIDER_SMALL_SCOREPOINT) {
                    tick_geometric := heading_back ? slider.tick_count + 1 - slider.checked_path_ticks_count : slider.checked_path_ticks_count
                    slider.tick_hits[tick_geometric - 1] = true
                    slider_play_tick_hitsound(hobj, slider.checked_repeats_count, slider.checked_path_ticks_count)
                }
            } else if .HEAD_CONTINGENCY_WINDOW_PASSED not_in slider.flags {
                if slider.contingency_window_scorepoint_count >= 64 {
                    notify_warn("contingency window included more than 64 scorepoints: %d", slider.contingency_window_scorepoint_count)
                }
                slider.contingency_window_scorepoint_count += 1
            } else {
                slider_scorepoint_judge(hobj, .SLIDER_SCOREPOINT_MISS)
            }
        }
        
        if slider_path_time_at >= slider.duration_ms && slider.checked_repeats_count < (slider.path_travel_count - 1) {
            slider.checked_repeats_count += 1
            slider.checked_path_ticks_count = 0
            // note(isak): ticks reappear each traversal, so clear hit state for the new pass
            for &hit in slider.tick_hits do hit = false

            if is_tracking && .HEAD_CHECKED in slider.flags  {
                if slider_scorepoint_judge(hobj, .SLIDER_LARGE_SCOREPOINT) {
                    slider_play_edge_hitsound(hobj, slider.checked_repeats_count)
                }
            } else if .HEAD_CONTINGENCY_WINDOW_PASSED not_in slider.flags {
                if slider.contingency_window_scorepoint_count >= 64 {
                    log.warn("contingency window included more than 64 scorepoints!", slider.contingency_window_scorepoint_count)
                } else {
                    slider.contingency_window_scorepoints |= {slider.contingency_window_scorepoint_count}
                }
                slider.contingency_window_scorepoint_count += 1
            } else {
                slider_scorepoint_judge(hobj, .SLIDER_SCOREPOINT_MISS)
            }
        }
    }

    should_slide := .HEAD_CHECKED in slider.flags && is_tracking && !game.paused
    if should_slide {
        if slider.slide_sound == {} {
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
        if slider_scorepoint_judge(hobj, .SLIDER_LARGE_SCOREPOINT) {
            // note(isak): the tail is the last edge, index path_travel_count
            slider_play_edge_hitsound(hobj, slider.path_travel_count)
        }
    } else {
        slider_scorepoint_judge(hobj, .SLIDER_END_MISS)
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

    final := judgement_new(hobj, result, 0)
    judgement_new_drawable(hobj)
    hitobject_emit_phase_transition(hobj, final == .MISS ? .MISS : .HIT)
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
// normal set, the whistle/finish/clap additions from its addition set
slider_play_edge_hitsound :: proc(hobj: ^Hitobject, edge_index: int) {
    if game.paused || game.ui_timeline.dragging || game.ui_timeline.released do return

    if edge_index < 0 || edge_index >= len(hobj.slider_edge_hitsounds) {
        // note(isak): falls back to a plain hit from the timing point set
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
            loop = true, volume = volume, expires_at_ms = hobj.end_time_ms)
    }
    if slider.whistle_sound == {} && .WHISTLE in hobj.hitsound_flags {
        slider.whistle_sound = game_sound_play(resolve_hitsound(sample_set, .SLIDERWHISTLE, timing_point.sample_index),
            loop = true, volume = volume, expires_at_ms = hobj.end_time_ms)
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
