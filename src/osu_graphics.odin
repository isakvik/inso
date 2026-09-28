package inso

import "vendor:wasm/WebGL"
import "base:runtime"
import "base:intrinsics"
import q "core:container/queue"
import "core:math"
import sb "swap_buffer"
import "slotmap"
import "core:slice"


// note(isak): texture id lookup table for skin elements
skin_element_for_type_table := #partial #sparse [Element_Type]Skin_Element_Type{
    .HIT_CIRCLE         = .HITCIRCLE,
    .HIT_CIRCLE_OVERLAY = .HITCIRCLE_OVERLAY,
    .APPROACH_CIRCLE    = .APPROACHCIRCLE,
    .COMBO_NUMBER       = .COMBO_1,
    .LIGHTING           = .LIGHTING,

    .SLIDER_BALL          = .SLIDER_BALL,
    .SLIDER_FOLLOW_CIRCLE = .SLIDER_FOLLOW_CIRCLE,
    .SLIDER_REPEAT        = .SLIDER_REPEAT,
    .SLIDER_TICK          = .SLIDER_TICK,
    .SLIDER_END           = .SLIDER_END,
    .SLIDER_END_OVERLAY   = .SLIDER_END_OVERLAY,

    .FOLLOWPOINT          = .FOLLOWPOINT,

    .JUDGEMENT_MISS      = .HIT0,
    .JUDGEMENT_OK        = .HIT50,
    .JUDGEMENT_GOOD      = .HIT100,
    .JUDGEMENT_MARVELOUS = .HIT300,
    .JUDGEMENT_GOOD_KATU      = .HIT100K,
    .JUDGEMENT_MARVELOUS_KATU = .HIT300K,
    .JUDGEMENT_MARVELOUS_GEKI = .HIT300G,

    .CLICKED_HIT_CIRCLE = .HITCIRCLE,
    .CLICKED_HIT_CIRCLE_OVERLAY = .HITCIRCLE_OVERLAY,
    .FINISHED_SLIDER_END_CIRCLE = .SLIDER_END,
    .FINISHED_SLIDER_END_CIRCLE_OVERLAY = .SLIDER_END_OVERLAY,

    .SLIDER_START_CIRCLE                 = .SLIDER_START_CIRCLE,
    .SLIDER_START_CIRCLE_OVERLAY         = .SLIDER_START_CIRCLE_OVERLAY,
    .CLICKED_SLIDER_START_CIRCLE         = .SLIDER_START_CIRCLE,
    .CLICKED_SLIDER_START_CIRCLE_OVERLAY = .SLIDER_START_CIRCLE_OVERLAY,
}

// note(isak): osu draws skin images at their native size scaled by hitcircle_diameter/128 (combo
// numbers use a /160 reference), so an off-reference image renders proportionally smaller or larger
// instead of being stretched to the circle. metrics already account for @2x images
SKIN_CIRCLE_REFERENCE_PX :: f32(128)
SKIN_NUMBER_REFERENCE_PX :: f32(160)

skin_element_size_radius_units :: proc(el_type: Element_Type) -> vec2 {
    skin_el := skin_effective_element(game.active_skin, skin_element_for_type_table[el_type])
    metrics := game.active_skin.elements[skin_el].metrics
    if metrics.x == 0 do return {2, 2}
    return metrics * (2.0 / SKIN_CIRCLE_REFERENCE_PX)
}


create_default_elements :: proc(elements: ^q.Queue(Element), anims: ^q.Queue(Animation), lists: ^q.Queue(Animation_List)) {
    q.reserve(elements, len(Element_Type))
    elements.len += len(Element_Type)
    build_default_elements(elements, anims, lists)
}

build_default_elements :: proc(elements: ^q.Queue(Element), anims: ^q.Queue(Animation), lists: ^q.Queue(Animation_List)) {
    for el_type in Element_Type {
        elements.data[el_type] = {}
    }

    for el_type in Element_Type {
        elements.data[el_type].type = el_type
        elements.data[el_type].tex = 
            skin_texture(skin_effective_element(game.active_skin, skin_element_for_type_table[el_type]))
    }

    for digit in 0..<10 {
        elements.data[builtin_element_slot(Element_Type(int(Element_Type.COMBO_DIGIT_0) + digit))].tex =
            skin_texture(Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digit))
    }

    elements.data[builtin_element_slot(.HIT_CIRCLE)] = {
        tex = skin_texture(.HITCIRCLE),
        flags = {.USE_COMBO_COLOR}
    }

    elements.data[builtin_element_slot(.SLIDER_START_CIRCLE)].flags = {.USE_COMBO_COLOR}
    
    elements.data[builtin_element_slot(.APPROACH_CIRCLE)] = {
        tex = skin_texture(.APPROACHCIRCLE),
        flags = {.USE_COMBO_COLOR},

        animation_list = animation_new(anims, lists, Animation_Scale{
            start_time = 0,
            end_time = 1,
            start_scale = {4, 4},
            end_scale = {1, 1}
        })
    }
    
    judgement_fade_in_end    :: 120.0
    judgement_fade_out_start :: 500.0

    judgement_fade_in := Animation_Alpha{
        start_time  = 0, end_time  = judgement_fade_in_end,
        start_alpha = 0, end_alpha = 1,
    }
    judgement_fade_out := Animation_Alpha{
        start_time  = judgement_fade_out_start, end_time = JUDGEMENT_DISPLAY_DURATION,
        start_alpha = 1, end_alpha = 0,
    }

    default_anim_judgement := animation_new_in_domain(anims, lists, .MILLISECONDS,
        Animation_Scale{
            start_time  = 0, end_time = judgement_fade_in_end * 0.8,
            start_scale = {0.6, 0.6}, end_scale = {1.1, 1.1},
        },
        Animation_Scale{
            start_time  = judgement_fade_in_end * 0.8, end_time = judgement_fade_in_end * 1.2,
            start_scale = {1.1, 1.1}, end_scale = {0.9, 0.9},
        },
        Animation_Scale{
            start_time  = judgement_fade_in_end * 1.2, end_time = judgement_fade_in_end * 1.4,
            start_scale = {0.9, 0.9}, end_scale = {1.0, 1.0},
        },
        judgement_fade_in,
        judgement_fade_out,
    )
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS)].animation_list = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_GOOD)].animation_list      = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_OK)].animation_list        = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_GOOD_KATU)].animation_list      = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS_KATU)].animation_list = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS_GEKI)].animation_list = default_anim_judgement

    elements.data[builtin_element_slot(.JUDGEMENT_MISS)].animation_list = animation_new_in_domain(anims, lists, .MILLISECONDS,
        Animation_Scale{
            start_time  = 0, end_time = judgement_fade_in_end,
            start_scale = {2, 2}, end_scale = {1, 1},
        },
        Animation_Translate{
            tween = .CUBIC_IN,
            start_time = 0, end_time = JUDGEMENT_DISPLAY_DURATION,
            start_pos = {0, -5}, end_pos = {0, 40},
        },
        judgement_fade_in,
        judgement_fade_out,
    )

    judgement_types := [?]Element_Type{
        .JUDGEMENT_MISS, .JUDGEMENT_OK, .JUDGEMENT_GOOD, .JUDGEMENT_MARVELOUS,
        .JUDGEMENT_GOOD_KATU, .JUDGEMENT_MARVELOUS_KATU, .JUDGEMENT_MARVELOUS_GEKI,
    }
    for el_type in judgement_types {
        skin_el     := skin_element_for_type_table[el_type]
        frame_count := game.active_skin.elements[skin_el].frame_count
        if frame_count <= 1 do continue
        
        // note(isak): these are 60fps animations. i don't think i've seen anything else for these
        frame_ms :: 1000.0 / 60

        frames := make([]Animation, 2 + frame_count, context.temp_allocator)
        for frame in 0..<frame_count {
            frames[frame] = Animation_Texture{
                start_time = f64(frame)     * frame_ms,
                end_time   = f64(frame + 1) * frame_ms,
                texture_id = skin_frame_texture(skin_el, frame),
            }
        }
        frames[frame_count]     = judgement_fade_in
        frames[frame_count + 1] = judgement_fade_out
        elements.data[builtin_element_slot(el_type)].animation_list = animation_new_in_domain(anims, lists, .MILLISECONDS, ..frames)
    }


    anim_hit := animation_new(anims, lists, 
        Animation_Scale{
            start_time = 0,
            end_time = 1,
            start_scale = {1, 1}, 
            end_scale = {1.5, 1.5}
        },
        Animation_Alpha{
            start_time = 0,
            end_time = 1,
            start_alpha = 1.0,
            end_alpha = 0.0,
        }
    )

    clickables := [?]Element_Type{
        .CLICKED_HIT_CIRCLE, .CLICKED_HIT_CIRCLE_OVERLAY, .FINISHED_SLIDER_END_CIRCLE, .FINISHED_SLIDER_END_CIRCLE_OVERLAY,
        .CLICKED_SLIDER_START_CIRCLE, .CLICKED_SLIDER_START_CIRCLE_OVERLAY,
    }
    for el in clickables {
        elements.data[builtin_element_slot(el)].animation_list = anim_hit
    }

    elements.data[builtin_element_slot(.SLIDER_TICK)].animation_list = animation_new_in_domain(anims, lists, .MILLISECONDS,
        Animation_Scale{
            tween = .LINEAR,
            start_time = 0, end_time = SLIDER_TICK_POP_MS * 0.5,
            start_scale = {0, 0}, end_scale = {1.1, 1.1},
        },
        Animation_Scale{
            tween = .LINEAR,
            start_time = SLIDER_TICK_POP_MS * 0.5, end_time = SLIDER_TICK_POP_MS,
            start_scale = {1.1, 1.1}, end_scale = {1, 1},
        },
    )
}


hitobject_clear_drawables :: proc(hobj: ^Hitobject) {
    for handle in hobj.gfx_handles {
        slotmap.remove(&game.beatmap.drawables, handle)
    }
    hobj.gfx_handles = {}
}

hitobject_reserve_phase_elements :: proc(
    hobj: ^Hitobject, phase: Hitobject_Phase, num_elements: u32 = 16
) -> (result: []Element_ID) {
    return make([]Element_ID, 16, memory.allocators[.SCRIPT_ELEMENTS])
}

// note(isak): creates drawables for a hitobject entering the given phase. for PREEMPT, falls back to 
// the default graphics if no custom elements are set. for other phases, only writes drawables if 
// custom elements are set. phase_start_time is the map time at which this phase began
hitobject_create_phase_drawables :: proc(hobj: ^Hitobject, phase: Hitobject_Phase, phase_start_time: f64) {
    if hobj.type != .CIRCLE && hobj.type != .SLIDER do return

    preempt := hitobject_preempt_ms(hobj)
    num_custom := hobj.custom_element_nums[phase]

    in_visible_phase := phase == .PREEMPT || phase == .POSTEMPT

    digits: [6]int
    num_digits: int
    if .HIDE_COMBO_NUMBERS not_in hobj.flags && in_visible_phase {
        num_digits = write_combo_digits(&digits, int(hobj.combo_number))
    }
    
    // note(isak): skins shipping sliderstartcircle use it for slider heads; when its overlay is
    // absent osu draws no overlay at all (no hitcircleoverlay fallback), hence the slice trim
    base_els := [?]Element_Type{.HIT_CIRCLE_OVERLAY, .HIT_CIRCLE, .APPROACH_CIRCLE}
    base := base_els[:]
    if hobj.type == .SLIDER && game.active_skin.has_sliderstart {
        base_els[0] = .SLIDER_START_CIRCLE_OVERLAY
        base_els[1] = .SLIDER_START_CIRCLE
        if window.skin_textures[.SLIDER_START_CIRCLE_OVERLAY].tex_id == 0 {
            base = base_els[1:]
        }
    }

    hidden := .HIDDEN_FADES in hobj.flags
    if hidden {
        base = base[:len(base)-1] // the approach circle is always last
    }

    num_base := num_custom if num_custom > 0 else (len(base) if in_visible_phase else 0)
    total_handles := num_digits + num_base

    // note(isak): handles draw last-to-first, so the digits normally land above the whole circle.
    // HitCircleOverlayAboveNumber moves the overlay to the front instead, in front of the digits
    has_overlay := base[0] == .HIT_CIRCLE_OVERLAY || base[0] == .SLIDER_START_CIRCLE_OVERLAY
    overlay_above_digits := num_custom == 0 && has_overlay && game.active_skin.hit_circle_overlay_above_number
    digit_handle_offset := 1 if overlay_above_digits else 0

    if total_handles == 0 do return

    if len(hobj.gfx_handles_backing) < total_handles {
        hobj.gfx_handles_backing = make([]Drawable_Handle, total_handles, memory.allocators[.DRAWABLES])
    }
    hobj.gfx_handles = hobj.gfx_handles_backing[:total_handles]

    if num_custom > 0 {
        // note(isak): maps animation time over the natural duration of each phase
        phase_end_time: f64
        rel_pos: vec2
        switch phase {
            case .PREEMPT:  phase_end_time = phase_start_time + preempt
            case .POSTEMPT: phase_end_time = phase_start_time + hitobject_timing_windows(hobj).ok
            case .HOLD:     phase_end_time = phase_start_time + hobj.end_time_ms - hobj.start_time_ms
            case .NONE:     phase_end_time = phase_start_time + f64(0)
            case .HIT, .MISS: 
                hit_animation_time := hobj.custom_hit_animation_len_ms != 0 ? hobj.custom_hit_animation_len_ms : OSU_HIT_ANIMATION_LENGTH
                phase_end_time = phase_start_time + f64(hit_animation_time)

                if hobj.type == .SLIDER {
                    rel_pos = hitobject_tail_pos(hobj) - hitobject_pos(hobj)
                }
        }

        // note(isak): size is stored in radius units (1 = 1 radius). render_drawable multiplies by 
        // hitobject_radius_osupx at draw time
        
        is_final_phase := phase == .HIT || phase == .MISS

        for i in 0..<hobj.custom_element_nums[phase] {
            el_id := hobj.custom_elements[phase][i]
            el := q.get(&game.beatmap.elements, el_id)

            drawable_color := hitobject_combo_color(hobj) if .USE_COMBO_COLOR in el.flags else color_white
            drawable_flags := Drawable_Flags{.ACTIVE}
            if in_visible_phase do drawable_flags |= {.FADE_IN, .HITOBJECT_DIM}
            if is_final_phase do drawable_flags |= {.OWNER_DRAWN}

            handle := drawable_new(Drawable{
                flags         = drawable_flags,
                element       = el_id,
                layer         = layer_id(.HITOBJECTS),
                pos           = rel_pos,
                size          = {2, 2},
                anchor        = .CENTER,
                color         = drawable_color,
                start_time_ms = phase_start_time,
                end_time_ms   = phase_end_time,
                hobj_index    = hobj.index + 1,
            })
            hobj.gfx_handles[num_digits + i] = handle
            if is_final_phase {
                sb.append(&game.beatmap.gameplay_expiring_gfx, handle)
            }
        }
    } else {
        for el_type, i in base {
            el_id := builtin_element_slot(el_type)
            el := q.get(&game.beatmap.elements, el_id)

            drawable_color := hitobject_combo_color(hobj) if .USE_COMBO_COLOR in el.flags else color_white

            drawable_flags := Drawable_Flags{.ACTIVE, .FADE_IN}
            if el_type != .APPROACH_CIRCLE do drawable_flags |= {.HITOBJECT_DIM}
            else do drawable_color = with_alpha(drawable_color, 0.9) // note(isak): osu's approach circle alpha multiplier

            end_ms := hobj.start_time_ms + (hitobject_timing_windows(hobj).ok if el_type != .APPROACH_CIRCLE else 0)
            handle_index := 0 if overlay_above_digits && i == 0 else num_digits + i
            hobj.gfx_handles[handle_index] = drawable_new(Drawable{
                flags          = drawable_flags,
                element        = el_id,
                layer          = layer_id(.HITOBJECTS),
                pos            = vec2{0, 0},
                size           = skin_element_size_radius_units(el_type),
                anchor         = .CENTER,
                color          = drawable_color,
                start_time_ms  = hobj.start_time_ms - preempt,
                end_time_ms    = end_ms,
                hobj_index     = hobj.index + 1,
                animation_list = game.beatmap.hidden_fade_list if hidden else 0,
            })
        }
    }

    if num_digits > 0 {
        // digit drawables
        // note(isak): size and pos are in radius units so they scale correctly with CS changes at runtime.
        // digits scale against osu's fixed 160px reference, independent of the hitcircle image's size
        number_scale_norm := 2.0 / SKIN_NUMBER_REFERENCE_PX
        // note(isak): HitCircleOverlap is a pixel count at the glyph's metric size, so it normalizes
        // through the same factor as the digit widths. it trims the gap between adjacent digits.
        overlap_norm := game.active_skin.font_hit_circle_overlap * number_scale_norm

        total_digits_w_norm: f32
        for digit in 0..<num_digits {
            digit_el := Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digits[digit])
            total_digits_w_norm += game.active_skin.elements[digit_el].metrics.x * number_scale_norm
        }
        total_digits_w_norm -= overlap_norm * f32(num_digits - 1)

        x_norm := -total_digits_w_norm / 2
        for di in 0..<num_digits {
            digit_el      := Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digits[di])
            digit_metrics := game.active_skin.elements[digit_el].metrics
            digit_size_norm := digit_metrics * number_scale_norm
            hobj.gfx_handles[di + digit_handle_offset] = drawable_new(Drawable{
                flags          = {.ACTIVE, .FADE_IN, .SCALE_POS_BY_RADIUS, .HITOBJECT_DIM},
                element        = builtin_element_slot(Element_Type(int(Element_Type.COMBO_DIGIT_0) + digits[di])),
                layer          = layer_id(.HITOBJECTS),
                pos            = {x_norm + digit_size_norm.x / 2, 0},
                size           = digit_size_norm,
                anchor         = .CENTER,
                color          = with_alpha(color_white, 1),
                start_time_ms  = hobj.start_time_ms - preempt,
                end_time_ms    = hobj.start_time_ms + hitobject_timing_windows(hobj).ok,
                hobj_index     = hobj.index + 1,
                animation_list = game.beatmap.hidden_fade_list if hidden else 0,
            })
            x_norm += digit_size_norm.x - overlap_norm
        }
    }
}

hitcircle_create_default_hit_drawables :: proc(hobj: ^Hitobject, pos: vec2, map_time: f64, sliderend: bool) {
    if hobj.flags & {.HIDDEN_BY_SCRIPT, .HIDDEN_FADES} != {} {
        return
    }

    el_overlay: Element_Type = sliderend ? .FINISHED_SLIDER_END_CIRCLE_OVERLAY : .CLICKED_HIT_CIRCLE_OVERLAY
    el_circle: Element_Type = sliderend ? .FINISHED_SLIDER_END_CIRCLE : .CLICKED_HIT_CIRCLE
    draw_overlay := !sliderend || skin_draws_sliderend_overlay(game.active_skin)
    if !sliderend && hobj.type == .SLIDER && game.active_skin.has_sliderstart {
        el_circle  = .CLICKED_SLIDER_START_CIRCLE
        el_overlay = .CLICKED_SLIDER_START_CIRCLE_OVERLAY
        draw_overlay = window.skin_textures[.SLIDER_START_CIRCLE_OVERLAY].tex_id != 0
    }

    combo_color := hitobject_combo_color(hobj)

    slider_head := !sliderend && hobj.type == .SLIDER
    flags := Drawable_Flags{.ACTIVE}
    if slider_head do flags |= {.OWNER_DRAWN}

    // note(isak): expiring gfx render in insertion order, so order matters here
    circle_handle := drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
        flags = flags,
        element = builtin_element_slot(el_circle),
        layer = layer_id(.HITOBJECTS),
        pos = pos,
        size = skin_element_size_radius_units(el_circle),
        anchor = .CENTER,
        color = combo_color,
        start_time_ms = map_time,
        end_time_ms = map_time + OSU_HIT_ANIMATION_LENGTH,
        hobj_index = hobj.index + 1,
    })
    overlay_handle: Drawable_Handle
    if draw_overlay {
        overlay_handle = drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
            flags = flags,
            element = builtin_element_slot(el_overlay),
            layer = layer_id(.HITOBJECTS),
            pos = pos,
            size = skin_element_size_radius_units(el_overlay),
            anchor = .CENTER,
            color = color_white,
            start_time_ms = map_time,
            end_time_ms = map_time + OSU_HIT_ANIMATION_LENGTH,
            hobj_index = hobj.index + 1,
        })
    }
    if slider_head {
        hobj.slider_state.gfx.clicked_circle = circle_handle
        hobj.slider_state.gfx.clicked_overlay = overlay_handle
    }
}

// note(isak): processes phase transitions emitted by game logic, creating/replacing drawables
process_hitobject_phase_transitions :: proc() {
    map_time := beatmap_music_time_ms(&game.beatmap)

    for transition in game.beatmap.phase_transitions.current {
        hobj := &game.beatmap.hitobjects[transition.hitobject_index]

        preempt := hitobject_preempt_ms(hobj)
        switch transition.to {
        case .PREEMPT:
            hitobject_create_phase_drawables(hobj, .PREEMPT, hobj.start_time_ms - preempt)
            if hobj.type == .SLIDER do slider_create_gfx(hobj)

        case .POSTEMPT:
            hitobject_clear_drawables(hobj)
            hitobject_create_phase_drawables(hobj, .POSTEMPT, hobj.start_time_ms)
        
        case .HOLD:
            hitobject_clear_drawables(hobj)
            
            hitcircle_create_default_hit_drawables(hobj, hitobject_pos(hobj), map_time, false)
            hitobject_create_phase_drawables(hobj, .HOLD, hobj.start_time_ms)
        case .HIT:
            hitobject_clear_drawables(hobj)
            
            // note(isak): custom hit animations override the default circle expanding animation
            if hobj.custom_element_nums[.HIT] == 0 {
                if transition.from == .PREEMPT || transition.from == .POSTEMPT {
                    hitcircle_create_default_hit_drawables(hobj, hitobject_pos(hobj), map_time, false)
                } else if transition.from == .HOLD {
                    hitcircle_create_default_hit_drawables(hobj, hitobject_tail_pos(hobj), map_time, true)
                }
            }
            hitobject_create_phase_drawables(hobj, .HIT, map_time)
        case .MISS:
            hitobject_clear_drawables(hobj)
            hitobject_create_phase_drawables(hobj, .MISS, map_time)
        case .NONE:
        }
    }
    sb.swap(&game.beatmap.phase_transitions)
}


slider_screenspace_bounding_box :: proc(hobj: ^Hitobject, slider: ^Slider_Path, translation: vec2 = {}) -> (result: Rect) {
    r := hitobject_radius_osupx(hobj)
    pad := f32(2)
    osupx_rect := Rect{
        slider.bounds_min.x - r + translation.x,
        slider.bounds_min.y - r + translation.y,
        slider.bounds_max.x - slider.bounds_min.x + r * 2,
        slider.bounds_max.y - slider.bounds_min.y + r * 2,
    }
    pf_mat := transform_to_mat3(game.playfield_transform)
    ss_mat := transform_to_mat3(window.screenspace_transform)
    corners := transform_rect_to_screen_corners(osupx_rect, pf_mat, ss_mat)
    result = calculate_aabb_from_corners(corners)
    result.x, result.y = result.x - pad, result.y - pad
    result.w, result.h = result.w + pad*2, result.h + pad*2
    return result
}


// note(isak): the immediate-mode body can't use the drawable FADE_IN/FADE_OUT flags, so it mirrors their
// math here: fade in over the preempt (same as circles), fade out over the tail past end_time.
slider_body_alpha :: proc(hobj: ^Hitobject, map_time: f64) -> f32 {
    preempt := hitobject_preempt_ms(hobj)
    fade_in_ms := min(preempt * 0.4, 400.0)
    fade_in := clamp((map_time - (hobj.start_time_ms - preempt)) / fade_in_ms, 0, 1)

    if .HIDDEN_FADES in hobj.flags {
        return f32(min(fade_in, slider_hidden_fadeout_factor(hobj, map_time)))
    }

    fade_out_ms := f64(OSU_HIT_ANIMATION_LENGTH)
    fade_out := clamp((hobj.end_time_ms + fade_out_ms - map_time) / fade_out_ms, 0, 1)

    return f32(min(fade_in, fade_out))
}

// note(isak): stable hidden slider fade - starts the moment the 40%-of-preempt fade-in completes
// and reaches zero exactly at the slider's end time
slider_hidden_fadeout_factor :: proc(hobj: ^Hitobject, map_time: f64) -> f64 {
    fade_out_start := hobj.start_time_ms - hitobject_preempt_ms(hobj) * 0.6
    return clamp((hobj.end_time_ms - map_time) / (hobj.end_time_ms - fade_out_start), 0, 1)
}

SLIDER_ATLAS_PAD :: 2
SLIDER_ATLAS_SIZE :: 8192 // clamped to GL_MAX_TEXTURE_SIZE at init

// note(isak): the SLIDERS framebuffer is a big fixed atlas of cached body distance fields,
// reserved once up front (R16F, 2 B/texel) so it never reallocates mid-map. slots are
// bump-allocated in rows; when the atlas fills up we reset the whole thing and bump the
// generation, which lazily regenerates every visible body over the following frames - one
// frame of regeneration costs what every frame cost before caching, so resets are cheap.
Slider_Atlas :: struct {
    w, h: i32,
    cur_x, cur_y, row_h: i32,
    generation: u32, // starts at 1 so zero-value Slider_Body_Caches are never valid
}

Slider_Body_Cache :: struct {
    content_rect: Rect, // atlas texels, excluding the cleared gutter around the slot
    baked_bbox: Rect,   // slider-local osupx actually baked (full bbox clipped to visibility)
    texels_per_osupx: f32,
    baked_first, baked_last: i32,
    generation: u32,
}

slider_atlas_reset :: proc "contextless" () {
    atlas := &window.slider_atlas
    atlas.cur_x = 0
    atlas.cur_y = 0
    atlas.row_h = 0
    atlas.generation += 1
}

// note(isak): w and h must each fit the atlas minus the gutter; callers guarantee that by
// clamping their texel density. allocation therefore always succeeds after at most one reset.
slider_atlas_alloc :: proc(w, h: i32) -> (content: Rect) {
    atlas := &window.slider_atlas
    atlas_w := atlas.w
    atlas_h := atlas.h
    padded_w := w + 2 * SLIDER_ATLAS_PAD
    padded_h := h + 2 * SLIDER_ATLAS_PAD

    if atlas.cur_x + padded_w > atlas_w {
        atlas.cur_y += atlas.row_h
        atlas.cur_x = 0
        atlas.row_h = 0
    }
    if atlas.cur_y + padded_h > atlas_h {
        slider_atlas_reset()
    }

    content = Rect{f32(atlas.cur_x + SLIDER_ATLAS_PAD), f32(atlas.cur_y + SLIDER_ATLAS_PAD), f32(w), f32(h)}
    atlas.cur_x += padded_w
    atlas.row_h = max(atlas.row_h, padded_h)
    return content
}

slider_render_path :: proc(renderer: ^Renderer, hobj: ^Hitobject, slider: ^Slider_Path, map_time: f64) {
    first_instance := i32(0)
    last_instance  := max(1, i32(f64(slider.instance_count) * slider_snake_in_factor(hobj)))
    retracted := i32(f64(slider.instance_count) * slider_snake_out_factor(hobj))
    final_span_heads_back := hobj.slider_state.path_travel_count % 2 == 0
    if final_span_heads_back {
        last_instance = min(last_instance, slider.instance_count - retracted)
    } else {
        first_instance = retracted
    }
    if last_instance <= first_instance {
        return
    }

    r := hitobject_radius_osupx(hobj)
    full_bbox := Rect{
        slider.bounds_min.x - r,
        slider.bounds_min.y - r,
        slider.bounds_max.x - slider.bounds_min.x + r * 2,
        slider.bounds_max.y - slider.bounds_min.y + r * 2,
    }

    // only bake the part the playfield transform can currently show: the visible screen region
    // mapped back to this slider's local osupx (minus its script translation), padded by a radius
    // so edges/AA never clip. a moved camera re-bakes via the baked_bbox staleness key below
    translation := hobj.script_pos_translation
    visible := playfield_visible_osupx_bounds()
    visible.x -= translation.x + r
    visible.y -= translation.y + r
    visible.w += 2 * r
    visible.h += 2 * r
    bbox_osupx, on_screen := rect_intersect(full_bbox, visible)
    if !on_screen {
        return
    }

    atlas := &window.slider_atlas

    // bake at the texel density so static playfields sample the field 1:1; bodies larger
    // than the atlas bake at whatever density fits (banding stays sharp regardless
    // since the thresholds run on the sampled field)
    texels_per_osupx := min(
        playfield_px_per_osupx(),
        (f32(atlas.w) - 2 * SLIDER_ATLAS_PAD) / bbox_osupx.w,
        (f32(atlas.h) - 2 * SLIDER_ATLAS_PAD) / bbox_osupx.h)

    cache := &hobj.slider_state.body_cache
    clip_tol := 0.5 / texels_per_osupx // half a texel of camera drift before we re-bake the clip
    stale := cache.generation != window.slider_atlas.generation ||
             cache.baked_first != first_instance ||
             cache.baked_last  != last_instance ||
             abs(cache.texels_per_osupx - texels_per_osupx) > texels_per_osupx * 0.005 ||
             abs(cache.baked_bbox.x - bbox_osupx.x) > clip_tol ||
             abs(cache.baked_bbox.y - bbox_osupx.y) > clip_tol ||
             abs(cache.baked_bbox.w - bbox_osupx.w) > clip_tol ||
             abs(cache.baked_bbox.h - bbox_osupx.h) > clip_tol

    if stale {
        content_w := i32(math.ceil(bbox_osupx.w * texels_per_osupx))
        content_h := i32(math.ceil(bbox_osupx.h * texels_per_osupx))
        if cache.generation != window.slider_atlas.generation ||
           i32(cache.content_rect.w) != content_w || i32(cache.content_rect.h) != content_h {
            cache.content_rect = slider_atlas_alloc(content_w, content_h)
        }
        cache.texels_per_osupx = texels_per_osupx
        cache.baked_bbox = bbox_osupx
        cache.baked_first = first_instance
        cache.baked_last = last_instance
        cache.generation = window.slider_atlas.generation

        // note(isak): slider geometry is in CS-normalized units (osupx / radius); the bake
        // transform places the body's osupx bbox at its atlas slot, treating the atlas like a
        // second screen so all scissor/uv conventions match the window. script translation is
        // NOT baked - it moves the presented quad instead
        place_atlas_px := mat3{
            texels_per_osupx, 0, cache.content_rect.x - bbox_osupx.x * texels_per_osupx,
            0, texels_per_osupx, cache.content_rect.y - bbox_osupx.y * texels_per_osupx,
            0, 0, 1,
        }
        cs_to_osupx := mat3{r, 0, 0, 0, r, 0, 0, 0, 1}
        // the atlas is its own render target, so slot pixels map to NDC through an atlas-sized
        // screenspace transform, not the window's
        atlas_screenspace := transform_from_bounds({0, 0, f32(atlas.w), f32(atlas.h)}, 1)
        bake_transform := mat3_to_transform(transform_to_mat3(atlas_screenspace) * place_atlas_px * cs_to_osupx)

        slot_rect := Rect{
            cache.content_rect.x - SLIDER_ATLAS_PAD,
            cache.content_rect.y - SLIDER_ATLAS_PAD,
            f32(content_w + 2 * SLIDER_ATLAS_PAD),
            f32(content_h + 2 * SLIDER_ATLAS_PAD),
        }

        r_bind_pipeline({ pipeline = builtin_pipeline_slot(.SLIDER) })
        r_bind_framebuffer({ write = builtin_framebuffer(.SLIDERS) })
        r_bind_ssbo(&window.circle_geo_buffer, .VERTEX_BUFFER)

        if window.graphics_vendor == .INTEL_INTEGRATED {
            // note(isak): on intel opengl drivers, a scissored glClear ignores ClipControl(UPPER_LEFT),
            // so we flip the y coordinate basis to upper left ourselves
            r_set_scissor_mode(
                i32(slot_rect.x),
                atlas.h - i32(slot_rect.y) - i32(slot_rect.h),
                i32(slot_rect.w),
                i32(slot_rect.h))
            r_clear(with_alpha(color_black, 0.0))
            r_set_scissor_mode(slot_rect)
        } else {
            r_set_scissor_mode(slot_rect)
            r_clear(with_alpha(color_black, 0.0))
        }

        r_push_draw_slider(Slider_Params{
            transform          = bake_transform,
            base_instance      = u32(slider.first_instance_at + first_instance),
            radius_osupx       = r,
        }, last_instance - first_instance)
    }

    // note(isak): the body composite bypasses render_drawable, so we have to resolve the HITOBJECTS
    // target through r_layer_framebuffer to match the rest of the layer
    slider_write_target := r_layer_framebuffer(.HITOBJECTS).write
    r_bind_framebuffer({ read = builtin_framebuffer(.SLIDERS), write = slider_write_target })
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)

    if app.debug_display_slider_bounds {
        r_bind_pipeline({ pipeline = builtin_pipeline_slot(.QUAD) })
        r_push_transform(window.screenspace_transform)
        r_reset_scissor_mode()
        r_draw_rect_outline(&renderer.quad_geometry, slider_screenspace_bounding_box(hobj, slider, translation), color_cyan, 1)
    }
    r_bind_pipeline({ pipeline = builtin_pipeline_slot(.SLIDER_PRESENT) })
    r_reset_scissor_mode()

    // present exactly what's in the slot: a reused cache may have drifted within tolerance from
    // this frame's live clip/density, so the quad and uvs track the baked values, not the live ones
    baked_bbox := cache.baked_bbox
    baked_density := cache.texels_per_osupx

    // uvs cover the exact fractional field extent, not the ceil'd slot, so texels map 1:1
    atlas_uvs := Rect{
        cache.content_rect.x / f32(atlas.w),
        cache.content_rect.y / f32(atlas.h),
        baked_bbox.w * baked_density / f32(atlas.w),
        baked_bbox.h * baked_density / f32(atlas.h),
    }
    body_rect := Rect{
        baked_bbox.x + translation.x,
        baked_bbox.y + translation.y,
        baked_bbox.w,
        baked_bbox.h,
    }

    // note(isak): the band's body samples this per-slider color; border stays skin-global. track
    // override wins when set, otherwise the body takes the object's combo color
    body_rgb := hitobject_combo_color(hobj)
    if game.active_skin != nil && game.active_skin.slider_track_override.a != 0 {
        body_rgb = game.active_skin.slider_track_override
    }

    // note(isak): dimming the composite tint dims border and body together, mirroring HITOBJECT_DIM
    // the same way slider_body_alpha mirrors FADE_IN/FADE_OUT
    body_tint := color_scale_rgb(color_white, hitobject_dim_factor(hobj.start_time_ms, map_time))
    r_push_transform(game.playfield_transform)
    r_draw_rect_with_uv(&renderer.quad_geometry,
                        body_rect,
                        atlas_uvs,
                        with_alpha(body_tint, slider_body_alpha(hobj, map_time)),
                        builtin_texture(.SLIDER_FRAMEBUFFER),
                        body_color = with_alpha(body_rgb, 0.7))
}

slider_part_element :: proc(hobj: ^Hitobject, part: Slider_Part) -> Element_ID {
    if custom := hobj.slider_state.custom_elements[part]; custom != 0 {
        return custom
    }
    builtin: Element_Type
    switch part {
    case .BALL:          builtin = .SLIDER_BALL
    case .FOLLOW_CIRCLE: builtin = .SLIDER_FOLLOW_CIRCLE
    case .TICK:          builtin = .SLIDER_TICK
    case .REPEAT:        builtin = .SLIDER_REPEAT
    case .END:           builtin = .SLIDER_END
    case .END_OVERLAY:   builtin = .SLIDER_END_OVERLAY
    }
    return builtin_element_slot(builtin)
}

// note(isak): size is in radius units (multiplied by the CS radius at render time via hobj_index)
slider_drawable_new :: proc(hobj: ^Hitobject, part: Slider_Part, size_radius_units: vec2, color: Color, flags: Drawable_Flags = {}, linger_ms: f64 = 0) -> Drawable_Handle {
    return drawable_new(Drawable{
        flags         = flags,
        element       = slider_part_element(hobj, part),
        layer         = layer_id(.HITOBJECTS),
        size          = size_radius_units,
        anchor        = .CENTER,
        color         = color,
        start_time_ms = hobj.start_time_ms - hitobject_preempt_ms(hobj),
        end_time_ms   = hobj.end_time_ms + linger_ms,
        hobj_index    = hobj.index + 1,
    })
}

// note(isak): allocates the slider's internal drawables (or reuses if already allocated).
// per-frame visibility and position come from slider_sync_gfx.
slider_create_gfx :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state
    combo := hitobject_combo_color(hobj)

    tick_size    := skin_element_size_radius_units(.SLIDER_TICK)
    repeat_size  := skin_element_size_radius_units(.SLIDER_REPEAT)
    ball_size    := skin_element_size_radius_units(.SLIDER_BALL)
    end_size     := skin_element_size_radius_units(.SLIDER_END)
    overlay_size := skin_element_size_radius_units(.SLIDER_END_OVERLAY)

    gfx := &slider.gfx
    gfx.end_circle   = slider_drawable_new(hobj, .END,           end_size,     combo,       {.FADE_IN, .HITOBJECT_DIM})
    gfx.end_overlay  = slider_drawable_new(hobj, .END_OVERLAY,   overlay_size, color_white, {.FADE_IN, .HITOBJECT_DIM})
    gfx.head_circle  = slider_drawable_new(hobj, .END,           end_size,     combo,       {.FADE_IN, .HITOBJECT_DIM})
    gfx.head_overlay = slider_drawable_new(hobj, .END_OVERLAY,   overlay_size, color_white, {.FADE_IN, .HITOBJECT_DIM})
    gfx.follow       = slider_drawable_new(hobj, .FOLLOW_CIRCLE, slider_follow_circle_size(slider), color_white,
                                           linger_ms = FOLLOW_CIRCLE_END_MS)
    for &arrow in gfx.repeat_arrows {
        arrow = slider_drawable_new(hobj, .REPEAT, repeat_size, color_white)
    }

    ball_color := game.active_skin.slider_ball
    if game.active_skin.allow_slider_ball_tint do ball_color = combo
    gfx.ball = slider_drawable_new(hobj, .BALL, ball_size, ball_color)

    // note(isak): the head click animation is created on hit, not here; clear stale handles so a
    // respawn (seek + replay) never renders a recycled slot before the head is clicked again
    gfx.clicked_circle = {}
    gfx.clicked_overlay = {}

    if len(gfx.ticks) != slider.tick_count {
        gfx.ticks = make([]Drawable_Handle, slider.tick_count, memory.allocators[.DRAWABLES])
    }
    for i in 0..<slider.tick_count {
        gfx.ticks[i] = slider_drawable_new(hobj, .TICK, tick_size, color_white)
    }
}

// note(isak): sets the lua element override for a slider part and applies it to any already-spawned drawables
slider_set_part_element :: proc(hobj: ^Hitobject, part: Slider_Part, element: Element_ID) {
    hobj.slider_state.custom_elements[part] = element

    gfx := &hobj.slider_state.gfx
    update :: proc(h: Drawable_Handle, element: Element_ID) {
        if h == {} do return
        if d, ok := slotmap.get(&game.beatmap.drawables, h); ok do d.element = element
    }
    switch part {
    case .BALL:          update(gfx.ball, element)
    case .FOLLOW_CIRCLE: update(gfx.follow, element)
    case .REPEAT:        for h in gfx.repeat_arrows do update(h, element)
    case .END:           update(gfx.end_circle, element);  update(gfx.head_circle, element)
    case .END_OVERLAY:   update(gfx.end_overlay, element); update(gfx.head_overlay, element)
    case .TICK:          for h in gfx.ticks do update(h, element)
    }
}

slider_clear_handles :: proc(hobj: ^Hitobject) {
    gfx := &hobj.slider_state.gfx
    handles := [?]Drawable_Handle{
        gfx.ball, gfx.follow, gfx.end_circle, gfx.end_overlay,
        gfx.head_circle, gfx.head_overlay,
    }
    for h in handles {
        if h != {} do slotmap.remove(&game.beatmap.drawables, h)
    }
    for h in gfx.repeat_arrows {
        if h != {} do slotmap.remove(&game.beatmap.drawables, h)
    }
    for &h in gfx.ticks {
        if h != {} do slotmap.remove(&game.beatmap.drawables, h)
        h = {}
    }
    ticks := gfx.ticks
    gfx^ = {}
    gfx.ticks = ticks
}


slider_drawable_update :: proc(d: ^Drawable, active: bool, pos: vec2, angle: f32 = 0) {
    if active do d.flags |= {.ACTIVE}
    else      do d.flags &~= {.ACTIVE}
    d.pos = pos
    d.angle_rad = angle
}

slider_handle_update :: proc(h: Drawable_Handle, active: bool, pos: vec2, angle: f32 = 0, fade_start_ms: f64 = -1) {
    d, ok := slotmap.get(&game.beatmap.drawables, h)
    if !ok do return
    slider_drawable_update(d, active, pos, angle)
    if active && fade_start_ms >= 0 do d.start_time_ms = fade_start_ms
}

progress_over :: proc(elapsed_ms, duration_ms: f64) -> f32 {
    if duration_ms <= 0 do return 1
    return f32(clamp(elapsed_ms / duration_ms, 0, 1))
}

// note(isak): stable's follow circle, via lazer's LegacyFollowCircle. scales relative to the full sprite
FOLLOW_CIRCLE_PRESS_SCALE_MS    :: 180
FOLLOW_CIRCLE_PRESS_FADE_MS     :: 60
FOLLOW_CIRCLE_PRESS_START_SCALE :: 0.5
FOLLOW_CIRCLE_BREAK_MS          :: 100
FOLLOW_CIRCLE_BREAK_SCALE       :: 2
FOLLOW_CIRCLE_END_MS            :: 200
FOLLOW_CIRCLE_END_SCALE         :: 0.8

// note(isak): handles custom scripts scaling the radius multiplier
slider_follow_circle_size :: proc(slider: ^Slider_State) -> vec2 {
    return skin_element_size_radius_units(.SLIDER_FOLLOW_CIRCLE) *
        (slider.follow_circle_radius_mult / SLIDER_FOLLOW_CIRCLE_DEFAULT_RADIUS_MULT)
}

slider_follow_circle_press_look :: proc(hobj: ^Hitobject, since_press_ms: f64) -> (scale, alpha: f32) {
    remaining_ms := max(hobj.end_time_ms - hobj.slider_state.tracked_timestamp_at, 0)
    grown := tween_apply(.QUAD_OUT, progress_over(since_press_ms, min(FOLLOW_CIRCLE_PRESS_SCALE_MS, remaining_ms)))
    
    scale = math.lerp(f32(FOLLOW_CIRCLE_PRESS_START_SCALE), 1, grown)
    alpha = progress_over(since_press_ms, min(FOLLOW_CIRCLE_PRESS_FADE_MS, remaining_ms))
    return scale, alpha
}

slider_follow_circle_look :: proc(hobj: ^Hitobject, map_time: f64) -> (scale, alpha: f32) {
    slider := &hobj.slider_state
    if .EVER_TRACKED not_in slider.flags do return 0, 0

    pressed_at := slider.tracked_timestamp_at
    if slider.scorepoint_missed_at > pressed_at {
        scale, alpha = slider_follow_circle_press_look(hobj, slider.scorepoint_missed_at - pressed_at)
        t := progress_over(map_time - slider.scorepoint_missed_at, FOLLOW_CIRCLE_BREAK_MS)
        scale = math.lerp(scale, FOLLOW_CIRCLE_BREAK_SCALE, t)
        alpha = math.lerp(alpha, 0, t)
        return scale, alpha
    }
    if .FINALIZED in slider.flags {
        scale, alpha = slider_follow_circle_press_look(hobj, hobj.end_time_ms - pressed_at)
        t := progress_over(map_time - hobj.end_time_ms, FOLLOW_CIRCLE_END_MS)
        scale = math.lerp(scale, FOLLOW_CIRCLE_END_SCALE, tween_apply(.QUAD_OUT, t))
        alpha *= (1 - tween_apply(.QUAD_IN, t))
        return scale, alpha
    }

    return slider_follow_circle_press_look(hobj, map_time - pressed_at)
}

// note(isak): stable's reverse arrow, via lazer's LegacyReverseArrow and DrawableSliderRepeat
REPEAT_ARROW_FADE_IN_MS  :: 150
REPEAT_ARROW_PULSE_MS    :: 300
REPEAT_ARROW_PULSE_SCALE :: 1.3
REPEAT_ARROW_HIT_MS      :: 300
REPEAT_ARROW_HIT_SCALE   :: 1.4

// note(isak): every repeat gets its own arrow, but at most two per end are ever alive (the one just
// hit, still fading, and the next one appearing behind it), so they cycle through four slots
slider_repeat_arrow_slot :: proc(repeat_index: int) -> int {
    return (repeat_index % 2) * 2 + (repeat_index / 2) % 2
}

// note(isak): end 0 is the tail, where even repeats turn around; end 1 is the head
slider_upcoming_repeat_on_end :: proc(slider: ^Slider_State, end: int) -> int {
    return slider.checked_repeats_count + (end - slider.checked_repeats_count) %% 2
}

slider_repeat_arrow_look :: proc(hobj: ^Hitobject, repeat_index: int, map_time: f64) -> (scale, alpha: f32) {
    slider := &hobj.slider_state
    span_ms := slider.duration_ms
    hit_time_ms := hobj.start_time_ms + f64(repeat_index + 1) * span_ms

    // note(isak): the first arrow arrives with the slider, held back until snaking finishes; each
    // later one spawns the moment the previous arrow on its end is hit
    appear_ms, fade_in_start_ms, fade_in_ms: f64
    if repeat_index == 0 {
        preempt_ms := hitobject_preempt_ms(hobj)
        appear_ms = hobj.start_time_ms - preempt_ms
        fade_in_start_ms = appear_ms + (preempt_ms / 3 if slider_snakes_in(hobj) else 0)
        fade_in_ms = REPEAT_ARROW_FADE_IN_MS
    } else {
        appear_ms = hit_time_ms - 2 * span_ms
        fade_in_start_ms = appear_ms
        fade_in_ms = min(REPEAT_ARROW_FADE_IN_MS, span_ms)
    }
    if map_time < fade_in_start_ms do return 0, 0

    pulse_t := progress_over(math.mod(map_time - appear_ms, REPEAT_ARROW_PULSE_MS), REPEAT_ARROW_PULSE_MS)

    scale = math.lerp(f32(REPEAT_ARROW_PULSE_SCALE), 1, tween_apply(.QUAD_OUT, pulse_t))
    alpha = progress_over(map_time - fade_in_start_ms, fade_in_ms)

    if repeat_index < slider.checked_repeats_count {
        t := progress_over(map_time - hit_time_ms, min(REPEAT_ARROW_HIT_MS, span_ms))
        if slider.last_repeat_hit_per_end[repeat_index % 2] {
            eased := tween_apply(.QUAD_OUT, t)
            scale = math.lerp(f32(1), REPEAT_ARROW_HIT_SCALE, eased)
            alpha *= 1 - eased
        } else {
            alpha *= 1 - t
        }
    }
    return scale, alpha
}

slider_update_gfx :: proc(hobj: ^Hitobject, map_time: f64) {
    slider := &hobj.slider_state
    gfx := &slider.gfx
    path := &game.beatmap.slider_paths[hobj.slider_path_index]

    hobj_pos := hitobject_pos(hobj)
    end_pos  := path.end_pos + hobj.script_pos_translation
    snake_full := slider_snake_in_factor(hobj) >= 1

    // note(isak): sliderticks
    current_span := slider.checked_repeats_count
    last_span := slider.path_travel_count - 1
    snake_out := slider_snake_out_factor(hobj)
    final_span_heads_back := slider.path_travel_count % 2 == 0
    for tick, tick_i in gfx.ticks {
        d, ok := slotmap.get(&game.beatmap.drawables, tick)
        if ok {
            span := current_span + (1 if slider.tick_hits[tick_i] else 0)
            active := span <= last_span

            // note(isak): when snaking out, passed ticks must
            // vanish with it regardless of if they were hit so they don't render off the track
            if snake_out > 0 {
                tick_fraction := f64(tick_i + 1) * slider.tick_interval_ms / slider.duration_ms
                retracted := final_span_heads_back ? tick_fraction > 1 - snake_out : tick_fraction < snake_out
                if retracted do active = false
            }

            tick_pos := slider_path_pos_at(hobj, hobj.start_time_ms + f64(tick_i + 1) * slider.tick_interval_ms)

            slider_drawable_update(d, active, tick_pos)
            if active {
                // note(isak): we reuse the tick graphics from the current travel for the next one to emulate osu
                d.start_time_ms = slider_tick_popin_time(hobj, tick_i + 1, span)
            }
        }
    }

    // note(isak): sliderend
    overlay_drawn := slider.custom_elements[.END_OVERLAY] != 0 || skin_draws_sliderend_overlay(game.active_skin)

    has_sliderend_at_end := slider.path_travel_count % 2 == 1 || current_span < last_span
    end_on := has_sliderend_at_end && snake_full
    snake_done_ms := hobj.start_time_ms - hitobject_preempt_ms(hobj) * (2.0/3.0)
    slider_handle_update(gfx.end_circle,  end_on, end_pos, fade_start_ms = snake_done_ms)
    slider_handle_update(gfx.end_overlay, end_on && overlay_drawn, end_pos, fade_start_ms = snake_done_ms)

    has_sliderend_at_head := slider.path_travel_count > 1 &&
        (slider.path_travel_count % 2 == 0 || current_span < last_span)
    head_on := has_sliderend_at_head && hobj.start_time_ms <= map_time
    slider_handle_update(gfx.head_circle,  head_on, hobj_pos)
    slider_handle_update(gfx.head_overlay, head_on && overlay_drawn, hobj_pos)

    hidden_fade := f32(1)
    if .HIDDEN_FADES in hobj.flags {
        hidden_fade = f32(slider_hidden_fadeout_factor(hobj, map_time))
    }

    // note(isak): slider repeats
    for h in gfx.repeat_arrows {
        if d, ok := slotmap.get(&game.beatmap.drawables, h); ok do d.flags &~= {.ACTIVE}
    }
    repeat_size := skin_element_size_radius_units(.SLIDER_REPEAT)
    repeat_count := slider.path_travel_count - 1
    for end in 0..<2 {
        upcoming := slider_upcoming_repeat_on_end(slider, end)
        for repeat_index in ([?]int{upcoming, upcoming - 2}) {
            if repeat_index < 0 || repeat_index >= repeat_count do continue
            d := slotmap.get(&game.beatmap.drawables, gfx.repeat_arrows[slider_repeat_arrow_slot(repeat_index)]) or_continue

            scale, alpha := slider_repeat_arrow_look(hobj, repeat_index, map_time)
            alpha *= hidden_fade
            at_tail := end == 0
            slider_drawable_update(d, alpha > 0, at_tail ? end_pos : hobj_pos, at_tail ? path.end_angle_rad : path.head_angle_rad)
            d.size = repeat_size * scale
            d.color.a = u8(0xFF * alpha)
        }
    }

    // note(isak): sliderball
    ball_active := hobj.start_time_ms <= map_time && map_time < hobj.end_time_ms
    ball_pos := slider_path_pos_at(hobj, map_time) if ball_active else vec2{}
    // note(isak): the sprite faces along the path, so on return spans it points backwards unless the
    // skin mirrors it (SliderBallFlip)
    ball_angle: f32
    ball_mirrored: bool
    if ball_active {
        heading_back := int((map_time - hobj.start_time_ms) / slider.duration_ms) % 2 == 1
        ball_angle = slider_ball_angle_at(hobj, map_time) + (math.PI if heading_back else 0)
        ball_mirrored = heading_back && game.active_skin.slider_ball_flip
    }
    slider_handle_update(gfx.ball, ball_active, ball_pos, ball_angle)
    if d_ball, ok := slotmap.get(&game.beatmap.drawables, gfx.ball); ok {
        d_ball.uv = {}
        if ball_mirrored {
            uv := game.beatmap.elements.data[d_ball.element].uv
            if uv.w == 0 && uv.h == 0 do uv = {0, 0, 1, 1}
            d_ball.uv = {uv.x + uv.w, uv.y, -uv.w, uv.h}
        }
    }

    ball_frame_count := game.active_skin.elements[.SLIDER_BALL].frame_count
    if ball_frame_count > 1 {
        if d_ball, ok := slotmap.get(&game.beatmap.drawables, gfx.ball); ok {
            frame := int((map_time - hobj.start_time_ms) / slider_ball_frame_delay_ms(hobj)) %% ball_frame_count
            d_ball.tex  = skin_frame_texture(.SLIDER_BALL, frame)
            d_ball.size = skin_frame_metrics(.SLIDER_BALL, frame) * (2.0 / SKIN_CIRCLE_REFERENCE_PX)
        }
    }
    
    if d_follow, ok := slotmap.get(&game.beatmap.drawables, gfx.follow); ok {
        scale, alpha := slider_follow_circle_look(hobj, map_time)
        follow_pos := slider_path_pos_at(hobj, clamp(map_time, hobj.start_time_ms, hobj.end_time_ms))
        slider_drawable_update(d_follow, alpha > 0, follow_pos)
        d_follow.start_time_ms = slider.tracked_timestamp_at
        d_follow.size = slider_follow_circle_size(slider) * scale
        d_follow.color.a = u8(0xFF * alpha)
    }

    // note(isak): scorepoint hidden fade
    if .HIDDEN_FADES in hobj.flags {
        fade := u8(f32(0xFF) * hidden_fade)
        fading := [?]Drawable_Handle{
            gfx.end_circle, gfx.end_overlay, gfx.head_circle, gfx.head_overlay,
        }
        for h in fading {
            if d, ok := slotmap.get(&game.beatmap.drawables, h); ok do d.color.a = fade
        }
        for h in gfx.ticks {
            if d, ok := slotmap.get(&game.beatmap.drawables, h); ok do d.color.a = fade
        }
    }
}

slider_render_gfx :: proc(hobj: ^Hitobject, map_time: f64) {
    slider_update_gfx(hobj, map_time)

    gfx := &hobj.slider_state.gfx
    for handle in gfx.ticks {
        d, ok := slotmap.get(&game.beatmap.drawables, handle)
        if ok && .ACTIVE in d.flags {
            render_drawable(d, map_time)
        }
    }
    ordered := [?]Drawable_Handle{
        gfx.end_circle, gfx.end_overlay, gfx.head_circle, gfx.head_overlay,
    }
    for handle in ordered {
        d, ok := slotmap.get(&game.beatmap.drawables, handle)
        if ok && .ACTIVE in d.flags {
            render_drawable(d, map_time)
        }
    }

    // note(isak): a fresh arrow spawns behind the one just hit on the same end
    for end in 0..<2 {
        upcoming := slider_upcoming_repeat_on_end(&hobj.slider_state, end)
        for repeat_index in ([?]int{upcoming, upcoming + 2}) {
            d, ok := slotmap.get(&game.beatmap.drawables, gfx.repeat_arrows[slider_repeat_arrow_slot(repeat_index)])
            if ok && .ACTIVE in d.flags {
                render_drawable(d, map_time)
            }
        }
    }
}

// note(isak): the tracking gfx (head click animation, follow circle, ball) draws after the object's
// gfx_handles so it stacks above the sliderhead, while staying inside the object's cluster slot -
// concurrent sliders keep their cluster ordering, unlike stable's global ball lift
slider_render_tracking_gfx :: proc(hobj: ^Hitobject, map_time: f64) {
    gfx := &hobj.slider_state.gfx
    ordered := [?]Drawable_Handle{gfx.clicked_circle, gfx.clicked_overlay, gfx.follow, gfx.ball}
    for handle in ordered {
        d, ok := slotmap.get(&game.beatmap.drawables, handle)
        if ok && .ACTIVE in d.flags {
            render_drawable(d, map_time)
        }
    }
}


// note(isak): extracts up to 4 decimal digits of n into buf (most-significant first), returns count
write_combo_digits :: proc(buf: ^[6]int, n: int) -> (count: int) {
    v := max(n, 1)
    for v > 0 && count < 6 {
        buf[count] = v % 10
        v /= 10
        count += 1
    }
    // reverse to most-significant-first order
    for i in 0..<count/2 {
        buf[i], buf[count-1-i] = buf[count-1-i], buf[i]
    }
    return count
}

bg_dim_apply :: proc(dim: f32) {
    d, ok := slotmap.get(&game.beatmap.drawables, game.beatmap.bg_handle)
    if !ok do return
    v := u8(255 * (1 - clamp(dim, 0, 1)))
    d.color = {v, v, v, 255}
}

create_bg_drawable :: proc(bg_path, shader_name: string) -> (result: Drawable_Handle) {
    tex, ok := mapset_texture(bg_path)
    if ok {
        bg_aspect_ratio := f32(tex.h) / f32(tex.w)
        bg_size := vec2{PLAYFIELD_SIZE_OSUPX, PLAYFIELD_SIZE_OSUPX} / {(bg_aspect_ratio), 1}
        
        if window.aspect_ratio <= bg_aspect_ratio {
            bg_size *= (window.rect.w / bg_size.x)
        } else {
            bg_size *= (window.rect.h / bg_size.y)
        }
        bg_size *= PLAYFIELD_SIZE_OSUPX / window.rect.h
        
        return drawable_new_expiring(&game.beatmap.map_expiring_gfx, {
            flags = {.ACTIVE},
            element = element_new({
                tex = mapset_texture_slot_or_else(bg_path, builtin_texture(.WHITE)),
                shader = mapset_pipeline_slot_or_else(shader_name, builtin_pipeline_slot(.QUAD))
            }),
            layer = layer_id(.BACKGROUND),
    
            pos = vec2{256, 256} - PLAYFIELD_BASE_TRANSLATION_OSUPX,
            size = bg_size,
            anchor = .CENTER,
            color = {255, 255, 255, 255},
            
            start_time_ms = game.beatmap.start_time_ms - 1000,
            end_time_ms = game.beatmap.length_ms + 1000
        })
    }
    return result
}

// note(isak): threshold is in map-time ms, doesn't adjust for beatmap rate (for osu parity)
hitobject_dim_factor :: proc(hit_time_ms, at_time: f64) -> f32 {
    undim_start := hit_time_ms - OSU_HITOBJECT_DIM_UNTIL_MS
    t := f32(clamp((at_time - undim_start) / OSU_HITOBJECT_DIM_FADE_MS, 0, 1))
    return math.lerp(OSU_HITOBJECT_DIM_FACTOR, 1, t)
}
