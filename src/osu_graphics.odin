package notosu

import "base:intrinsics"
import q "core:container/queue"
import "core:math/linalg"
import "core:slice"

import rb "ring_buffer"
import sb "swap_buffer"
import "slotmap"


// note(isak): texture id lookup table for skin elements
skin_element_for_type_table := #partial #sparse [Element_Type]Skin_Element_Type{
    .HIT_CIRCLE = .HITCIRCLE,
    .HIT_CIRCLE_OVERLAY = .HITCIRCLEOVERLAY,
    .APPROACH_CIRCLE = .APPROACHCIRCLE,
    .COMBO_NUMBER = .COMBO_1,
    .JUDGEMENT = .LIGHTING,
}

//////////////////////////////////////////////////////
// note(isak): core types

Tween :: enum {
    LINEAR,
    ACCELERATE,
    DECELERATE,
    SMOOTH,
    SLEEP
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
    start_time, end_time: f64,
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
}
Animation_Alpha :: struct {
    using base: Base_Animation,
    start_alpha, end_alpha: f32
}
Animation_Texture :: struct {
    using base: Base_Animation,
    texture_id: u32,
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
    SLIDER_END_CIRCLE,
    SLIDER_TICK,
    SLIDER_PATH,

    CLICKED_HIT_CIRCLE,
    CLICKED_HIT_CIRCLE_OVERLAY,
    JUDGEMENT,
    
    CUSTOM_ELEMENT
}

Element_ID :: u32
Element :: struct {
    type: Element_Type, // note(isak): this is just for debug purposes
    
    shader: Pipeline_ID,
    static_geometry: bool,
    ssbo: u32,
    index_count: u32,
    
    tex: u32,
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
    angle_deg: f32,
    anchor: Layout_Anchor,
    color: Color,
    
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
// note(isak): animation api

element_new :: proc(el: Element) -> (result: Element_ID) {
    result = Element_ID(game.beatmap.elements.len)
    el := el
    el.type = .CUSTOM_ELEMENT
    q.append(&game.beatmap.elements, el)
    return result
}

write_default_elements :: proc(elements: ^q.Queue(Element), anims: ^q.Queue(Animation)) {
    ar_ms := game.beatmap.preempt_ms

    q.reserve(elements, len(Element_Type))
    elements.len += len(Element_Type)
    
    for el_type in Element_Type {
        elements.data[el_type].tex = skin_texture(skin_element_for_type_table[el_type])
    }

    elements.data[builtin_element_slot(.HIT_CIRCLE)] = {
        tex = skin_texture(.HITCIRCLE),

        animations = animation_new(anims, 
            Animation_Scale{
                start_time = 0,
                end_time = ar_ms * 0.5,
                start_scale = {1, 1}, 
                end_scale = {4, 1}
            }, 
            Animation_Scale{
                start_time = ar_ms * 0.5, 
                end_time = ar_ms,
                start_scale = {4, 1}, 
                end_scale = {0, 0}
            }, 
            Animation_Rotate{
                start_time = 0, 
                end_time = ar_ms,
                start_angle = 0, 
                end_angle = 180
            }, 
        )
    }
    
    elements.data[builtin_element_slot(.APPROACH_CIRCLE)] = {
        tex = skin_texture(.APPROACHCIRCLE),

        animations = animation_new(anims, Animation_Scale{
            start_time = 0, 
            end_time = ar_ms,
            start_scale = {3, 3}, 
            end_scale = {0.9, 0.9}
        })
    }
    
    elements.data[builtin_element_slot(.JUDGEMENT)] = {
        tex = skin_texture(.LIGHTING),

        animations = animation_new(anims, 
            Animation_Scale{
                start_time = 0, 
                end_time = 600,
                start_scale = {0.5, 0.5}, 
                end_scale = {1.5, 1.5}
            },
            Animation_Alpha{
                start_time = 300, 
                end_time = 600,
                start_alpha = 1.0,
                end_alpha = 0.0,
            }
        )
    }
    
    
    click_animation := animation_new(anims, 
        Animation_Scale{
            start_time = 0,
            end_time = 250,
            start_scale = {1, 1}, 
            end_scale = {1.5, 1.5}
        },
        Animation_Alpha{
            start_time = 0,
            end_time = 250,
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

clear_hitobject_drawables :: proc(hobj: ^Hit_Object) {
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

write_default_drawables_from_map :: proc(osu_map: ^Osu_Map) {
    for &hobj in game.beatmap.hit_objects {
        hit_circle_el_types := [?]Element_Type{.COMBO_NUMBER, .HIT_CIRCLE_OVERLAY, .HIT_CIRCLE, .APPROACH_CIRCLE}
        hobj.gfx_handles = reserve_handles(&game.beatmap.persistent_gfx, len(hit_circle_el_types)) or_continue
        #reverse for el_type, i in hit_circle_el_types {
            e := Drawable{
                flags = {.ACTIVE},
                element = builtin_element_slot(el_type),
                layer = .HIT_OBJECTS,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = with_alpha(color_white, 1),
                start_time_ms = hobj.start_time_ms - game.beatmap.preempt_ms,
                end_time_ms = hobj.start_time_ms,
            }
            if el_type == .COMBO_NUMBER {
                e.size.x *= 0.2
                e.size.y *= 0.4
            }
            if el_type == .HIT_CIRCLE || el_type == .APPROACH_CIRCLE {
                e.color = color_purple
            }
            
            hobj.gfx_handles[i] = drawable_new(e)
        }
    }
}

render_drawable :: proc(e: ^Drawable, at_time: f64, parent_pos: vec2 = {0,0}) -> bool {
    if at_time < e.start_time_ms {
        return true
    }
    if e.end_time_ms < at_time {
        return false
    }
    rel_time := at_time - e.start_time_ms

    element := &game.beatmap.elements.data[e.element]
    tex := element.tex

    rect := Rect{e.pos.x + parent_pos.x, e.pos.y + parent_pos.y, e.size.x, e.size.y}
    angle := e.angle_deg + e.angle_vel * f32(rel_time / 1000)
    color := e.color
    texture_override: bool
    seen_animation_of_type: [Animation_Variant]bool

    #reverse for &anim in game.beatmap.elements.data[e.element].animations {
        base := cast(^Base_Animation)&anim
        if rel_time < base.start_time || seen_animation_of_type[animation_variant(anim)] {
            continue
        }

        t := f32((rel_time - base.start_time) / (base.end_time - base.start_time))
        t = min(t, 1)

        switch a in anim {
            case Animation_Translate:
                rect.x = linalg.lerp(a.start_pos.x, a.end_pos.x, t)
                rect.y = linalg.lerp(a.start_pos.y, a.end_pos.y, t)

            case Animation_Scale:
                rect.w = e.size.x * linalg.lerp(a.start_scale.x, a.end_scale.x, t)
                rect.h = e.size.y * linalg.lerp(a.start_scale.y, a.end_scale.y, t)

            case Animation_Rotate:
                angle = linalg.lerp(a.start_angle, a.end_angle, t)

            case Animation_Color:
                color.r = u8(linalg.lerp(f32(a.start_color.r), f32(a.end_color.r), t))
                color.g = u8(linalg.lerp(f32(a.start_color.g), f32(a.end_color.g), t))
                color.b = u8(linalg.lerp(f32(a.start_color.b), f32(a.end_color.b), t))
                color.a = u8(linalg.lerp(f32(a.start_color.a), f32(a.end_color.a), t))
                
            case Animation_Alpha:
                color.a = u8(linalg.lerp(a.start_alpha, a.end_alpha, t) * 0xFF)
                
            case Animation_Texture:
                texture_override = true
                tex = a.texture_id
        }
        seen_animation_of_type[animation_variant(anim)] = true
    }

    r_check_and_bind_pipeline({element.shader})
    r_check_and_bind_layer(e.layer)
    r_draw_layout_rect(&window.renderer.quad_geometry, rect, e.anchor, color, tex, angle)
    
    return true
}

process_and_draw_expiring_gfx_refs :: proc(expiring_gfx_refs: ^sb.Swap_Buffer(Drawable_Handle)) {
    for handle in expiring_gfx_refs.current {
        e := slotmap.get(&game.beatmap.drawables, handle) or_continue
        if .ACTIVE in e.flags {
            still_alive := render_drawable(e, game.beatmap.music_time_ms)
            if still_alive {
                append(expiring_gfx_refs.next, handle)
            } else {
                slotmap.remove(&game.beatmap.drawables, handle)
            }
        } else {
            slotmap.remove(&game.beatmap.drawables, handle)
        }
    }
    sb.swap(expiring_gfx_refs)
}

slider_screenspace_bounding_box :: proc(slider: ^Slider_Path) -> (result: Rect) {
    r := game.beatmap.circle_radius_osupx
    pad := f32(2)
    result = {
        slider.bounds_min.x - r,
        slider.bounds_min.y - r,
        slider.bounds_max.x - slider.bounds_min.x + r * 2,
        slider.bounds_max.y - slider.bounds_min.y + r * 2,
    }
    result = transform_playfield_rect_to_screenspace(result)
    result.x, result.y = result.x - pad, result.y - pad
    result.w, result.h = result.w + pad*2, result.h + pad*2
    return result
}

render_slider :: proc(renderer: ^Renderer, hobj: ^Hit_Object) {
    slider := &game.beatmap.slider_paths[hobj.slider_path_index]
    pf_size: f32 = playfield_size_osupx / game.beatmap.circle_radius_osupx

    slider_translation := -hobj.script_pos_translation / 2
    x, y := slider_translation.x / pf_size, slider_translation.y / pf_size
    
    pf_rect := Rect{x, y, pf_size,pf_size}
    slider_pf_transform := transform_from_bounds(rect_to_array(pf_rect), window.aspect_ratio)
    
    slider_rect := slider_screenspace_bounding_box(slider)
    slider_uvs := Rect{
        slider_rect.x / window.rect.w,
        slider_rect.y / window.rect.h,
        slider_rect.w / window.rect.w,
        slider_rect.h / window.rect.h,
    }
    
    r_begin_scissor_mode(slider_rect)
    
    r_push_transform(slider_pf_transform)
    r_bind_pipeline({builtin_pipeline_slot(.SLIDER)})
    r_bind_framebuffer({ write = .SLIDERS })
    r_bind_ssbo(&window.circle_geo_buffer, .VERTEX_BUFFER)
    
    r_clear()
    
    slider_snake_in_time_ms := game.beatmap.preempt_ms * (1.0/3.0)
    slider_snake_in_time_at := game.beatmap.music_time_ms - hobj.start_time_ms + game.beatmap.preempt_ms
    slider_snake_instances := i32(f64(slider.instance_count) * clamp(slider_snake_in_time_at / slider_snake_in_time_ms, 0, 1))
    
    command_push_draw_slider(Command_Draw_Slider{
        base_instance = u32(slider.first_instance_at),
        instance_count = slider_snake_instances
    })
    
    r_bind_framebuffer({ read = .SLIDERS })
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_bind_pipeline({builtin_pipeline_slot(.QUAD)})
    
    r_push_transform(window.screenspace_transform)
    {
        // note(isak): debug bounds drawing
        r_reset_scissor_mode()
        r_draw_rect_outline(&renderer.quad_geometry, slider_rect, color_cyan, 1)
    }
    r_begin_scissor_mode(slider_rect)
    
    r_draw_rect_with_uv(&renderer.quad_geometry, 
                        slider_rect,
                        slider_uvs,
                        with_alpha(color_white, 0.5), 
                        builtin_texture(.SLIDER_FRAMEBUFFER))
    r_reset_scissor_mode()
}

test_bg_drawable :: proc(bg_path, shader_name: string) -> (result: Drawable_Handle) {
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
