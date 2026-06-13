package notosu

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
    .HIT_CIRCLE_OVERLAY = .HITCIRCLEOVERLAY,
    .APPROACH_CIRCLE    = .APPROACHCIRCLE,
    .COMBO_NUMBER       = .COMBO_1,
    .LIGHTING           = .LIGHTING,

    .SLIDER_BALL          = .SLIDER_BALL,
    .SLIDER_FOLLOW_CIRCLE = .SLIDER_FOLLOW_CIRCLE,
    .SLIDER_REPEAT        = .SLIDER_REPEAT,
    .SLIDER_TICK          = .SLIDER_TICK,
    .SLIDER_END           = .SLIDER_END,
    .SLIDER_END_OVERLAY   = .SLIDER_END_OVERLAY,

    .JUDGEMENT_MISS      = .HIT0,
    .JUDGEMENT_OK        = .HIT50,
    .JUDGEMENT_GOOD      = .HIT100,
    .JUDGEMENT_MARVELOUS = .HIT300,
}

//////////////////////////////////////////////////////
// note(isak): core types

// note(isak): this (mostly) mirrors ease.Ease, but it's fine in case we wanna expand this later
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

    CLICKED_HIT_CIRCLE,
    CLICKED_HIT_CIRCLE_OVERLAY,
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

    // note(isak): the quad covers the whole render target (size is derived each frame), while pos
    // still nudges it in osupx. handy for compositing a screen-sized capture without size math.
    FULLSCREEN,
}

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
    
    // todo(isak): these are kinda intuitively made... not integrated into lua yet
    vel: vec2,
    accel: vec2,
    angle_vel: f32,
    
    start_time_ms, end_time_ms: f64,

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
        elements.data[el_type].tex = skin_texture(skin_render_element(skin_element_for_type_table[el_type]))
    }

    for digit in 0..<10 {
        elements.data[builtin_element_slot(Element_Type(int(Element_Type.COMBO_DIGIT_0) + digit))].tex =
            skin_texture(Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digit))
    }

    elements.data[builtin_element_slot(.HIT_CIRCLE)] = {
        tex = skin_texture(.HITCIRCLE),
        flags = {.USE_COMBO_COLOR}
    }
    
    elements.data[builtin_element_slot(.APPROACH_CIRCLE)] = {
        tex = skin_texture(.APPROACHCIRCLE),
        flags = {.USE_COMBO_COLOR},

        animations = animation_new(anims, Animation_Scale{
            start_time = 0, 
            end_time = 1,
            start_scale = {3, 3}, 
            end_scale = {0.9, 0.9}
        })
    }
    
    hit_anims := animation_new(anims,
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
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS)].animations = hit_anims
    elements.data[builtin_element_slot(.JUDGEMENT_GOOD)].animations      = hit_anims
    elements.data[builtin_element_slot(.JUDGEMENT_OK)].animations        = hit_anims

    elements.data[builtin_element_slot(.JUDGEMENT_MISS)].animations = animation_new(anims,
        Animation_Alpha{
            start_time  = 0.4, end_time  = 1.0,
            start_alpha = 1.0, end_alpha = 0.0,
        },
    )
    
    click_animation := animation_new(anims, 
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
    
    elements.data[builtin_element_slot(.CLICKED_HIT_CIRCLE)] = {
        tex = skin_texture(.HITCIRCLE),
        animations = click_animation
    }
    
    elements.data[builtin_element_slot(.CLICKED_HIT_CIRCLE_OVERLAY)] = {
        tex = skin_texture(.HITCIRCLEOVERLAY),
        animations = click_animation
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

    for el_type in Element_Type {
        elements.data[el_type].type = el_type
    }
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
    
    num_base := num_custom if num_custom > 0 else (3 if in_visible_phase else 0)
    total_handles := num_digits + num_base

    if total_handles == 0 do return

    hobj.gfx_handles = make([]Drawable_Handle, total_handles, memory.allocators[.DRAWABLES])

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
            if in_visible_phase do drawable_flags |= {.FADE_IN}
            
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
        base := [?]Element_Type{.HIT_CIRCLE_OVERLAY, .HIT_CIRCLE, .APPROACH_CIRCLE}
        for el_type, i in base {
            el_id := builtin_element_slot(el_type)
            el := q.get(&game.beatmap.elements, el_id)
            
            drawable_color := hitobject_combo_color(hobj) if .USE_COMBO_COLOR in el.flags else color_white
            
            end_ms := hobj.start_time_ms + (game.beatmap.timing_windows.ok if el_type != .APPROACH_CIRCLE else 0)
            hobj.gfx_handles[num_digits + i] = drawable_new(Drawable{
                flags         = {.ACTIVE, .FADE_IN},
                element       = el_id,
                layer         = .HITOBJECTS,
                pos           = vec2{0, 0},
                size          = {2, 2},
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
        hc_size := game.active_skin.elements[.HITCIRCLE].metrics
        number_scale_norm := 2 / max(hc_size.x, 1) * COMBO_NUMBER_SCALE
    
        total_digits_w_norm: f32
        for digit in 0..<num_digits {
            digit_el := Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digits[digit])
            total_digits_w_norm += game.active_skin.elements[digit_el].metrics.x * number_scale_norm
        }
        x_norm := -total_digits_w_norm / 2
        for di in 0..<num_digits {
            digit_el      := Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digits[di])
            digit_metrics := game.active_skin.elements[digit_el].metrics
            digit_size_norm := digit_metrics * number_scale_norm
            hobj.gfx_handles[di] = drawable_new(Drawable{
                flags         = {.ACTIVE, .FADE_IN, .SCALE_POS_BY_RADIUS},
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
            x_norm += digit_size_norm.x
        }
    }
}

hitcircle_create_default_hit_drawables :: proc(hobj: ^Hitobject, pos: vec2, map_time: f64) {
    if .HIDDEN_BY_SCRIPT in hobj.flags {
        return
    }
    
    combo_color := hitobject_combo_color(hobj)

    drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
        flags = {.ACTIVE},
        element = builtin_element_slot(.CLICKED_HIT_CIRCLE_OVERLAY),
        layer = .HITOBJECTS,
        pos = pos,
        size = {2, 2},
        anchor = .CENTER,
        color = color_white,
        start_time_ms = map_time,
        end_time_ms = map_time + OSU_HIT_ANIMATION_LENGTH,
        hobj_index = hobj.index + 1,
    })
    drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
        flags = {.ACTIVE},
        element = builtin_element_slot(.CLICKED_HIT_CIRCLE),
        layer = .HITOBJECTS,
        pos = pos,
        size = {2, 2},
        anchor = .CENTER,
        color = combo_color,
        start_time_ms = map_time,
        end_time_ms = map_time + OSU_HIT_ANIMATION_LENGTH,
        hobj_index = hobj.index + 1,
    })
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
            
            hitcircle_create_default_hit_drawables(hobj, hitobject_pos(hobj), map_time)
            hitobject_create_phase_drawables(hobj, .HOLD, hobj.start_time_ms)
        case .HIT:
            hitobject_clear_drawables(hobj)
            
            // note(isak): custom hit animations override the default circle expanding animation
            if hobj.custom_element_nums[.HIT] == 0 {
                if transition.from == .PREEMPT || transition.from == .POSTEMPT {
                    hitcircle_create_default_hit_drawables(hobj, hitobject_pos(hobj), map_time)
                } else if transition.from == .HOLD {
                    hitcircle_create_default_hit_drawables(hobj, hitobject_tail_pos(hobj), map_time)
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

render_drawable :: proc(d: ^Drawable, at_time: f64, parent_pos: vec2 = {0,0}) -> bool {
    if at_time < d.start_time_ms {
        return true
    }
    if d.end_time_ms < at_time {
        return false
    }
    relative_time_at := at_time - d.start_time_ms

    element := &game.beatmap.elements.data[d.element]
    tex := element.tex
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

    // note(isak): fullscreen derives its size each frame by inverse-mapping the screen corners into
    // playfield osupx, so it covers the render target (resize-safe) while pos stays an osupx nudge.
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

    seen_animation_of_type: [Animation_Variant]bool
    #reverse for &animation in game.beatmap.elements.data[d.element].animations {
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

    if .FADE_IN in d.flags {
        fade_in_ms := min((fade_ref_ms - d.start_time_ms) * 0.4, 400.0)
        color.a = u8(f32(color.a) * f32(clamp(relative_time_at / fade_in_ms, 0, 1)))
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
        target = game.active_mapset.layer_capture[d.layer]
    }
    r_bind_framebuffer({ write = target })

    if .STATIC_GEOMETRY in element.flags {
        r_bind_ssbo_raw(element.ssbo, element.ssbo_size, .VERTEX_BUFFER)
        r_push_draw_mesh(i32(element.index_count))
        // note(isak): restore quad VERTEX_BUFFER for subsequent quad draws
        r_bind_tbo(&window.quad_store, .VERTEX_BUFFER)
    } else {
        r_bind_tbo(&window.quad_store, .VERTEX_BUFFER)

        uv_rect := element.uv
        if uv_rect.w == 0 || uv_rect.h == 0 {
            uv_rect = {0, 0, 1, 1}
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
        if .ACTIVE in e.flags {
            still_alive := render_drawable(e, map_time)
            if still_alive {
                sb.append_next(expiring_gfx_refs, handle)
            } else {
                slotmap.remove(&game.beatmap.drawables, handle)
            }
        } else {
            slotmap.remove(&game.beatmap.drawables, handle)
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


slider_render_path :: proc(renderer: ^Renderer, hobj: ^Hitobject, slider: ^Slider_Path) {
    // note(isak): slider geometry is in CS-normalized units (osupx / radius)
    r := hitobject_radius_osupx(hobj)
    cs_to_osupx := mat3{r, 0, 0, 0, r, 0, 0, 0, 1}
    slider_pf_transform := mat3_to_transform(transform_to_mat3(game.playfield_transform) * cs_to_osupx)

    translation := hobj.script_pos_translation
    slider_rect := slider_screenspace_bounding_box(hobj, slider, translation)

    slider_uvs := Rect{
        slider_rect.x / window.rect.w,
        slider_rect.y / window.rect.h,
        slider_rect.w / window.rect.w,
        slider_rect.h / window.rect.h,
    }

    r_push_transform(slider_pf_transform)
    r_bind_pipeline({ pipeline = builtin_pipeline_slot(.SLIDER) })
    r_bind_framebuffer({ write = builtin_framebuffer(.SLIDERS) })
    r_bind_ssbo(&window.circle_geo_buffer, .VERTEX_BUFFER)

    // note(isak): on intel igpus, a scissored glClear fills the box in raw lower-left framebuffer
    // space, ignoring ClipControl(UPPER_LEFT), while rasterized draws honor it. the SCISSOR_MODE
    // handler's H-y-h flip is calibrated for draws, so the clear lands on the vertically mirrored
    // half (top-of-screen slider clears the bottom), leaving the slider's rows uncleared. nvidia
    // applies the flip to the clear consistently, so it's already correct there. on intel, pre-flip
    // the clear's y so the handler's flip cancels and glClear hits the slider's actual rows, then
    // restore the normal scissor for the body draw below.
    if window.intel_gpu {
        r_set_scissor_mode(
            i32(slider_rect.x),
            i32(window.rect.h - slider_rect.y - slider_rect.h),
            i32(slider_rect.w),
            i32(slider_rect.h))
        r_clear(with_alpha(color_black, 0.0))
        r_set_scissor_mode(slider_rect)
    } else {
        r_set_scissor_mode(slider_rect)
        r_clear(with_alpha(color_black, 0.0))
    }

    slider_snake_instances := max(1, i32(f64(slider.instance_count) * slider_snake_out_factor(hobj)))

    command_push_draw_slider(Command_Draw_Slider{
        base_instance      = u32(slider.first_instance_at),
        instance_count     = slider_snake_instances,
        border_color       = with_alpha(color_white, 0.9),
        body_color         = with_alpha(color_white, 0.7),
        script_translation = translation,
        radius_osupx       = r,
    })
    
    // note(isak): the body composite bypasses render_drawable, so it has to opt into the
    // HITOBJECTS capture target by hand; 0 (no capture) leaves it writing to the screen.
    slider_write_target := game.active_mapset.layer_capture[.HITOBJECTS]
    r_bind_framebuffer({ read = builtin_framebuffer(.SLIDERS), write = slider_write_target })
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_bind_pipeline({ pipeline = builtin_pipeline_slot(.QUAD) })
    
    r_push_transform(window.screenspace_transform)
    if app.debug_display_slider_bounds {
        r_reset_scissor_mode()
        r_draw_rect_outline(&renderer.quad_geometry, slider_rect, color_cyan, 1)
    }
    
    scissor_rect := Rect{
        2 + math.ceil(slider_rect.x),
        2 + math.ceil(slider_rect.y),
        math.floor(slider_rect.w) - 4,
        math.floor(slider_rect.h) - 4,
    }   
    r_set_scissor_mode(scissor_rect)
    
    r_draw_rect_with_uv(&renderer.quad_geometry, 
                        slider_rect,
                        slider_uvs,
                        color_white, 
                        builtin_texture(.SLIDER_FRAMEBUFFER))
    r_reset_scissor_mode()
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
slider_drawable_new :: proc(hobj: ^Hitobject, part: Slider_Part, size_radius_units: vec2, color: Color) -> Drawable_Handle {
    return drawable_new(Drawable{
        element       = slider_part_element(hobj, part),
        layer         = .HITOBJECTS,
        size          = size_radius_units,
        anchor        = .CENTER,
        color         = color,
        start_time_ms = hobj.start_time_ms - hitobject_preempt_ms(hobj),
        end_time_ms   = hobj.end_time_ms + OSU_HIT_ANIMATION_LENGTH,
        hobj_index    = hobj.index + 1,
    })
}

// note(isak): allocates the slider's persistent decoration drawables once, on spawn. sizes and combo color are
// baked here (same as the head/number drawables); per-frame visibility and position come from slider_sync_gfx.
slider_create_gfx :: proc(hobj: ^Hitobject) {
    slider := &hobj.slider_state
    combo := hitobject_combo_color(hobj)

    // note(isak): radius units = osupx size / radius
    radius_scale := vec2{2, 2} / game.active_skin.elements[.HITCIRCLE].metrics
    tick_size   := radius_scale * game.active_skin.elements[.SLIDER_TICK].metrics
    repeat_size := radius_scale * game.active_skin.elements[.SLIDER_REPEAT].metrics
    ball_size   := radius_scale * game.active_skin.elements[.SLIDER_BALL].metrics
    follow_size := vec2{2, 2} * f32(slider.follow_circle_radius_mult)
    end_size    := vec2{2, 2}

    gfx := &slider.gfx
    gfx.end_circle   = slider_drawable_new(hobj, .END,           end_size,    combo)
    gfx.end_overlay  = slider_drawable_new(hobj, .END_OVERLAY,   end_size,    color_white)
    gfx.head_circle  = slider_drawable_new(hobj, .END,           end_size,    combo)
    gfx.head_overlay = slider_drawable_new(hobj, .END_OVERLAY,   end_size,    color_white)
    gfx.end_repeat   = slider_drawable_new(hobj, .REPEAT,        repeat_size, color_white)
    gfx.head_repeat  = slider_drawable_new(hobj, .REPEAT,        repeat_size, color_white)
    gfx.follow       = slider_drawable_new(hobj, .FOLLOW_CIRCLE, follow_size, color_white)
    gfx.ball         = slider_drawable_new(hobj, .BALL,          ball_size,   combo)

    gfx.ticks = make([]Drawable_Handle, slider.tick_count, memory.allocators[.DRAWABLES])
    for i in 0..<slider.tick_count {
        gfx.ticks[i] = slider_drawable_new(hobj, .TICK, tick_size, color_white)
    }
}

// note(isak): sets the lua element override for a slider part and applies it to any already-spawned drawables
// for that part. takes effect immediately mid-slide and is also picked up by slider_create_gfx on respawn.
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
    for h in gfx.ticks {
        if h != {} do slotmap.remove(&game.beatmap.drawables, h)  
    } 
    gfx^ = {}
}


slider_drawable_update :: proc(d: ^Drawable, active: bool, pos: vec2, angle: f32 = 0) {
    if active do d.flags |= {.ACTIVE}
    else      do d.flags &~= {.ACTIVE}
    d.pos = pos
    d.angle_rad = angle
}

slider_handle_update :: proc(h: Drawable_Handle, active: bool, pos: vec2, angle: f32 = 0) {
    d, ok := slotmap.get(&game.beatmap.drawables, h)
    if !ok do return
    slider_drawable_update(d, active, pos, angle)
}

slider_update_gfx :: proc(hobj: ^Hitobject, map_time: f64) {
    slider := &hobj.slider_state
    gfx := &slider.gfx
    path := &game.beatmap.slider_paths[hobj.slider_path_index]

    hobj_pos := hitobject_pos(hobj)
    end_pos  := path.end_pos + hobj.script_pos_translation
    snake_full := slider_snake_out_factor(hobj) >= 1

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
    slider_handle_update(gfx.end_circle,  end_on, end_pos)
    slider_handle_update(gfx.end_overlay, end_on, end_pos)

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

COMBO_NUMBER_SCALE :: f32(0.9)

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
