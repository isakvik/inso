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


create_default_elements :: proc(elements: ^q.Queue(Element), anims: ^q.Queue(Animation)) {
    q.reserve(elements, len(Element_Type))
    elements.len += len(Element_Type)
    
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

        animations = animation_new(anims, Animation_Scale{
            start_time = 0,
            end_time = 1,
            start_scale = {4, 4},
            end_scale = {1, 1}
        })
    }
    
    judgement_fade_in_end    :: 120.0 / JUDGEMENT_DISPLAY_DURATION
    judgement_fade_out_start :: 500.0 / JUDGEMENT_DISPLAY_DURATION

    judgement_fade_in := Animation_Alpha{
        start_time  = 0, end_time  = judgement_fade_in_end,
        start_alpha = 0, end_alpha = 1,
    }
    judgement_fade_out := Animation_Alpha{
        start_time  = judgement_fade_out_start, end_time = 1,
        start_alpha = 1, end_alpha = 0,
    }

    default_anim_judgement := animation_new(anims,
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
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS)].animations = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_GOOD)].animations      = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_OK)].animations        = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_GOOD_KATU)].animations      = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS_KATU)].animations = default_anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS_GEKI)].animations = default_anim_judgement

    elements.data[builtin_element_slot(.JUDGEMENT_MISS)].animations = animation_new(anims,
        Animation_Scale{
            start_time  = 0, end_time = judgement_fade_in_end,
            start_scale = {2, 2}, end_scale = {1, 1},
        },
        Animation_Translate{
            tween = .CUBIC_IN,
            start_time = 0, end_time = 1,
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
        
        frames := make([]Animation, 2 + frame_count, context.temp_allocator)
        for frame in 0..<frame_count {
            // note(isak): this is a 60fps animation. i don't think i've seen anything else for these
            fps_factor: f64 = 60 / (1000.0 / JUDGEMENT_DISPLAY_DURATION)
            
            frames[frame] = Animation_Texture{
                start_time = f64(frame)     / fps_factor,
                end_time   = f64(frame + 1) / fps_factor,
                texture_id = skin_frame_texture(skin_el, frame),
            }
        }
        frames[frame_count]     = judgement_fade_in
        frames[frame_count + 1] = judgement_fade_out
        elements.data[builtin_element_slot(el_type)].animations = animation_new(anims, ..frames)
    }


    anim_hit := animation_new(anims, 
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
        elements.data[builtin_element_slot(el)].animations = anim_hit
    }

    elements.data[builtin_element_slot(.SLIDER_TICK)].animations = animation_new(anims,
        Animation_Scale{
            tween = .LINEAR,
            start_time = 0, end_time = 0.5,
            start_scale = {0, 0}, end_scale = {1.1, 1.1},
        },
        Animation_Scale{
            tween = .LINEAR,
            start_time = 0.5, end_time = 1,
            start_scale = {1.1, 1.1}, end_scale = {1, 1},
        },
    )
    
    elements.data[builtin_element_slot(.SLIDER_FOLLOW_CIRCLE)].animations = animation_new(anims,
        Animation_Scale{
            tween = .QUAD_OUT,
            start_time = 0, end_time = 1,
            start_scale = {1/2.4, 1/2.4}, end_scale = {1, 1},
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

    num_base := num_custom if num_custom > 0 else (len(base) if in_visible_phase else 0)
    total_handles := num_digits + num_base

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
            case .POSTEMPT: phase_end_time = phase_start_time + game.beatmap.timing_windows.ok
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
        
        for i in 0..<hobj.custom_element_nums[phase] {
            el_id := hobj.custom_elements[phase][i]
            el := q.get(&game.beatmap.elements, el_id)

            drawable_color := hitobject_combo_color(hobj) if .USE_COMBO_COLOR in el.flags else color_white
            drawable_flags := Drawable_Flags{.ACTIVE}
            if in_visible_phase do drawable_flags |= {.FADE_IN, .HITOBJECT_DIM}
            
            hobj.gfx_handles[num_digits + i] = drawable_new(Drawable{
                flags         = drawable_flags,
                element       = el_id,
                layer         = .HITOBJECTS,
                pos           = rel_pos,
                size          = {2, 2},
                anchor        = .CENTER,
                color         = drawable_color,
                start_time_ms = phase_start_time,
                end_time_ms   = phase_end_time,
                hobj_index    = hobj.index + 1,
            })
        }
    } else {
        for el_type, i in base {
            el_id := builtin_element_slot(el_type)
            el := q.get(&game.beatmap.elements, el_id)

            drawable_color := hitobject_combo_color(hobj) if .USE_COMBO_COLOR in el.flags else color_white

            drawable_flags := Drawable_Flags{.ACTIVE, .FADE_IN}
            if el_type != .APPROACH_CIRCLE do drawable_flags |= {.HITOBJECT_DIM}
            else do drawable_color = with_alpha(drawable_color, 0.9) // note(isak): osu's approach circle alpha multiplier

            end_ms := hobj.start_time_ms + (game.beatmap.timing_windows.ok if el_type != .APPROACH_CIRCLE else 0)
            hobj.gfx_handles[num_digits + i] = drawable_new(Drawable{
                flags         = drawable_flags,
                element       = el_id,
                layer         = .HITOBJECTS,
                pos           = vec2{0, 0},
                size          = skin_element_size_radius_units(el_type),
                anchor        = .CENTER,
                color         = drawable_color,
                start_time_ms = hobj.start_time_ms - preempt,
                end_time_ms   = end_ms,
                hobj_index    = hobj.index + 1,
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
            hobj.gfx_handles[di] = drawable_new(Drawable{
                flags         = {.ACTIVE, .FADE_IN, .SCALE_POS_BY_RADIUS, .HITOBJECT_DIM},
                element       = builtin_element_slot(Element_Type(int(Element_Type.COMBO_DIGIT_0) + digits[di])),
                layer         = .HITOBJECTS,
                pos           = {x_norm + digit_size_norm.x / 2, 0},
                size          = digit_size_norm,
                anchor        = .CENTER,
                color         = with_alpha(color_white, 1),
                start_time_ms = hobj.start_time_ms - preempt,
                end_time_ms   = hobj.start_time_ms + game.beatmap.timing_windows.ok,
                hobj_index    = hobj.index + 1,
            })
            x_norm += digit_size_norm.x - overlap_norm
        }
    }
}

hitcircle_create_default_hit_drawables :: proc(hobj: ^Hitobject, pos: vec2, map_time: f64, sliderend: bool) {
    if .HIDDEN_BY_SCRIPT in hobj.flags {
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
        layer = .HITOBJECTS,
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
            layer = .HITOBJECTS,
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

    fade_out_ms := f64(OSU_HIT_ANIMATION_LENGTH)
    fade_out := clamp((hobj.end_time_ms + fade_out_ms - map_time) / fade_out_ms, 0, 1)

    return f32(min(fade_in, fade_out))
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

        if window.intel_gpu {
            // note(isak): on intel opengl drivers, a scissored glClear ignores ClipControl(UPPER_LEFT).
            // pre-flip against the atlas height so the command's own y-flip cancels back to top-left
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
slider_drawable_new :: proc(hobj: ^Hitobject, part: Slider_Part, size_radius_units: vec2, color: Color, flags: Drawable_Flags = {}) -> Drawable_Handle {
    return drawable_new(Drawable{
        flags         = flags,
        element       = slider_part_element(hobj, part),
        layer         = .HITOBJECTS,
        size          = size_radius_units,
        anchor        = .CENTER,
        color         = color,
        start_time_ms = hobj.start_time_ms - hitobject_preempt_ms(hobj),
        end_time_ms   = hobj.end_time_ms,
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
    follow_size  := vec2{2, 2} * f32(slider.follow_circle_radius_mult)

    gfx := &slider.gfx
    gfx.end_circle   = slider_drawable_new(hobj, .END,           end_size,     combo,       {.FADE_IN, .HITOBJECT_DIM})
    gfx.end_overlay  = slider_drawable_new(hobj, .END_OVERLAY,   overlay_size, color_white, {.FADE_IN, .HITOBJECT_DIM})
    gfx.head_circle  = slider_drawable_new(hobj, .END,           end_size,     combo,       {.FADE_IN, .HITOBJECT_DIM})
    gfx.head_overlay = slider_drawable_new(hobj, .END_OVERLAY,   overlay_size, color_white, {.FADE_IN, .HITOBJECT_DIM})
    gfx.end_repeat   = slider_drawable_new(hobj, .REPEAT,        repeat_size, color_white, {.BEAT_PULSE})
    gfx.head_repeat  = slider_drawable_new(hobj, .REPEAT,        repeat_size, color_white, {.BEAT_PULSE})
    gfx.follow       = slider_drawable_new(hobj, .FOLLOW_CIRCLE, follow_size, color_white)

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
    case .REPEAT:        update(gfx.end_repeat, element);  update(gfx.head_repeat, element)
    case .END:           update(gfx.end_circle, element);  update(gfx.head_circle, element)
    case .END_OVERLAY:   update(gfx.end_overlay, element); update(gfx.head_overlay, element)
    case .TICK:          for h in gfx.ticks do update(h, element)
    }
}

slider_clear_handles :: proc(hobj: ^Hitobject) {
    gfx := &hobj.slider_state.gfx
    handles := [?]Drawable_Handle{
        gfx.ball, gfx.follow, gfx.end_circle, gfx.end_overlay, gfx.end_repeat,
        gfx.head_circle, gfx.head_overlay, gfx.head_repeat,
    }
    for h in handles   {
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

slider_update_gfx :: proc(hobj: ^Hitobject, map_time: f64) {
    slider := &hobj.slider_state
    gfx := &slider.gfx
    path := &game.beatmap.slider_paths[hobj.slider_path_index]

    hobj_pos := hitobject_pos(hobj)
    end_pos  := path.end_pos + hobj.script_pos_translation
    snake_full := slider_snake_in_factor(hobj) >= 1

    current_span := slider.checked_repeats_count
    last_span := slider.path_travel_count - 1
    for tick, tick_i in gfx.ticks {
        d, ok := slotmap.get(&game.beatmap.drawables, tick)
        if ok {
            span := current_span + (1 if slider.tick_hits[tick_i] else 0)
            active := span <= last_span
            tick_pos := slider_path_pos_at(hobj, hobj.start_time_ms + f64(tick_i + 1) * slider.tick_interval_ms)
            
            slider_drawable_update(d, active, tick_pos)
            if active {
                // note(isak): we reuse the tick graphics from the current travel for the next one to emulate osu
                pop_at := slider_tick_popin_time(hobj, tick_i + 1, span)
                d.start_time_ms = pop_at
                d.animation_rate = (d.end_time_ms - pop_at) / SLIDER_TICK_POP_MS
            }
        }
    }

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

    has_repeat_at_end := slider.path_travel_count > 1 && current_span < last_span &&
        (slider.path_travel_count % 2 == 0 || current_span < slider.path_travel_count - 2)
    slider_handle_update(gfx.end_repeat, has_repeat_at_end && snake_full, end_pos, path.end_angle_rad)

    has_repeat_at_head := slider.path_travel_count > 2 && current_span < last_span &&
        (slider.path_travel_count % 2 == 1 || current_span < slider.path_travel_count - 2)
    slider_handle_update(gfx.head_repeat, has_repeat_at_head && hobj.start_time_ms <= map_time, hobj_pos, path.head_angle_rad)

    ball_active := hobj.start_time_ms <= map_time && map_time < hobj.end_time_ms
    ball_pos := slider_path_pos_at(hobj, map_time) if ball_active else vec2{}
    slider_handle_update(gfx.ball,   ball_active, ball_pos, ball_active ? slider_ball_angle_at(hobj, map_time) : 0)

    ball_frame_count := game.active_skin.elements[.SLIDER_BALL].frame_count
    if ball_frame_count > 1 {
        if d_ball, ok := slotmap.get(&game.beatmap.drawables, gfx.ball); ok {
            frame := int((map_time - hobj.start_time_ms) / slider_ball_frame_delay_ms(hobj)) %% ball_frame_count
            d_ball.tex  = skin_frame_texture(.SLIDER_BALL, frame)
            d_ball.size = skin_frame_metrics(.SLIDER_BALL, frame) * (2.0 / SKIN_CIRCLE_REFERENCE_PX)
        }
    }
    
    if d_follow, ok := slotmap.get(&game.beatmap.drawables, gfx.follow); ok {
        slider_drawable_update(d_follow, ball_active && .TRACKING in slider.flags, ball_pos)
        if .TRACKING in slider.flags {
            d_follow.start_time_ms = slider.tracked_timestamp_at
            d_follow.animation_rate = (d_follow.end_time_ms - slider.tracked_timestamp_at) / SLIDER_FOLLOW_CIRCLE_POP_MS
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
        gfx.end_repeat, gfx.head_repeat,
    }
    for handle in ordered {
        d, ok := slotmap.get(&game.beatmap.drawables, handle)
        if ok && .ACTIVE in d.flags {
            render_drawable(d, map_time)
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
            layer = .BACKGROUND,
    
            pos = vec2{256, 256} - playfield_base_translation_osupx,
            size = bg_size,
            anchor = .CENTER,
            color = {255, 255, 255, 255},
            
            start_time_ms = game.beatmap.start_time_ms - 1000,
            end_time_ms = game.beatmap.length_ms + 1000
        })
    }
    return result
}
