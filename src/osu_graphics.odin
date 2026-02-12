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
    .JUDGMENT = .LIGHTING,
}

//////////////////////////////////////////////////////
// note(isak): core types

Graphics_Object :: struct {
    num_entities, first_entity_at: int
}

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

Base_Animation :: struct {
    variant: Animation_Variant,
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


Element_Type :: enum {
    NULL,
    MAP_ELEMENT,

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
    JUDGMENT,
}

Element_ID :: u32
Element :: struct {
    type: Element_Type,
    shader: Pipeline_ID,
    static_geometry: bool,
    ssbo: u32,
    index_count: u32,
    
    tex: u32,
    animations: []Animation,
}

element_id :: proc(el_type: Element_Type) -> Element_ID {
    return Element_ID(el_type)
}


Entity_Flags :: distinct bit_set[Entity_Flag; u32]
Entity_Flag :: enum u32 {
    ACTIVE,
}

// note(isak): 
Entity :: struct {
    id: int,
    flags: Entity_Flags,
    element: Element_ID,

    // note(isak): quad params
    // implicitly: 1 quad vertex, 6 indices that are appended to buffer every draw
    pos: vec2,
    size: vec2,
    angle_deg: f32,
    anchor: Layout_Anchor,
    color: Color,
    
    vel: vec2,
    accel: vec2,
    angle_vel: f32,
    
    start_time_ms, end_time_ms: f64,
}


//////////////////////////////////////////////////////
// note(isak): animation api

animation_push :: proc(buf: ^q.Queue(Animation), elems: ..Animation) -> []Animation {
    temp := buf.len
    for &e in elems {
        switch &v in e {
            case Animation_Translate:   v.variant = .TRANSLATE
            case Animation_Scale:       v.variant = .SCALE
            case Animation_Color:       v.variant = .COLOR
            case Animation_Alpha:       v.variant = .ALPHA
            case Animation_Rotate:      v.variant = .ROTATE
            case Animation_Texture:     v.variant = .TEXTURE
        }
    }
    q.append_elems(buf, ..elems)

    return buf.data[temp:buf.len]
}

//////////////////////////////////////////////////////
// note(isak): animation api

element_push :: proc(buf: ^q.Queue(Element), el: Element) -> Element_ID {
    q.append(buf, el)
    return Element_ID(buf.len) - 1
}

write_default_elements :: proc(elements: ^q.Queue(Element), anims: ^q.Queue(Animation)) {
    ar_ms := game.beatmap.preempt_ms

    q.reserve(elements, len(Element_Type))
    elements.len += len(Element_Type)
    
    for el_type in Element_Type {
        elements.data[el_type].tex = skin_texture(skin_element_for_type_table[el_type])
    }

    elements.data[element_id(.HIT_CIRCLE)] = {
        tex = skin_texture(.HITCIRCLE),

        animations = animation_push(anims, 
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
    
    elements.data[element_id(.APPROACH_CIRCLE)] = {
        tex = skin_texture(.APPROACHCIRCLE),

        animations = animation_push(anims, Animation_Scale{
            start_time = 0, 
            end_time = ar_ms,
            start_scale = {3, 3}, 
            end_scale = {0.9, 0.9}
        })
    }
    
    elements.data[element_id(.JUDGMENT)] = {
        tex = skin_texture(.LIGHTING),

        animations = animation_push(anims, 
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
    
    
    click_animation := animation_push(anims, 
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
    
    elements.data[element_id(.CLICKED_HIT_CIRCLE)] = {
        tex = skin_texture(.HITCIRCLE),
        animations = click_animation
    }
    
    elements.data[element_id(.CLICKED_HIT_CIRCLE_OVERLAY)] = {
        tex = skin_texture(.HITCIRCLEOVERLAY),
        animations = click_animation
    }
    
    for el_type in Element_Type {
        elements.data[el_type].type = el_type
    }
}

//////////////////////////////////////////////////////
// note(isak): entity api

push_entity :: proc(e: Entity) -> slotmap.Handle {
    e := e
    e.id = game.next_entity_id
    game.next_entity_id += 1
    
    return slotmap.insert(&game.entities, e)
}

push_entity_temp :: proc(e: Entity) {
    sb.append(&game.temp_gfx_refs, push_entity(e))
}

clear_hitobject_entities :: proc(hobj: ^Hit_Object) {
    for handle in hobj.gfx_handles {
        slotmap.remove(&game.entities, handle)
    }
    hobj.gfx_handles = {}
}

// note(isak): seeks the entirety of the ring buffer until a contiguous run of n unoccupied handles are found
reserve_handles :: proc(buf: ^rb.Ring_Buffer(slotmap.Handle), #any_int n: int) -> ([]slotmap.Handle, bool) {
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

write_default_entities_from_map :: proc(osu_map: ^Osu_Map) {
    preempt: f64 = convert_approach_rate_to_preempt_ms(osu_map.diff_approach_rate)

    final_hobj_time_ms: f64
    i: int
    for &hobj in game.beatmap.hit_objects {
        final_hobj_time_ms = max(final_hobj_time_ms, hobj.end_time_ms)
        
        hobj.gfx_handles = reserve_handles(&game.gfx_handles, 4) or_continue
        
        hit_circle_el_types := [?]Element_Type{.COMBO_NUMBER, .HIT_CIRCLE_OVERLAY, .HIT_CIRCLE, .APPROACH_CIRCLE}
        #reverse for el_type, i in hit_circle_el_types {
            e := Entity{
                flags = {.ACTIVE},
                element = element_id(el_type),
                pos = hobj.pos,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = with_alpha(color_white, 1),
                start_time_ms = hobj.start_time_ms - preempt,
                end_time_ms = hobj.start_time_ms,
            }
            if el_type == .COMBO_NUMBER {
                e.size.x *= 0.2
                e.size.y *= 0.4
            }
            if el_type == .HIT_CIRCLE || el_type == .APPROACH_CIRCLE {
                e.color = color_purple
            }
            
            hobj.gfx_handles[i] = push_entity(e)
        }
    }
}

render_entity :: proc(e: ^Entity, at_time: f64) -> bool {
    if at_time < e.start_time_ms || e.end_time_ms < at_time {
        return false
    }
    rel_time := at_time - e.start_time_ms

    element := &game.elements.data[e.element]
    tex := element.tex

    rect := Rect{e.pos.x, e.pos.y, e.size.x, e.size.y}
    angle := e.angle_deg + e.angle_vel * f32(rel_time / 1000)
    color := e.color
    texture_override: bool
    seen_animation_of_type: [Animation_Variant]bool

    #reverse for &anim in game.elements.data[e.element].animations {
        base := transmute(^Base_Animation)&anim
        if rel_time < base.start_time || seen_animation_of_type[base.variant] {
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
        seen_animation_of_type[base.variant] = true
    }

    r_check_and_bind_pipeline({element.shader})
    r_draw_layout_rect(&window.renderer.quad_geometry, rect, e.anchor, color, tex, angle)
    
    return true
}

process_and_draw_temp_gfx_handles :: proc() {
    for handle in game.temp_gfx_refs.current {
        e := slotmap.get(&game.entities, handle) or_continue
        if .ACTIVE in e.flags {
            was_in_time := render_entity(e, game.beatmap.music_time_ms)
            if was_in_time {
                append(game.temp_gfx_refs.next, handle)
            } else {
                //fmt.println("temp entity expired", e.id)
            }
        } else {
            //fmt.println("inactive entity", e.id)
        }
    }
    sb.swap(&game.temp_gfx_refs)
}

render_slider :: proc(renderer: ^Renderer, slider: ^Slider_Path) {
    // todo(isak): generate partial instance draws (snaking) and the bounding quads like the smart cookie you are

    r_bind_pipeline({builtin_pipeline(.SLIDER)})
    r_bind_framebuffer({ write = .SLIDERS })    
    r_bind_ssbo(&window.circle_geo_buffer, .VERTEX_BUFFER)
    r_clear()

    pf_size: f32 = osu_playfield_size_osupx / game.beatmap.circle_radius_osupx

    r_push_transform(transform_from_bounds({0,0,pf_size,pf_size}, window.aspect_ratio))

    command_push_draw_slider(Command_Draw_Slider{
        base_instance = u32(slider.first_instance_at),
        instance_count = i32(slider.instance_count)
    })
    
    r_bind_framebuffer({ read = .SLIDERS })
    r_bind_ssbo(&window.quad_store, .VERTEX_BUFFER)
    r_bind_pipeline({builtin_pipeline(.QUAD)})
    
    r_push_transform(fullscreen_transform)
    r_draw_rect(&renderer.quad_geometry, {0, 0, 1, 1}, with_alpha(color_white, 0.4), reserved_texture(.SLIDER_FRAMEBUFFER))
}

test_bg :: proc(bg_path: string) -> slotmap.Handle {
    bg_entity := Entity{
        element = element_push(&game.elements, Element{
            type = .MAP_ELEMENT, 
            tex = mapset_texture(bg_path),
            shader = mapset_shader("wave")
        }),
        flags = {.ACTIVE},

        pos = {0.5, 0.5},
        size = {1, 1},
        anchor = .CENTER,
        color = {30,30,30,255},
        
        start_time_ms = game.beatmap.start_time_ms,
        end_time_ms = game.beatmap.length_ms
    }
    return slotmap.insert(&game.entities, bg_entity)
}

/*
    animation plans

    animation memory use:
    we don't really need unbounded dynamic arrays (i figured the exception might be if a script system would
        add elements with separate animations, but if you're planning on doing something like that you could
        probably just say to reserve 1000 slots for a particle-ish buffer)
    so we just allocate a queue upfront in mapset_arena

    init graphical entities that are drawn in time on the playfield
    both game elements and graphical features animate with the same system
    
    we want several entities from the same game object, since they all use a bunch of different sprites
    approachcircle,
    hitcircle,
    hitcircleoverlay,
    combonumber

    sliderball,
    sliderfollowcircle,

    these are read by some rendering system that reads the animation states for each entity animation
    and pushes the appropriate rect
        this job is parallelizable (subdivision and calculation, writing quad must lock and copy)
    holy

    this is pretty much standard storyboarding; but we can let a map override the pushed elements with
    animations for every element type (one section at a time)
        this only determines the data that's used to generate draws in time, it's just config

    map side api use:

    r_bind_pipeline determines shader used
    before a procedure (pushed draws) runs, bind a shader

    so associate a shader with a group of elements

    setup:
    begin_animation_entity_type(type)
    a_fade(0, 500, 0, 1)
    a_fade(3500, 4000, 1, 0)
    end_animation()
    
    update:
        at time 0, bind_animation(type, animation)
        at time 10000, bind_animation(type, animation2)
    
    we got several groups of what goes into the command queue eventually
        layer delineation - in the script we require blocks of picked layers - easiest option

        shader delineation - we write arbitrary element commands with some bound shader

    we have to somehow sort element draws in a frame by shader
        
    on_update:

    for every shader in a layer:
        bind shader
        determine visible objects and iterate:
            push_element

*/
