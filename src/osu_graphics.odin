package inso

import "vendor:wasm/WebGL"
import "base:runtime"
import "base:intrinsics"
import q "core:container/queue"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
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
    metrics := game.active_skin.elements[skin_element_for_type_table[el_type]].metrics
    if metrics.x == 0 do return {2, 2}
    return metrics * (2.0 / SKIN_CIRCLE_REFERENCE_PX)
}

//////////////////////////////////////////////////////
// note(isak): core types

// note(isak): this mirrors ease.Ease right now, but it's fine in case we wanna expand this later
Tween :: enum {
    LINEAR,
    QUAD_IN,     QUAD_OUT,     QUAD_IN_OUT,
    CUBIC_IN,    CUBIC_OUT,    CUBIC_IN_OUT,
    QUARTIC_IN,  QUARTIC_OUT,  QUARTIC_IN_OUT,
    QUINTIC_IN,  QUINTIC_OUT,  QUINTIC_IN_OUT,
    SINE_IN,     SINE_OUT,     SINE_IN_OUT,
    EXPO_IN,     EXPO_OUT,     EXPO_IN_OUT,
    BACK_IN,     BACK_OUT,     BACK_IN_OUT,
    ELASTIC_OUT,
    BOUNCE_OUT,
}

tween_apply :: proc(tween: Tween, t: f32) -> f32 {
    switch tween {
    case .LINEAR:         return t
    case .QUAD_IN:        return ease.quadratic_in(t)
    case .QUAD_OUT:       return ease.quadratic_out(t)
    case .QUAD_IN_OUT:    return ease.quadratic_in_out(t)
    case .CUBIC_IN:       return ease.cubic_in(t)
    case .CUBIC_OUT:      return ease.cubic_out(t)
    case .CUBIC_IN_OUT:   return ease.cubic_in_out(t)
    case .QUARTIC_IN:     return ease.quartic_in(t)
    case .QUARTIC_OUT:    return ease.quartic_out(t)
    case .QUARTIC_IN_OUT: return ease.quartic_in_out(t)
    case .QUINTIC_IN:     return ease.quintic_in(t)
    case .QUINTIC_OUT:    return ease.quintic_out(t)
    case .QUINTIC_IN_OUT: return ease.quintic_in_out(t)
    case .SINE_IN:        return ease.sine_in(t)
    case .SINE_OUT:       return ease.sine_out(t)
    case .SINE_IN_OUT:    return ease.sine_in_out(t)
    case .EXPO_IN:        return ease.exponential_in(t)
    case .EXPO_OUT:       return ease.exponential_out(t)
    case .EXPO_IN_OUT:    return ease.exponential_in_out(t)
    case .BACK_IN:        return ease.back_in(t)
    case .BACK_OUT:       return ease.back_out(t)
    case .BACK_IN_OUT:    return ease.back_in_out(t)
    case .ELASTIC_OUT:    return ease.elastic_out(t)
    case .BOUNCE_OUT:     return ease.bounce_out(t)
    }
    return t
}

// note(isak): how an Animation_Color result is applied against the drawable's current color.
// REPLACE:  output = animated_color. ignores drawable.color entirely
// MULTIPLY: output = drawable.color * animated_color / 255 per channel.
//           useful for tint/dim effects that should work regardless of the base color -
//           e.g. dimming approach circles before click time while preserving their combo color
Color_Blend_Type :: enum u8 {
    REPLACE,
    MULTIPLY,
}

Animation_Variant :: enum {
    TRANSLATE,
    SCALE,
    ROTATE,
    COLOR,
    ALPHA,
    TEXTURE,
}

animation_variant :: proc(anim: Animation) -> (result: Animation_Variant) {
    switch v in anim {
    case Animation_Translate: result = .TRANSLATE
    case Animation_Scale:     result = .SCALE
    case Animation_Rotate:    result = .ROTATE
    case Animation_Color:     result = .COLOR
    case Animation_Alpha:     result = .ALPHA
    case Animation_Texture:   result = .TEXTURE
    }
    return result
}

Base_Animation :: struct {
    tween: Tween,
    start_time, end_time: f64, // note(isak): [0,1] range
}

Animation :: union #align(4) {
    Animation_Translate,
    Animation_Scale,
    Animation_Rotate,
    Animation_Color,
    Animation_Alpha,
    Animation_Texture,
}

Animation_Translate :: struct {
    using base: Base_Animation,
    start_pos, end_pos: vec2,
}
Animation_Scale :: struct {
    using base: Base_Animation,
    start_scale, end_scale: vec2,
}
Animation_Rotate :: struct {
    using base: Base_Animation,
    start_angle, end_angle: f32,
}
Animation_Color :: struct {
    using base: Base_Animation,
    start_color, end_color: Color,
    blend: Color_Blend_Type,
}
Animation_Alpha :: struct {
    using base: Base_Animation,
    start_alpha, end_alpha: f32
}
Animation_Texture :: struct {
    using base: Base_Animation,
    texture_id: u32,
    layer: f32, // note(isak): array layer index; 0 for single-layer textures
}

Script_Animation_List :: struct {
    at, num_animations: uint,
}


// note(isak): builtin element types
Element_Type :: enum {
    NULL,

    HIT_CIRCLE,
    HIT_CIRCLE_OVERLAY,
    APPROACH_CIRCLE,
    COMBO_NUMBER,
    LIGHTING,

    SLIDER_BALL,
    SLIDER_FOLLOW_CIRCLE,
    SLIDER_TICK,
    SLIDER_REPEAT,
    SLIDER_PATH,
    SLIDER_END,
    SLIDER_END_OVERLAY,

    FOLLOWPOINT,

    CLICKED_HIT_CIRCLE,
    CLICKED_HIT_CIRCLE_OVERLAY,
    FINISHED_SLIDER_END_CIRCLE,
    FINISHED_SLIDER_END_CIRCLE_OVERLAY,

    // note(isak): skins with sliderstartcircle use it for slider heads instead of the hitcircle pair
    SLIDER_START_CIRCLE,
    SLIDER_START_CIRCLE_OVERLAY,
    CLICKED_SLIDER_START_CIRCLE,
    CLICKED_SLIDER_START_CIRCLE_OVERLAY,

    JUDGEMENT_MISS,
    JUDGEMENT_OK,
    JUDGEMENT_GOOD,
    JUDGEMENT_MARVELOUS,

    COMBO_DIGIT_0,
    COMBO_DIGIT_1,
    COMBO_DIGIT_2,
    COMBO_DIGIT_3,
    COMBO_DIGIT_4,
    COMBO_DIGIT_5,
    COMBO_DIGIT_6,
    COMBO_DIGIT_7,
    COMBO_DIGIT_8,
    COMBO_DIGIT_9,

    CUSTOM_ELEMENT
}

Element_Flags :: distinct bit_set[Element_Flag; u32]
Element_Flag :: enum u32 {
    USE_COMBO_COLOR,
    STATIC_GEOMETRY,
}

Element_ID :: u32
Element :: struct {
    type: Element_Type, // note(isak): this is just for debug purposes
    flags: Element_Flags,

    shader: Pipeline_ID,
    render_target: Framebuffer_ID, // note(isak): 0 == DEFAULT, falls through to the layer's capture target
    ssbo: u32,
    ssbo_size: int,
    index_count: u32,

    tex: u32,
    uv: Rect, // note(isak): UV sub-rect in [0,1] space; {0,0,1,1} = full texture
    animations: []Animation,
}

builtin_element_slot :: proc(el_type: Element_Type) -> Element_ID {
    return Element_ID(el_type)
}

user_element_slot :: proc(slot: u32) -> Element_ID {
    return Element_ID(len(Element_Type) + slot)
}


Drawable_Flags :: distinct bit_set[Drawable_Flag; u32]
Drawable_Flag :: enum u32 {
    ACTIVE,
    LOOP_ANIMATION,
    
    // note(isak): when hobj_index is set, also scales d.pos by the hitobject's current radius. 
    // use for child drawables (e.g. digits) whose pos is an offset in radius units, not for world-space 
    // positioned drawables
    SCALE_POS_BY_RADIUS, 

    // note(isak): fades alpha from 0 to 1 over the first 40% of the drawable's lifetime (capped at 400ms).
    // set on preempt-phase drawables so they fade in using baked timing, not live hitobject preempt.
    FADE_IN,

    // note(isak): fades alpha from 1 to 0 over the last OSU_HIT_ANIMATION_LENGTH ms before end_time_ms.
    FADE_OUT,

    // note(isak): visually dim the drawable before its start time
    HITOBJECT_DIM,

    // note(isak): the quad covers the whole render target (size is derived each frame), while pos
    // still nudges it in osupx. handy for compositing a screen-sized capture without size math.
    FULLSCREEN,

    // note(isak): visibility flag
    HIDDEN,

    // note(isak): scales size up to BEAT_PULSE_MAX_SCALE on every beat, easing back down before the
    // next one (osu's reverse arrow pulse). syncs to the current uninherited timing point.
    BEAT_PULSE,
}

BEAT_PULSE_MAX_SCALE :: f32(1.3)

Drawable_Handle :: slotmap.Handle

// note(isak): graphical entity that is pushed to the renderer
Drawable :: struct {
    id: int,
    flags: Drawable_Flags,
    element: Element_ID,
    layer: Layer,

    // note(isak): quad params
    // todo(isak): implicitly 1 quad vertex, 6 indices that are appended to buffer every draw. this might need 
    // rethinking if we want to support arbitrary geometry... or maybe just recommend using a frame and
    // drawing to that directly somehow
    pos: vec2,
    size: vec2,
    angle_rad: f32,
    anchor: Layout_Anchor,
    color: Color,
    animation_rate: f64,
    
    vel: vec2,
    accel: vec2,
    angle_vel: f32,
    
    start_time_ms, end_time_ms: f64,

    animations: []Animation, // note(isak): animation override
    uv: Rect, // note(isak): element override. UV sub-rect in [0,1] space; {0,0,1,1} = full texture
    tex: u32, // note(isak): element override

    // note(isak): index+1 into game.beatmap.hitobjects. 0 = no associated hitobject.
    // when set, d.size is stored in radius units and multiplied by hitobject_radius_osupx at render time.
    hobj_index: int,
}


//////////////////////////////////////////////////////
// note(isak): animation api

animation_new :: proc(buf: ^q.Queue(Animation), elems: ..Animation) -> []Animation {
    temp := buf.len
    q.append_elems(buf, ..elems)
    return buf.data[temp:buf.len]
}

//////////////////////////////////////////////////////
// note(isak): element api

element_new :: proc(el: Element) -> (result: Element_ID) {
    result = Element_ID(game.beatmap.elements.len)
    el := el
    el.type = .CUSTOM_ELEMENT
    q.append(&game.beatmap.elements, el)
    return result
}

create_default_elements :: proc(elements: ^q.Queue(Element), anims: ^q.Queue(Animation)) {
    q.reserve(elements, len(Element_Type))
    elements.len += len(Element_Type)
    
    for el_type in Element_Type {
        elements.data[el_type].type = el_type
        elements.data[el_type].tex = 
            skin_texture(skin_render_element(game.active_skin, skin_element_for_type_table[el_type]))
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

        // note(isak): osu parity - approachScale = 1 + 3 * (delta / preempt), reaching exactly 1 at hit time
        animations = animation_new(anims, Animation_Scale{
            start_time = 0,
            end_time = 1,
            start_scale = {4, 4},
            end_scale = {1, 1}
        })
    }
    
    anim_judgement := animation_new(anims,
        Animation_Scale{
            tween = .QUAD_OUT,
            start_time  = 0,   
            end_time = 0.2,
            start_scale = {0.8, 0.8}, 
            end_scale = {1.0, 1.0},
        },
        Animation_Alpha{
            start_time  = 0.7, 
            end_time = 1.0,
            start_alpha = 1.0, 
            end_alpha = 0.0,
        },
    )
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS)].animations = anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_GOOD)].animations      = anim_judgement
    elements.data[builtin_element_slot(.JUDGEMENT_OK)].animations        = anim_judgement

    elements.data[builtin_element_slot(.JUDGEMENT_MISS)].animations = animation_new(anims,
        Animation_Alpha{
            start_time  = 0.4, end_time  = 1.0,
            start_alpha = 1.0, end_alpha = 0.0,
        },
    )
    
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

//////////////////////////////////////////////////////
// note(isak): drawable api

drawable_new :: proc(d: Drawable) -> Drawable_Handle {
    d := d
    d.id = game.beatmap.next_drawable_id
    game.beatmap.next_drawable_id += 1
    
    return slotmap.insert(&game.beatmap.drawables, d)
}

drawable_new_expiring :: proc(buf: ^sb.Swap_Buffer(Drawable_Handle), d: Drawable) -> (result: Drawable_Handle) {
    result = drawable_new(d)
    sb.append(buf, result)
    return result
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

    digits: [4]int
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
    draw_overlay := true
    if !sliderend && hobj.type == .SLIDER && game.active_skin.has_sliderstart {
        el_circle  = .CLICKED_SLIDER_START_CIRCLE
        el_overlay = .CLICKED_SLIDER_START_CIRCLE_OVERLAY
        draw_overlay = window.skin_textures[.SLIDER_START_CIRCLE_OVERLAY].tex_id != 0
    }

    combo_color := hitobject_combo_color(hobj)

    // note(isak): expiring gfx render in insertion order, so the circle goes first and the overlay
    // draws on top of it - same stacking as the preempt drawables (which render #reverse'd)
    drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
        flags = {.ACTIVE},
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
    if draw_overlay {
        drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
            flags = {.ACTIVE},
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

// note(isak): 1 exactly on the beat, easing off to 0 right before the next. extrapolates the
// current uninherited timing point in both directions, so it keeps pulsing before the first red line
beat_proximity_factor :: proc(at_time_ms: f64, tween: Tween = .QUAD_OUT) -> f32 {
    timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_uninherited]
    beat_length := max(timing_point.beat_length, 1)
    beat_progress := math.mod(at_time_ms - timing_point.time, beat_length) / beat_length
    if beat_progress < 0 do beat_progress += 1
    return 1 - tween_apply(tween, f32(beat_progress))
}

// note(isak): threshold is in map-time ms, doesn't adjust for beatmap rate (for osu parity)
hitobject_dim_factor :: proc(hit_time_ms, at_time: f64) -> f32 {
    undim_start := hit_time_ms - OSU_HITOBJECT_DIM_UNTIL_MS
    t := f32(clamp((at_time - undim_start) / OSU_HITOBJECT_DIM_FADE_MS, 0, 1))
    return math.lerp(OSU_HITOBJECT_DIM_FACTOR, 1, t)
}

render_drawable :: proc(d: ^Drawable, at_time: f64, parent_pos: vec2 = {0,0}) -> bool {
    if at_time < d.start_time_ms {
        return true
    }
    if d.end_time_ms < at_time {
        return false
    }
    if .HIDDEN in d.flags {
        return true // note(isak): alive, just not drawn this frame
    }
    relative_time_at := at_time - d.start_time_ms

    element := &game.beatmap.elements.data[d.element]
    tex := d.tex if d.tex != 0 else element.tex
    uv_layer: f32

    current_radius: f32 = 1
    fade_ref_ms := d.end_time_ms // note(isak): for FADE_IN, the baked hit time is used if hobj_index is set
    if d.hobj_index != 0 {
        hobj := &game.beatmap.hitobjects[d.hobj_index - 1]
        current_radius = hitobject_radius_osupx(hobj)
        fade_ref_ms = hobj.start_time_ms
    }

    t_sec := f32(relative_time_at / 1000)
    phys_x := d.vel.x * t_sec + 0.5 * d.accel.x * t_sec * t_sec
    phys_y := d.vel.y * t_sec + 0.5 * d.accel.y * t_sec * t_sec
    pos_x := d.pos.x * (current_radius if .SCALE_POS_BY_RADIUS in d.flags else 1)
    pos_y := d.pos.y * (current_radius if .SCALE_POS_BY_RADIUS in d.flags else 1)
    rect := Rect{pos_x + parent_pos.x + phys_x, pos_y + parent_pos.y + phys_y, d.size.x * current_radius, d.size.y * current_radius}

    if .FULLSCREEN in d.flags {
        tl := screenspace_to_playfield_osupx({0, 0})
        br := screenspace_to_playfield_osupx({window.rect.w, window.rect.h})
        rect = {tl.x + rect.x, tl.y + rect.y, br.x - tl.x, br.y - tl.y}
    }

    angle := d.angle_rad + d.angle_vel * t_sec
    color := d.color

    duration := d.end_time_ms - d.start_time_ms
    effective_rate := d.animation_rate if d.animation_rate != 0 else 1.0
    anim_time_at := relative_time_at / duration * effective_rate
    if .LOOP_ANIMATION in d.flags {
        anim_time_at = math.mod(anim_time_at, 1.0)
    }

    animations := d.animations if len(d.animations) > 0 else element.animations
    seen_animation_of_type: [Animation_Variant]bool
    #reverse for &animation in animations {
        base := cast(^Base_Animation)&animation
        if anim_time_at < base.start_time || seen_animation_of_type[animation_variant(animation)] {
            continue
        }

        t := f32((anim_time_at - base.start_time) / (base.end_time - base.start_time))
        t = tween_apply(base.tween, min(t, 1))

        // note(isak): we don't set (override) attributes directly the same way osu SBs work, but i don't like it
        switch anim in animation {
            case Animation_Translate:
                offset := linalg.lerp(anim.start_pos, anim.end_pos, t) * current_radius
                rect.x = pos_x + parent_pos.x + phys_x + offset.x
                rect.y = pos_y + parent_pos.y + phys_y + offset.y

            case Animation_Scale:
                rect.w = d.size.x * current_radius * linalg.lerp(anim.start_scale.x, anim.end_scale.x, t)
                rect.h = d.size.y * current_radius * linalg.lerp(anim.start_scale.y, anim.end_scale.y, t)

            case Animation_Rotate:
                angle = linalg.lerp(anim.start_angle, anim.end_angle, t)

            case Animation_Color:
                lerped := Color{
                    u8(linalg.lerp(f32(anim.start_color.r), f32(anim.end_color.r), t)),
                    u8(linalg.lerp(f32(anim.start_color.g), f32(anim.end_color.g), t)),
                    u8(linalg.lerp(f32(anim.start_color.b), f32(anim.end_color.b), t)),
                    u8(linalg.lerp(f32(anim.start_color.a), f32(anim.end_color.a), t)),
                }
                switch anim.blend {
                case .REPLACE:
                    color = lerped
                case .MULTIPLY:
                    color.r = u8(f32(color.r) * f32(lerped.r) / 255)
                    color.g = u8(f32(color.g) * f32(lerped.g) / 255)
                    color.b = u8(f32(color.b) * f32(lerped.b) / 255)
                    color.a = u8(f32(color.a) * f32(lerped.a) / 255)
                }
                
            case Animation_Alpha:
                color.a = u8(linalg.lerp(anim.start_alpha, anim.end_alpha, t) * 0xFF)
                
            case Animation_Texture:
                tex = anim.texture_id
                uv_layer = anim.layer
        }
        seen_animation_of_type[animation_variant(animation)] = true
    }

    if .BEAT_PULSE in d.flags {
        pulse := math.lerp(f32(1), BEAT_PULSE_MAX_SCALE, beat_proximity_factor(at_time))
        rect.w *= pulse
        rect.h *= pulse
    }
    if .HITOBJECT_DIM in d.flags {
        color = color_scale_rgb(color, hitobject_dim_factor(fade_ref_ms, at_time))
    }
    if .FADE_IN in d.flags {
        fade_in_ms := min((fade_ref_ms - d.start_time_ms) * 0.4, 400.0)
        color.a = u8(f32(color.a) * f32(clamp(relative_time_at / fade_in_ms, 0, 1)))
    }
    if .FADE_OUT in d.flags {
        fade_out_ms := f64(OSU_HIT_ANIMATION_LENGTH)
        color.a = u8(f32(color.a) * f32(clamp((d.end_time_ms - at_time) / fade_out_ms, 0, 1)))
    }

    r_check_and_bind_layer(d.layer)

    // note(isak): a drawable can be emitted into any layer's queue from another layer's recording
    // context, so it can't trust inherited state - it re-establishes everything it draws with.
    // drawables always position in playfield space so a script gets consistent osupx coordinates no
    // matter which layer it targets, and the full-window scissor keeps a never-scissored layer from
    // clipping the draw.
    r_push_transform(game.playfield_transform)
    _r_push_scissor({ 0, 0, i32(window.rect.w), i32(window.rect.h) })
    r_bind_pipeline({ pipeline = element.shader })

    target := element.render_target
    if target == 0 {
        // note(isak): resolve through r_layer_framebuffer so a drawable lands in the same target as
        // the rest of its layer, including the DEFAULT->BACKBUFFER redirect for full-frame-capture
        // maps. binding layer_capture directly punched drawables straight to the screen, bypassing
        // the backbuffer everything else on the layer draws into.
        target = r_layer_framebuffer(d.layer).write
    }
    r_bind_framebuffer({ write = target })

    if .STATIC_GEOMETRY in element.flags {
        r_bind_ssbo_raw(element.ssbo, element.ssbo_size, .VERTEX_BUFFER)
        r_push_draw_mesh(i32(element.index_count))
        // note(isak): restore quad VERTEX_BUFFER for subsequent quad draws
        r_bind_tbo(&window.quad_store, .VERTEX_BUFFER)
    } else {
        r_bind_tbo(&window.quad_store, .VERTEX_BUFFER)

        uv_rect := d.uv
        if uv_rect.w == 0 && uv_rect.h == 0 {
            uv_rect = element.uv
            if uv_rect.w == 0 && uv_rect.h == 0 {
                uv_rect = {0, 0, 1, 1}
            }
        }
        r_draw_rect_with_uv(&window.renderer.quad_geometry,
            rect_translate_by_anchor(rect, d.anchor),
            uv_rect, color, tex, angle, uv_layer)
    }

    return true
}

process_and_draw_expiring_gfx_refs :: proc(expiring_gfx_refs: ^sb.Swap_Buffer(Drawable_Handle)) {
    map_time := beatmap_music_time_ms(&game.beatmap)
    for handle in expiring_gfx_refs.current {
        e := slotmap.get(&game.beatmap.drawables, handle) or_continue
        still_alive := .ACTIVE in e.flags && render_drawable(e, map_time)
        if still_alive {
            sb.append_next(expiring_gfx_refs, handle)
        } else {
            slotmap.remove(&game.beatmap.drawables, handle)
            lua_unregister_events_for_handle(.DRAWABLE, transmute(u64)handle)
        }
    }
    sb.swap(expiring_gfx_refs)
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

// note(isak): the SLIDERS framebuffer is a window-sized atlas of cached body distance fields.
// slots are bump-allocated in rows; when the atlas fills up we reset the whole thing and bump
// the generation, which lazily regenerates every visible body over the following frames - one
// frame of regeneration costs what every frame cost before caching, so resets are cheap.
Slider_Atlas :: struct {
    cur_x, cur_y, row_h: i32,
    generation: u32, // starts at 1 so zero-value Slider_Body_Caches are never valid
}

Slider_Body_Cache :: struct {
    content_rect: Rect, // atlas texels, excluding the cleared gutter around the slot
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

// w and h must each fit the atlas minus the gutter; callers guarantee that by clamping their
// texel density. allocation therefore always succeeds after at most one reset.
slider_atlas_alloc :: proc(w, h: i32) -> (content: Rect) {
    atlas := &window.slider_atlas
    atlas_w := i32(window.rect.w)
    atlas_h := i32(window.rect.h)
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
    bbox_osupx := Rect{
        slider.bounds_min.x - r,
        slider.bounds_min.y - r,
        slider.bounds_max.x - slider.bounds_min.x + r * 2,
        slider.bounds_max.y - slider.bounds_min.y + r * 2,
    }

    // bake at the on-screen texel density so static playfields sample the field 1:1; bodies
    // larger than the atlas bake at whatever density fits (banding stays sharp regardless
    // since the thresholds run on the sampled field)
    texels_per_osupx := min(
        playfield_px_per_osupx(),
        (window.rect.w - 2 * SLIDER_ATLAS_PAD) / bbox_osupx.w,
        (window.rect.h - 2 * SLIDER_ATLAS_PAD) / bbox_osupx.h)

    cache := &hobj.slider_state.body_cache
    stale := cache.generation != window.slider_atlas.generation ||
             cache.baked_first != first_instance ||
             cache.baked_last  != last_instance ||
             abs(cache.texels_per_osupx - texels_per_osupx) > texels_per_osupx * 0.005

    if stale {
        content_w := i32(math.ceil(bbox_osupx.w * texels_per_osupx))
        content_h := i32(math.ceil(bbox_osupx.h * texels_per_osupx))
        if cache.generation != window.slider_atlas.generation ||
           i32(cache.content_rect.w) != content_w || i32(cache.content_rect.h) != content_h {
            cache.content_rect = slider_atlas_alloc(content_w, content_h)
        }
        cache.texels_per_osupx = texels_per_osupx
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
        bake_transform := mat3_to_transform(transform_to_mat3(window.screenspace_transform) * place_atlas_px * cs_to_osupx)

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
            // note(isak): on intel igpus, a scissored glClear ignores ClipControl(UPPER_LEFT)
            r_set_scissor_mode(
                i32(slot_rect.x),
                i32(window.rect.h - slot_rect.y - slot_rect.h),
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
    translation := hobj.script_pos_translation
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

    // uvs cover the exact fractional field extent, not the ceil'd slot, so texels map 1:1
    atlas_uvs := Rect{
        cache.content_rect.x / window.rect.w,
        cache.content_rect.y / window.rect.h,
        bbox_osupx.w * texels_per_osupx / window.rect.w,
        bbox_osupx.h * texels_per_osupx / window.rect.h,
    }
    body_rect := Rect{
        bbox_osupx.x + translation.x,
        bbox_osupx.y + translation.y,
        bbox_osupx.w,
        bbox_osupx.h,
    }

    // note(isak): dimming the composite tint dims border and body together, mirroring HITOBJECT_DIM
    // the same way slider_body_alpha mirrors FADE_IN/FADE_OUT
    body_tint := color_scale_rgb(color_white, hitobject_dim_factor(hobj.start_time_ms, map_time))
    r_push_transform(game.playfield_transform)
    r_draw_rect_with_uv(&renderer.quad_geometry,
                        body_rect,
                        atlas_uvs,
                        with_alpha(body_tint, slider_body_alpha(hobj, map_time)),
                        builtin_texture(.SLIDER_FRAMEBUFFER))
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
    gfx.ball         = slider_drawable_new(hobj, .BALL,          ball_size,   combo)

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

    has_sliderend_at_end := slider.path_travel_count % 2 == 1 || current_span < last_span
    end_on := has_sliderend_at_end && snake_full
    snake_done_ms := hobj.start_time_ms - hitobject_preempt_ms(hobj) * (2.0/3.0)
    slider_handle_update(gfx.end_circle,  end_on, end_pos, fade_start_ms = snake_done_ms)
    slider_handle_update(gfx.end_overlay, end_on, end_pos, fade_start_ms = snake_done_ms)

    has_sliderend_at_head := slider.path_travel_count > 1 &&
        (slider.path_travel_count % 2 == 0 || current_span < last_span)
    head_on := has_sliderend_at_head && hobj.start_time_ms <= map_time
    slider_handle_update(gfx.head_circle,  head_on, hobj_pos)
    slider_handle_update(gfx.head_overlay, head_on, hobj_pos)

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
            frame := int(map_time / SLIDER_BALL_ANIMATION_LOOP_MS * f64(ball_frame_count)) %% ball_frame_count
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
        gfx.end_repeat, gfx.head_repeat, gfx.follow, gfx.ball,
    }
        
    for handle in ordered {
        d, ok := slotmap.get(&game.beatmap.drawables, handle)
        if ok && .ACTIVE in d.flags {
            render_drawable(d, map_time)
        }
    }
}


// note(isak): extracts up to 4 decimal digits of n into buf (most-significant first), returns count
write_combo_digits :: proc(buf: ^[4]int, n: int) -> (count: int) {
    v := max(n, 1)
    for v > 0 && count < 4 {
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

TEST_bg_drawable :: proc(bg_path, shader_name: string) -> (result: Drawable_Handle) {
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
            
            start_time_ms = game.beatmap.start_time_ms,
            end_time_ms = game.beatmap.length_ms
        })
    }
    return result
}
