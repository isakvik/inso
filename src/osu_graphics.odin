package notosu

import "base:intrinsics"
import q "core:container/queue"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:slice"

import rb "ring_buffer"
import sb "swap_buffer"
import "slotmap"


// note(isak): texture id lookup table for skin elements
skin_element_for_type_table := #partial #sparse [Element_Type]Skin_Element_Type{
    .HIT_CIRCLE         = .HITCIRCLE,
    .HIT_CIRCLE_OVERLAY = .HITCIRCLEOVERLAY,
    .APPROACH_CIRCLE    = .APPROACHCIRCLE,
    .COMBO_NUMBER       = .COMBO_1,

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

Element_ID :: u32
Element :: struct {
    type: Element_Type, // note(isak): this is just for debug purposes

    shader: Pipeline_ID,
    static_geometry: bool,
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
}

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

write_default_elements :: proc(elements: ^q.Queue(Element), anims: ^q.Queue(Animation)) {
    q.reserve(elements, len(Element_Type))
    elements.len += len(Element_Type)
    
    for el_type in Element_Type {
        elements.data[el_type].tex = skin_texture(skin_element_for_type_table[el_type])
    }

    // note(isak): one element per digit glyph, avoids re-creating elements per hitobject
    for d in 0..<10 {
        elements.data[builtin_element_slot(Element_Type(int(Element_Type.COMBO_DIGIT_0) + d))].tex =
            skin_texture(Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + d))
    }

    elements.data[builtin_element_slot(.HIT_CIRCLE)] = {
        tex = skin_texture(.HITCIRCLE),

        animations = animation_new(anims,
            Animation_Scale{
                start_time = 0,
                end_time = 0.5,
                start_scale = {1, 1}, 
                end_scale = {4, 1}
            }, 
            Animation_Scale{
                start_time = 0.5, 
                end_time = 1,
                start_scale = {4, 1}, 
                end_scale = {0, 0}
            }, 
            Animation_Rotate{
                start_time = 0,
                end_time = 1,
                start_angle = 0, 
                end_angle = math.PI/2
            }, 
        )
    }
    
    elements.data[builtin_element_slot(.APPROACH_CIRCLE)] = {
        tex = skin_texture(.APPROACHCIRCLE),

        animations = animation_new(anims, Animation_Scale{
            start_time = 0, 
            end_time = 1,
            start_scale = {3, 3}, 
            end_scale = {0.9, 0.9}
        })
    }
    
    elements.data[builtin_element_slot(.JUDGEMENT_MARVELOUS)] = {
        tex = skin_texture(.LIGHTING),

        animations = animation_new(anims, 
            Animation_Scale{
                start_time = 0, 
                end_time = 1,
                start_scale = {0.5, 0.5}, 
                end_scale = {1.5, 1.5}
            },
            Animation_Alpha{
                start_time = 0.5, 
                end_time = 1,
                start_alpha = 1.0,
                end_alpha = 0.0,
            }
        )
    }
    
    
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
    
    for el_type in Element_Type {
        elements.data[el_type].type = el_type
    }
}

//////////////////////////////////////////////////////
// note(isak): drawable api

Drawable_Handle :: slotmap.Handle

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

clear_hitobject_drawables :: proc(hobj: ^Hitobject) {
    for handle in hobj.gfx_handles {
        slotmap.remove(&game.beatmap.drawables, handle)
    }
    hobj.gfx_handles = {}
}

// note(isak): seeks the entirety of the ring buffer until a contiguous run of n unoccupied handles are found
reserve_handles :: proc(buf: ^rb.Ring_Buffer(Drawable_Handle), #any_int n: int) -> ([]Drawable_Handle, bool) {
    at: int 
    has_contiguous_space: bool
    for !has_contiguous_space && at < cap(buf.data) {
        found_active_el: bool
        for i in 0..<n {
            handle := rb.at(buf, buf.cursor + at + i)
            if handle.index > 0 {
                at += i + 1
                found_active_el = true
                break
            }
        }
        has_contiguous_space = !found_active_el
    }
    // todo(isak): needs eviction strategy in case of important elements (use another element flag for this)
    assert(has_contiguous_space)
    
    if has_contiguous_space {
        buf.cursor += at
        return slice.from_ptr(rb.at(buf, buf.cursor), n), true
    }
    return slice.from_ptr(rb.at(buf, buf.cursor), 0), false
}

render_drawable :: proc(d: ^Drawable, at_time: f64, parent_pos: vec2 = {0,0}, alpha_mul: f32 = 1.0) -> bool {
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

    t_sec := f32(relative_time_at / 1000)
    phys_x := d.vel.x * t_sec + 0.5 * d.accel.x * t_sec * t_sec
    phys_y := d.vel.y * t_sec + 0.5 * d.accel.y * t_sec * t_sec
    rect := Rect{d.pos.x + parent_pos.x + phys_x, d.pos.y + parent_pos.y + phys_y, d.size.x, d.size.y}
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

        // note(isak): we don't set attributes directly the same way osu SBs work, but i don't like it
        switch anim in animation {
            case Animation_Translate:
                rect.x = d.pos.x * linalg.lerp(anim.start_pos.x, anim.end_pos.x, t)
                rect.y = d.pos.y * linalg.lerp(anim.start_pos.y, anim.end_pos.y, t)

            case Animation_Scale:
                rect.w = d.size.x * linalg.lerp(anim.start_scale.x, anim.end_scale.x, t)
                rect.h = d.size.y * linalg.lerp(anim.start_scale.y, anim.end_scale.y, t)

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

    color.a = u8(f32(color.a) * alpha_mul)

    r_check_and_bind_pipeline({element.shader})
    r_check_and_bind_layer(d.layer)

    if element.static_geometry {
        r_bind_ssbo_raw(element.ssbo, element.ssbo_size, .VERTEX_BUFFER)
        r_push_draw_mesh(i32(element.index_count))
        // note(isak): restore quad VERTEX_BUFFER for subsequent quad draws
        r_bind_tbo(&window.quad_store, .VERTEX_BUFFER)
    } else {
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

slider_screenspace_bounding_box :: proc(slider: ^Slider_Path, translation: vec2 = {}) -> (result: Rect) {
    r := game.beatmap.circle_radius_osupx
    pad := f32(2)
    result = {
        slider.bounds_min.x - r + translation.x,
        slider.bounds_min.y - r + translation.y,
        slider.bounds_max.x - slider.bounds_min.x + r * 2,
        slider.bounds_max.y - slider.bounds_min.y + r * 2,
    }
    result = transform_rect_playfield_to_screenspace(result)
    result.x, result.y = result.x - pad, result.y - pad
    result.w, result.h = result.w + pad*2, result.h + pad*2
    return result
}


render_slider_path :: proc(renderer: ^Renderer, hobj: ^Hitobject, slider: ^Slider_Path) {
    pf_size: f32 = playfield_size_osupx / game.beatmap.circle_radius_osupx
    
    pf_rect := Rect{0, 0, pf_size,pf_size}
    slider_pf_transform := transform_from_bounds(rect_to_array(pf_rect), window.aspect_ratio)
    
    translation := hobj.script_pos_translation
    slider_rect := slider_screenspace_bounding_box(slider, translation)

    slider_uvs := Rect{
        slider_rect.x / window.rect.w,
        slider_rect.y / window.rect.h,
        slider_rect.w / window.rect.w,
        slider_rect.h / window.rect.h,
    }

    r_set_scissor_mode(slider_rect)

    r_push_transform(slider_pf_transform)
    r_bind_pipeline({builtin_pipeline_slot(.SLIDER)})
    r_bind_framebuffer({ write = .SLIDERS })
    r_bind_ssbo(&window.circle_geo_buffer, .VERTEX_BUFFER)

    r_clear(with_alpha(color_black, 0.0))

    slider_snake_instances := max(1, i32(f64(slider.instance_count) * slider_snake_factor(hobj)))

    command_push_draw_slider(Command_Draw_Slider{
        base_instance      = u32(slider.first_instance_at),
        instance_count     = slider_snake_instances,
        border_color       = with_alpha(color_white, 0.9),
        body_color         = with_alpha(color_white, 0.7),
        script_translation = translation,
    })
    
    r_bind_framebuffer({ read = .SLIDERS })
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_bind_pipeline({builtin_pipeline_slot(.QUAD)})
    
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

render_slider_quads :: proc(hobj: ^Hitobject, path: ^Slider_Path, map_time: f64) {
    slider := &hobj.slider_state
    
    // todo(isak): these actually have to be rewritten into drawables for data manipulation purposes, but we
    // can do that later
    
    combo_color := hitobject_combo_color(hobj)
    
    cs := game.beatmap.circle_radius_osupx
    element_scale := (cs*2) / (game.active_skin.elements[.HITCIRCLE].metrics)
    
    hobj_pos := hitobject_pos(hobj)
    end_pos  := path.end_pos + hobj.script_pos_translation
    slider_path_time_at := (map_time - hobj.start_time_ms) - f64(slider.checked_repeats_count) * slider.duration_ms

    // note(isak): slider ticks
    heading_back := slider.checked_repeats_count % 2 == 1
    first_tick_time := heading_back \
        ? slider.duration_ms - slider.tick_interval_ms * f64(slider.tick_count) \
        : slider.tick_interval_ms

    ticks_to_draw := slider.tick_count
    for ticks_to_draw > 0 && slider_path_time_at <= first_tick_time + f64(ticks_to_draw - 1) * slider.tick_interval_ms {
        tick_size := element_scale * game.active_skin.elements[.SLIDER_TICK].metrics
        forward_tick_index := heading_back ? (slider.tick_count + 1 - ticks_to_draw) : ticks_to_draw
        tick_pos := slider_path_pos_at(hobj, hobj.start_time_ms + f64(forward_tick_index) * slider.tick_interval_ms)
        tick_rect := rect_at_pos(tick_pos, tick_size)
        r_draw_layout_rect(&window.renderer.quad_geometry, tick_rect, .CENTER, color_white,
            skin_texture(.SLIDER_TICK))

        ticks_to_draw -= 1
    }
    
    
    // note(isak): slider end circles
    has_sliderend_at_end := slider.path_travel_count % 2 == 1 || slider.checked_repeats_count < slider.path_travel_count - 1
    if has_sliderend_at_end && slider_snake_factor(hobj) >= 1 {
        sliderend_rect := rect_at_pos(end_pos, {cs * 2, cs * 2})
        r_draw_layout_rect(&window.renderer.quad_geometry, sliderend_rect, .CENTER, combo_color,
            skin_texture(.SLIDER_END))
        r_draw_layout_rect(&window.renderer.quad_geometry, sliderend_rect, .CENTER, color_white,
            skin_texture(.SLIDER_END_OVERLAY))
    }

    has_sliderend_at_head := slider.path_travel_count > 1 &&
        (slider.path_travel_count % 2 == 0 || slider.checked_repeats_count < slider.path_travel_count - 1)
    if has_sliderend_at_head && hobj.start_time_ms <= map_time {
        sliderend_head_rect := rect_at_pos(hobj_pos, {cs * 2, cs * 2})
        r_draw_layout_rect(&window.renderer.quad_geometry, sliderend_head_rect, .CENTER, combo_color,
            skin_texture(.SLIDER_END))
        r_draw_layout_rect(&window.renderer.quad_geometry, sliderend_head_rect, .CENTER, color_white,
            skin_texture(.SLIDER_END_OVERLAY))
    }

    // note(isak): slider repeat arrows
    has_repeat_at_end := slider.path_travel_count > 1 && slider.checked_repeats_count < slider.path_travel_count - 1 &&
        (slider.path_travel_count % 2 == 0 || slider.checked_repeats_count < slider.path_travel_count - 2)
    if has_repeat_at_end && slider_snake_factor(hobj) >= 1 {
        repeat_size := element_scale * game.active_skin.elements[.SLIDER_REPEAT].metrics
        sliderend_repeat_rect := rect_at_pos(end_pos, repeat_size)
        r_draw_layout_rect(&window.renderer.quad_geometry, sliderend_repeat_rect, .CENTER, color_white,
            skin_texture(.SLIDER_REPEAT), angle = path.end_angle_rad)
    }

    has_repeat_at_head := slider.path_travel_count > 2 && slider.checked_repeats_count < slider.path_travel_count - 1 &&
        (slider.path_travel_count % 2 == 1 || slider.checked_repeats_count < slider.path_travel_count - 2)
    if has_repeat_at_head && hobj.start_time_ms <= map_time {
        repeat_size := element_scale * game.active_skin.elements[.SLIDER_REPEAT].metrics
        sliderend_repeat_rect := rect_at_pos(hobj_pos, repeat_size)
        r_draw_layout_rect(&window.renderer.quad_geometry, sliderend_repeat_rect, .CENTER, color_white,
            skin_texture(.SLIDER_REPEAT), angle = path.head_angle_rad)
    }
    
    // note(isak): slider tracking graphics
    if hobj.start_time_ms <= map_time && map_time < hobj.end_time_ms {
        ball_pos := slider_path_pos_at(hobj, map_time)
        ball_rect := rect_at_pos(ball_pos, element_scale * game.active_skin.elements[.SLIDER_BALL].metrics)
        
        if .TRACKING in hobj.slider_state.flags {
            follow_size := element_scale * game.active_skin.elements[.HITCIRCLE].metrics * SLIDER_FOLLOW_CIRCLE_RADIUS_MULT
            follow_rect := rect_at_pos(ball_pos, follow_size)
            r_draw_layout_rect(&window.renderer.quad_geometry, follow_rect, .CENTER, color_white, skin_texture(.SLIDER_FOLLOW_CIRCLE))
        }
        
        r_draw_layout_rect(&window.renderer.quad_geometry, ball_rect, .CENTER, combo_color, skin_texture(.SLIDER_BALL),
            angle = 0) // todo(isak): slider ball angle needs to be mathed out...
    }
}


// note(isak): extracts up to 4 decimal digits of n into buf (most-significant first), returns count
_combo_digits :: proc(n: int, buf: ^[4]int) -> (count: int) {
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

TEST_write_default_drawables_from_map :: proc(osu_map: ^Osu_Map) {
    for &hobj in game.beatmap.hitobjects {
        if hobj.type != .CIRCLE && hobj.type != .SLIDER {
            continue
        }

        combo_color := hitobject_combo_color(&hobj)

        digits: [4]int
        n_digits := _combo_digits(int(hobj.combo_number), &digits)

        total_handles := n_digits + 3
        hobj.gfx_handles = reserve_handles(&game.beatmap.persistent_gfx, total_handles) or_continue

        // last 3 handles (rendered first, behind digits)
        base := [?]Element_Type{.HIT_CIRCLE_OVERLAY, .HIT_CIRCLE, .APPROACH_CIRCLE}
        for el_type, i in base {
            end_ms := hobj.start_time_ms + (game.beatmap.timing_windows.ok if el_type != .APPROACH_CIRCLE else 0)
            hobj.gfx_handles[n_digits + i] = drawable_new(Drawable{
                flags        = {.ACTIVE},
                element      = builtin_element_slot(el_type),
                layer        = .HITOBJECTS,
                size         = game.beatmap.circle_radius_osupx * 2,
                anchor       = .CENTER,
                color        = (combo_color if el_type == .HIT_CIRCLE || el_type == .APPROACH_CIRCLE else with_alpha(color_white, 1)),
                start_time_ms = hobj.start_time_ms - game.beatmap.preempt_ms,
                end_time_ms   = end_ms,
            })
        }

        // digit drawables. each sized from its own skin metrics, spread and centered on hitobject pos
        // compute total width first so we can center the run
        hc_size := game.active_skin.elements[.HITCIRCLE].metrics
        // how many osupx per natural skin pixel, based on hitcircle fitting circle_radius*2
        number_scale := (game.beatmap.circle_radius_osupx * 2) / max(hc_size.x, 1) * COMBO_NUMBER_SCALE
            
        total_digits_w: f32
        for digit in 0..<n_digits {
            digit_el := Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digits[digit])
            total_digits_w += game.active_skin.elements[digit_el].metrics.x * number_scale
        }
        x := -total_digits_w / 2
        for di in 0..<n_digits {
            digit_el      := Skin_Element_Type(int(Skin_Element_Type.COMBO_0) + digits[di])
            digit_metrics := game.active_skin.elements[digit_el].metrics
            digit_size    := digit_metrics * number_scale
            hobj.gfx_handles[di] = drawable_new(Drawable{
                flags   = {.ACTIVE},
                element = builtin_element_slot(Element_Type(int(Element_Type.COMBO_DIGIT_0) + digits[di])),
                layer   = .HITOBJECTS,
                pos     = {x + digit_size.x / 2, 0},
                size    = digit_size,
                anchor  = .CENTER,
                color   = with_alpha(color_white, 1),
                start_time_ms = hobj.start_time_ms - game.beatmap.preempt_ms,
                end_time_ms   = hobj.start_time_ms + game.beatmap.timing_windows.ok,
            })
            x += digit_size.x
        }
    }
}

TEST_bg_drawable :: proc(bg_path, shader_name: string) -> (result: Drawable_Handle) {
    tex, ok := mapset_texture(bg_path)
    if ok {
        bg_aspect_ratio := f32(tex.h) / f32(tex.w)
        bg_size := vec2{playfield_size_osupx, playfield_size_osupx} / {(bg_aspect_ratio), 1}
        
        if window.aspect_ratio <= bg_aspect_ratio {
            bg_size *= (window.rect.w / bg_size.x)
        } else {
            bg_size *= (window.rect.h / bg_size.y)
        }
        bg_size *= playfield_size_osupx / window.rect.h
        
        return drawable_new_expiring(&game.beatmap.map_expiring_gfx, {
            flags = {.ACTIVE},
            element = element_new({
                tex = mapset_texture_slot_or_else(bg_path, builtin_texture(.WHITE)),
                shader = mapset_pipeline_slot_or_else(shader_name, builtin_pipeline_slot(.QUAD))
            }),
            layer = .BACKGROUND,
    
            pos = {256, 256},
            size = bg_size,
            anchor = .CENTER,
            color = {30,30,30,100},
            
            start_time_ms = game.beatmap.start_time_ms,
            end_time_ms = game.beatmap.length_ms
        })
    }
    return result
}
