package notosu

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
    
    if lua_cares_about_event(.ON_JUDGEMENT) {
        lua_beatmap_on_judgement(hobj.index, type, time_error_ms)
    }
}

judgement_new_drawable :: proc(hobj: ^Hitobject) {
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

        case .NONE, .COMBO_BREAK, .IGNORED_HIT, .SLIDER_SCOREPOINT_MISS:
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

hitobject_on_click :: proc(hobj: ^Hitobject) -> (result: Judgement_Type) {
    // todo(isak): input timings should be threaded, should be more granular that way during heavy load
    click_time := beatmap_music_time_ms(&game.beatmap)
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
            slider_on_click(hobj)
        } else {
            judgement_new(hobj, result, time_error_ms)
            hobj.flags |= {.HIT, .EXPIRED}
        }

        timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
        sample_set := Skin_Sample_Set(timing_point.sample_set)
        
        // todo(isak): we don't handle custom sampleset timing sections, need to reserve some space and add indirection
        sample_play(&game.active_skin.hitsounds[sample_set][.HITNORMAL])
        
        if .WHISTLE in hobj.flags {
            sample_play(&game.active_skin.hitsounds[sample_set][.HITWHISTLE])
        }
        if .CLAP in hobj.flags {
            sample_play(&game.active_skin.hitsounds[sample_set][.HITCLAP])
        }
        if .FINISH in hobj.flags {
            sample_play(&game.active_skin.hitsounds[sample_set][.HITFINISH])
        }
    }
    return result
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

build_deferred_activations :: proc(beatmap: ^Beatmap) {
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
    for &hobj in beatmap.hitobjects {
        if hobj.custom_preempt_ms != 0 {
            append(&beatmap.deferred_activations, Deferred_Activation{hobj.index, hobj.start_time_ms - hobj.custom_preempt_ms})
            hobj.deferred_activation_index = len(beatmap.deferred_activations) // index+1
        }
    }
}


//////////////////////////////////////////////////////
// note(isak): slider logic core

SLIDER_FOLLOW_CIRCLE_RADIUS_MULT :: 2.4
SLIDER_TICK_AT_SLIDEREND_CHECK_LENIENCY_MS :: 3
SLIDER_END_LENIENCY_MS :: 36

slider_snake_factor :: proc(hobj: ^Hitobject) -> f64 {
    preempt_ms := hitobject_preempt_ms(hobj)
    snake_duration_ms := preempt_ms * (1.0/3.0)
    time_into_preempt  := beatmap_music_time_ms(&game.beatmap) - hobj.start_time_ms + preempt_ms
    return clamp(time_into_preempt / snake_duration_ms, 0, 1)
}

slider_process :: proc(hobj: ^Hitobject, map_time: f64) -> (expired: bool) {
    slider := &hobj.slider_state

    // note(isak): one-time head miss check once the miss window has passed without a click
    if .HEAD_HIT in slider.flags ||
        map_time > hobj.start_time_ms + game.beatmap.timing_windows.ok {
        slider.flags |= {.HEAD_CHECKED}
    }

    if map_time >= hobj.start_time_ms {
        slider_update(hobj, map_time)
    }

    // note(isak): we gotta process results (and the contingency) before we let the slider expire
    if .HEAD_CHECKED in slider.flags && map_time > hobj.end_time_ms {
        slider_expire(hobj)
        expired = true
    }
    return expired
}

// note(isak): slider head click is recorded, final judgement is deferred to slider_expire
slider_on_click :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state
    slider.flags |= {.HEAD_HIT, .HEAD_CHECKED}
    slider.down_key = pressed_controller_key()
    
    timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
    sample_set := Skin_Sample_Set(timing_point.sample_set)
    if slider.slide_sound == {} {
        slider.slide_sound = 
            game_sound_play(&game.active_skin.hitsounds[sample_set][.SLIDERSLIDE], loop = true, volume = 0.5)
    }
}


slider_path_pos_at :: proc(hobj: ^Hitobject, map_time: f64) -> vec2 {
    path := &game.beatmap.slider_paths[hobj.slider_path_index]

    return path_calculate_position_at(hobj, map_time, path)
}

// note(isak): direction the sliderball is travelling at map_time, in the renderer's angle convention
// (0 points right, matching osu!). taken as a central difference of the folded path position, growing
// the sample window until the ball has actually moved so slow sliders still resolve a heading.
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

slider_update :: proc(hobj: ^Hitobject, map_time: f64) {
    slider := &hobj.slider_state
    slider_time_at := (map_time - hobj.start_time_ms)
    
    ball_pos      := slider_path_pos_at(hobj, map_time)
    ball_radius   := hitobject_radius_osupx(hobj)
    follow_radius := ball_radius * SLIDER_FOLLOW_CIRCLE_RADIUS_MULT

    // note(isak): if a specific key hit the head, the opposite key being freshly pressed frees tracking to any key
    if slider.down_key != 0 && controller_key_pressed(slider.down_key == 1 ? 2 : 1) {
        slider.down_key = 0
    }
    key_held := slider.down_key == 0 \
        ? controller_key_down(1) || controller_key_down(2) \
        : controller_key_down(slider.down_key)
    
    is_over_sliderball := point_in_circle(game.input.mouse_pos, ball_pos, ball_radius)
    is_over_sliderfollowcircle := point_in_circle(game.input.mouse_pos, ball_pos, follow_radius)
    
    was_tracking := .TRACKING in slider.flags
    is_tracking := key_held && is_over_sliderfollowcircle && (was_tracking || is_over_sliderball)

    // note(isak): we want the slider tracking to activate late even in the case the cursor isn't over the sliderball
    // in the circumstance that the head is clicked in time and the sliderball hasn't moved the length of the follow
    // circle radius. this mirrors the hard-fought sliderhead leniency that's now present in lazer, but is the cause
    // of a good few frustrating slidertick misses in stable
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
    
    if is_tracking do slider.flags |= {.TRACKING}
    else do slider.flags &= ~{.TRACKING}
    
    if is_tracking && map_time >= hobj.end_time_ms - SLIDER_END_LENIENCY_MS {
        slider.flags |= {.END_TRACKED}
    }

    timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
    sample_set := Skin_Sample_Set(timing_point.sample_set)

    // note(isak): "contingency" check in the case of a late hit where ticks/repeats have passed before the
    // end of the timing window. we store them and process them in order once the timing window has passed.
    if .HEAD_CONTINGENCY_WINDOW_PASSED in slider.flags && slider.contingency_window_scorepoint_count > 0 {
        if .HEAD_HIT in slider.flags {
            has_repeat: bool
            for i in 0..<slider.contingency_window_scorepoint_count {
                is_repeat := slider.contingency_window_scorepoints & {i} > {}
                judgement_new(hobj, is_repeat ? .SLIDER_LARGE_SCOREPOINT : .SLIDER_SMALL_SCOREPOINT, 0)
                slider.hit_judgement_count += 1
                has_repeat = has_repeat || is_repeat
            }
            sample_play(&game.active_skin.hitsounds[sample_set][has_repeat ? .HITNORMAL : .SLIDERTICK])
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
        
        heading_back := slider.checked_repeats_count % 2 == 1
        first_tick_time := heading_back ? slider.duration_ms - slider.tick_interval_ms * f64(slider.tick_count) : slider.tick_interval_ms
        slider_path_time_at := slider_time_at - f64(slider.checked_repeats_count) * slider.duration_ms
        if slider_path_time_at >= first_tick_time + f64(slider.checked_path_ticks_count) * slider.tick_interval_ms {
            return true
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
                // todo(isak): hitsound volume!!!!
                sample_play(&game.active_skin.hitsounds[sample_set][.SLIDERTICK])
            } else if .HEAD_CONTINGENCY_WINDOW_PASSED not_in slider.flags {
                if slider.contingency_window_scorepoint_count >= 64 {
                    // note(isak): what kind of insane tick rate would even trigger this?
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
            
            if is_tracking && .HEAD_CHECKED in slider.flags  {
                judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
                slider.hit_judgement_count += 1
                // todo(isak): hitsound volume!! repeat hitsounds need to be parsed!!!
                sample_play(&game.active_skin.hitsounds[sample_set][.HITNORMAL])
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
    
    if .HEAD_CHECKED in slider.flags && slider.slide_sound == {} && is_tracking && !was_tracking {
        // todo(isak): hitsound volume!! sliderwhistle!!
        slider.slide_sound = 
            game_sound_play(&game.active_skin.hitsounds[sample_set][.SLIDERSLIDE], loop = true, volume = 0.5)
    } else if !is_tracking && slider.slide_sound != {} {
        game_sound_stop(slider.slide_sound)
        slider.slide_sound = {}
    }
}

slider_expire :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state

    if .END_TRACKED in slider.flags {
        // todo(isak): hitsound volume!! end hitsounds need to be parsed!!!
        timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_inherited]
        sample_set := Skin_Sample_Set(timing_point.sample_set)
        sample_play(&game.active_skin.hitsounds[sample_set][.HITNORMAL])
        judgement_new(hobj, .SLIDER_LARGE_SCOREPOINT, 0)
        slider.hit_judgement_count += 1
    }

    game_sound_stop(slider.slide_sound)
    slider.slide_sound = {}

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
    hobj.flags &~= {.VISIBLE}
    hobj.flags |= {.EXPIRED}
}
