package inso

import "core:container/queue"
import "core:math"

//////////////////////////////////////////////////////
// note(isak): judgements

JUDGEMENT_DISPLAY_DURATION :: 1100
LIGHTING_DISPLAY_DURATION  :: 600

judgement_new :: proc(hobj: ^Hitobject, type: Judgement_Type, time_error_ms: f64) {
    time := beatmap_music_time_ms(&game.beatmap)
    hobj.judgement_index = int(game.beatmap.judgements.len)
    queue.append(&game.beatmap.judgements, Judgement{ type, time, time_error_ms, hobj.index })

    score_apply_judgement(hobj, type, time_error_ms)
    lua_beatmap_on_judgement(hobj.index, type, time_error_ms)
}

COMBOBREAK_SOUND_MIN_COMBO :: 20

score_apply_judgement :: proc(hobj: ^Hitobject, type: Judgement_Type, time_error_ms: f64) {
    score := &game.beatmap.score
    score.hit_counts[type] += 1

    if judgement_carries_hit_error(hobj.type, type) {
        errors := &score.hit_errors
        errors.sum += time_error_ms
        errors.sum_squares += time_error_ms * time_error_ms
        errors.count += 1
        if time_error_ms < 0 {
            errors.early_sum += time_error_ms
            errors.early_count += 1
        } else {
            errors.late_sum += time_error_ms
            errors.late_count += 1
        }
    }

    // note(isak): a slider's final MISS/OK/GOOD/MARVELOUS is its accuracy judgement only -
    // combo was already counted by its head, ticks, repeats and tail as they happened
    slider_aggregate := hobj.type == .SLIDER

    switch type {
    case .OK, .GOOD, .MARVELOUS:
        if !slider_aggregate do score_combo_increment(score)
    case .MISS:
        if !slider_aggregate do score_combo_break(score)
    case .SLIDER_HEAD_OK, .SLIDER_HEAD_GOOD, .SLIDER_HEAD_MARVELOUS,
         .SLIDER_SMALL_SCOREPOINT, .SLIDER_LARGE_SCOREPOINT:
        score_combo_increment(score)
    case .SLIDER_HEAD_MISS, .SLIDER_SCOREPOINT_MISS, .COMBO_BREAK:
        score_combo_break(score)
    case .NONE, .IGNORED_HIT, .SLIDER_END_MISS:
    }
}

// note(isak): slider aggregates and scorepoints carry no real timing error, so the hit error
// stats only sample circle hits and slider head hits
judgement_carries_hit_error :: proc(hobj_type: Hitobject_Type, result: Judgement_Type) -> bool {
    #partial switch result {
    case .SLIDER_HEAD_OK, .SLIDER_HEAD_GOOD, .SLIDER_HEAD_MARVELOUS:
        return true
    case .OK, .GOOD, .MARVELOUS:
        return hobj_type == .CIRCLE
    }
    return false
}

// note(isak): errors are signed, negative = early. early_mean/late_mean average the early and
// late hits separately, the way stable's results screen "Error: -a ms - +b ms" does
Hit_Error_Stats :: struct {
    mean: f64,
    early_mean: f64,
    late_mean: f64,
    unstable_rate: f64, // 10x the standard deviation
}

score_hit_error_stats :: proc() -> (stats: Hit_Error_Stats) {
    errors := &game.beatmap.score.hit_errors
    if errors.count == 0 do return {}

    stats.mean = errors.sum / f64(errors.count)
    stats.unstable_rate = 10 * math.sqrt(max(errors.sum_squares / f64(errors.count) - stats.mean*stats.mean, 0))
    if errors.early_count > 0 do stats.early_mean = errors.early_sum / f64(errors.early_count)
    if errors.late_count > 0  do stats.late_mean  = errors.late_sum / f64(errors.late_count)
    return stats
}

score_combo_increment :: proc(score: ^Score_State) {
    score.combo += 1
    score.max_combo = max(score.max_combo, score.combo)
}

score_combo_break :: proc(score: ^Score_State) {
    lost := score.combo
    score.combo = 0
    if lost == 0 do return

    scrubbing := game.paused || game.ui_timeline.dragging || game.ui_timeline.released
    if lost >= COMBOBREAK_SOUND_MIN_COMBO && !scrubbing {
        sample_play(&game.active_skin.combobreak)
    }
    lua_beatmap_on_combo_break(lost)
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

        case .NONE, .COMBO_BREAK, .IGNORED_HIT, .SLIDER_SCOREPOINT_MISS, .SLIDER_END_MISS,
            .SLIDER_HEAD_MISS, .SLIDER_HEAD_OK, .SLIDER_HEAD_GOOD, .SLIDER_HEAD_MARVELOUS:
            return
        }

        pos := hitobject_tail_pos(hobj) if hobj.type == .SLIDER else hitobject_pos(hobj)

        if .LAST_IN_COMBO in hobj.flags {
            el_type = judgement_resolve_combo_end_type(hobj, judgement.result, el_type)
        }

        cs := hitobject_radius_osupx(hobj)
        element_scale := (cs * 2) / SKIN_CIRCLE_REFERENCE_PX
        skin_el := skin_element_for_type_table[el_type]

        duration: f64 = el_type == .LIGHTING ? LIGHTING_DISPLAY_DURATION : JUDGEMENT_DISPLAY_DURATION

        drawable_new_expiring(&game.beatmap.judgement_expiring_gfx, {
            flags         = {.ACTIVE},
            element       = builtin_element_slot(el_type),
            layer         = .HITOBJECTS,
            pos           = pos,
            size          = element_scale * game.active_skin.elements[skin_el].metrics,
            anchor        = .CENTER,
            color         = color_white,

            start_time_ms = judgement.time,
            end_time_ms   = judgement.time + duration,
        })
    }
    
}

judgement_resolve_combo_end_type :: proc(hobj: ^Hitobject, result: Judgement_Type, plain: Element_Type) -> Element_Type {
    if result != .MARVELOUS && result != .GOOD do return plain

    has_good := false
    for i := hobj.index; i >= 0; i -= 1 {
        section_hobj := &game.beatmap.hitobjects[i]
        if section_hobj.type != .SPINNER {
            if section_hobj.judgement_index <= 0 do return plain
            switch queue.get(&game.beatmap.judgements, section_hobj.judgement_index).result {
            case .MARVELOUS:
            case .GOOD:
                has_good = true
            case .NONE, .MISS, .OK,
                .SLIDER_SMALL_SCOREPOINT, .SLIDER_LARGE_SCOREPOINT, .SLIDER_SCOREPOINT_MISS,
                .SLIDER_HEAD_MISS, .SLIDER_HEAD_OK, .SLIDER_HEAD_GOOD, .SLIDER_HEAD_MARVELOUS,
                .IGNORED_HIT, .COMBO_BREAK, .SLIDER_END_MISS:
                return plain
            }
        }
        if .NEW_COMBO in section_hobj.flags do break
    }

    if result == .GOOD do return .JUDGEMENT_GOOD_KATU
    return .JUDGEMENT_MARVELOUS_KATU if has_good else .JUDGEMENT_MARVELOUS_GEKI
}


score_judged_object_count :: proc(score: ^Score_State) -> int {
    return score.hit_counts[.MARVELOUS] + score.hit_counts[.GOOD] + score.hit_counts[.OK] + score.hit_counts[.MISS]
}

score_total_scoring_objects :: proc() -> int {
    total := 0
    for &hobj in game.beatmap.hitobjects {
        if hobj.type != .SPINNER do total += 1
    }
    return total
}

score_accuracy :: proc(score: ^Score_State) -> f64 {
    judged := score_judged_object_count(score)
    if judged == 0 do return 1
    numerator := 300*score.hit_counts[.MARVELOUS] + 100*score.hit_counts[.GOOD] + 50*score.hit_counts[.OK]
    return f64(numerator) / f64(300 * judged)
}
