package inso

import q "core:container/queue"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import sb "swap_buffer"
import "slotmap"

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

// note(isak): a 0..1 value that chases a bool target over duration_s. t stays linear and tweens
// apply at sample time, so a mid-flight reversal retraces the same eased curve with no extra state
Transition :: struct {
    t: f32,
}

transition_update :: proc(tr: ^Transition, on: bool, duration_s: f32) {
    step := f32(game.dt) / 1000 / duration_s
    tr.t = clamp(tr.t + (step if on else -step), 0, 1)
}

transition_value :: proc(tr: Transition, tween: Tween = .LINEAR) -> f32 {
    return tween_apply(tween, tr.t)
}

transition_mix :: proc(tr: Transition, from, to: f32, tween: Tween = .LINEAR) -> f32 {
    return math.lerp(from, to, transition_value(tr, tween))
}

// note(isak): how an Animation_Color result is applied against the drawable's current color.
// REPLACE:  output = animated_color. ignores drawable.color entirely
// MULTIPLY: output = drawable.color * animated_color / 255 per channel.
//           useful for tint/dim effects that should work regardless of the base color
Color_Blend_Type :: enum u8 {
    REPLACE,
    MULTIPLY,
}

Animation_Variant :: enum {
    TRANSLATE,
    TRANSLATE_X,
    TRANSLATE_Y,
    SCALE,
    SCALE_X,
    SCALE_Y,
    ROTATE,
    COLOR,
    ALPHA,
    TEXTURE,
}

animation_variant :: proc(anim: Animation) -> (result: Animation_Variant) {
    switch v in anim {
    case Animation_Translate:   result = .TRANSLATE
    case Animation_Translate_X: result = .TRANSLATE_X
    case Animation_Translate_Y: result = .TRANSLATE_Y
    case Animation_Scale:       result = .SCALE
    case Animation_Scale_X:     result = .SCALE_X
    case Animation_Scale_Y:     result = .SCALE_Y
    case Animation_Rotate:      result = .ROTATE
    case Animation_Color:       result = .COLOR
    case Animation_Alpha:       result = .ALPHA
    case Animation_Texture:     result = .TEXTURE
    }
    return result
}

Base_Animation :: struct {
    tween: Tween,
    start_time, end_time: f64, // note(isak): [0,1] range
}

Animation :: union #align(4) {
    Animation_Translate,
    Animation_Translate_X,
    Animation_Translate_Y,
    Animation_Scale,
    Animation_Scale_X,
    Animation_Scale_Y,
    Animation_Rotate,
    Animation_Color,
    Animation_Alpha,
    Animation_Texture,
}

Animation_Translate :: struct {
    using base: Base_Animation,
    start_pos, end_pos: vec2,
}
Animation_Translate_X :: struct {
    using base: Base_Animation,
    start_x, end_x: f32,
}
Animation_Translate_Y :: struct {
    using base: Base_Animation,
    start_y, end_y: f32,
}
Animation_Scale :: struct {
    using base: Base_Animation,
    start_scale, end_scale: vec2,
}
Animation_Scale_X :: struct {
    using base: Base_Animation,
    start_scale_x, end_scale_x: f32,
}
Animation_Scale_Y :: struct {
    using base: Base_Animation,
    start_scale_y, end_scale_y: f32,
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

Animation_Time_Domain :: enum {
    NORMALIZED,       // note(isak): [0,1] across the drawable's lifetime
    MILLISECONDS,     // note(isak): ms since the drawable's start
    MAP_MILLISECONDS, // note(isak): absolute map time, like an osu storyboard
}

Animation_List :: struct {
    at, num_animations: uint,
    time_domain: Animation_Time_Domain,
    loop_period_ms: f64, // note(isak): 0 = loop over extent instead
    extent: f64,         // note(isak): highest end_time in the list, in time_domain units
}

Animation_List_ID :: distinct u32 // note(isak): 0 = none, resolving to the empty list kept at slot 0

Script_Animation_List :: struct {
    id: Animation_List_ID,
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

    JUDGEMENT_GOOD_KATU,
    JUDGEMENT_MARVELOUS_KATU,
    JUDGEMENT_MARVELOUS_GEKI,

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
    type: Element_Type, // note(isak): just for debug purposes
    flags: Element_Flags,

    shader: Pipeline_ID,
    render_target: Framebuffer_ID, // note(isak): 0 == DEFAULT, falls through to the layer's capture target
    ssbo: u32,
    ssbo_size: int,
    index_count: u32,

    tex: u32,
    uv: Rect, // note(isak): UV sub-rect in [0,1] space; {0,0,1,1} = full texture
    animation_list: Animation_List_ID,
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
    // use for child drawables (e.g. digits) whose pos is an offset in radius units
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

    // note(isak): lifetime stays with its expiring buffer, but the draw happens elsewhere (e.g. a
    // slider's click animation renders in the object's cluster slot so the ball can stack above it).
    // the expiring pass only checks liveness for these
    OWNER_DRAWN,

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

    animation_list: Animation_List_ID, // note(isak): element override
    uv: Rect, // note(isak): element override. UV sub-rect in [0,1] space; {0,0,1,1} = full texture
    uv_angle_rad: f32,
    tex: u32, // note(isak): element override

    // note(isak): index+1 into game.beatmap.hitobjects. 0 = no associated hitobject.
    // when set, d.size is stored in radius units and multiplied by hitobject_radius_osupx at render time.
    hobj_index: int,
}


//////////////////////////////////////////////////////
// note(isak): animation api

animation_new :: proc(anims: ^q.Queue(Animation), lists: ^q.Queue(Animation_List), elems: ..Animation) -> Animation_List_ID {
    return animation_new_in_domain(anims, lists, .NORMALIZED, ..elems)
}

animation_new_in_domain :: proc(anims: ^q.Queue(Animation), lists: ^q.Queue(Animation_List), domain: Animation_Time_Domain, elems: ..Animation) -> Animation_List_ID {
    at := anims.len
    q.append_elems(anims, ..elems)

    list := Animation_List{ at = at, num_animations = anims.len - at, time_domain = domain }
    for &elem in elems {
        list.extent = max(list.extent, (cast(^Base_Animation)&elem).end_time)
    }
    q.append(lists, list)
    return Animation_List_ID(lists.len - 1)
}

// note(isak): normalized timings always loop over its whole [0,1] range, so loop_period_ms (being ms) has
// nothing to say there
animation_loop_period :: proc(list: ^Animation_List) -> (result: f64) {
    switch list.time_domain {
    case .NORMALIZED:
        result = 1
    case .MILLISECONDS, .MAP_MILLISECONDS:
        result = list.loop_period_ms if list.loop_period_ms != 0 else list.extent
    }
    return result
}

animation_list :: proc(id: Animation_List_ID) -> ^Animation_List {
    return q.get_ptr(&game.beatmap.animation_lists, uint(id))
}

animation_list_entries :: proc(list: ^Animation_List) -> []Animation {
    return game.beatmap.animations.data[list.at:list.at + list.num_animations]
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

// note(isak): 1 exactly on the beat, easing off to 0 right before the next. extrapolates the
// current uninherited timing point in both directions, so it keeps pulsing before the first red line
beat_proximity_factor :: proc(at_time_ms: f64, tween: Tween = .QUAD_OUT) -> f32 {
    timing_point := &game.active_map.timing_points[game.beatmap.current_timing_point_index_uninherited]
    beat_length := max(timing_point.beat_length, 1)
    beat_progress := math.mod(at_time_ms - timing_point.time, beat_length) / beat_length
    if beat_progress < 0 do beat_progress += 1
    return 1 - tween_apply(tween, f32(beat_progress))
}

// note(isak): back/elastic tweens overshoot [0,1] on purpose; clamping here keeps the u8 cast
// from wrapping (u8(285.0) == 29) while geometric animations keep their overshoot
lerp_color_channel :: proc(from, to: u8, t: f32) -> u8 {
    return u8(clamp(linalg.lerp(f32(from), f32(to), t), 0, 255))
}

render_drawable :: proc(d: ^Drawable, at_time: f64, parent_pos: vec2 = {0,0}) {
    if at_time < d.start_time_ms || d.end_time_ms < at_time {
        return
    }
    if .HIDDEN in d.flags {
        return
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

    list := animation_list(d.animation_list)
    if list.num_animations == 0 {
        list = animation_list(element.animation_list)
    }
    animations := animation_list_entries(list)

    duration := d.end_time_ms - d.start_time_ms
    effective_rate := d.animation_rate if d.animation_rate != 0 else 1.0
    anim_time_at: f64
    switch list.time_domain {
    case .NORMALIZED:       anim_time_at = relative_time_at / duration * effective_rate
    case .MILLISECONDS:     anim_time_at = relative_time_at * effective_rate
    case .MAP_MILLISECONDS: anim_time_at = at_time
    }
    if .LOOP_ANIMATION in d.flags {
        period := animation_loop_period(list)
        if period > 0 {
            anim_time_at = math.mod(anim_time_at, period)
        }
    }

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

            case Animation_Translate_X:
                offset_x := linalg.lerp(anim.start_x, anim.end_x, t) * current_radius
                rect.x = pos_x + parent_pos.x + phys_x + offset_x

            case Animation_Translate_Y:
                offset_y := linalg.lerp(anim.start_y, anim.end_y, t) * current_radius
                rect.y = pos_y + parent_pos.y + phys_y + offset_y

            case Animation_Scale:
                rect.w = d.size.x * current_radius * linalg.lerp(anim.start_scale.x, anim.end_scale.x, t)
                rect.h = d.size.y * current_radius * linalg.lerp(anim.start_scale.y, anim.end_scale.y, t)

            case Animation_Scale_X:
                rect.w = d.size.x * current_radius * linalg.lerp(anim.start_scale_x, anim.end_scale_x, t)

            case Animation_Scale_Y:
                rect.h = d.size.y * current_radius * linalg.lerp(anim.start_scale_y, anim.end_scale_y, t)

            case Animation_Rotate:
                angle = linalg.lerp(anim.start_angle, anim.end_angle, t)

            case Animation_Color:
                lerped := Color{
                    lerp_color_channel(anim.start_color.r, anim.end_color.r, t),
                    lerp_color_channel(anim.start_color.g, anim.end_color.g, t),
                    lerp_color_channel(anim.start_color.b, anim.end_color.b, t),
                    lerp_color_channel(anim.start_color.a, anim.end_color.a, t),
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
                color.a = u8(clamp(linalg.lerp(anim.start_alpha, anim.end_alpha, t), 0, 1) * 0xFF)
                
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
        // note(isak): fade_ref_ms can precede start_time_ms (hitobject starting before the
        // drawable); a non-positive window means there's nothing to fade over, so skip it
        fade_in_ms := min((fade_ref_ms - d.start_time_ms) * 0.4, 400.0)
        if fade_in_ms > 0 {
            color.a = u8(f32(color.a) * f32(clamp(relative_time_at / fade_in_ms, 0, 1)))
        }
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
            uv_rect, color, tex, angle, uv_layer, uv_angle = d.uv_angle_rad)
    }
}

process_and_draw_expiring_gfx_refs :: proc(expiring_gfx_refs: ^sb.Swap_Buffer(Drawable_Handle)) {
    map_time := beatmap_music_time_ms(&game.beatmap)
    for handle in expiring_gfx_refs.current {
        e := slotmap.get(&game.beatmap.drawables, handle) or_continue
        still_alive := .ACTIVE in e.flags && map_time <= e.end_time_ms
        if still_alive {
            if .OWNER_DRAWN not_in e.flags {
                render_drawable(e, map_time)
            }
            sb.append_next(expiring_gfx_refs, handle)
        } else {
            slotmap.remove(&game.beatmap.drawables, handle)
            lua_unregister_events_for_handle(.DRAWABLE, transmute(u64)handle)
        }
    }
    sb.swap(expiring_gfx_refs)
}
