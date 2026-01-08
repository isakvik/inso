package notosu

import "core:container/queue"
import "core:math/linalg"
import "core:math/ease"


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
}

Animation_Translate :: struct {
    using base: Base_Animation,
    start_pos, end_pos: vec2,
}
Animation_Scale :: struct {
    using base: Base_Animation,
    start_scale, end_scale: vec2,
}
Animation_Color :: struct {
    using base: Base_Animation,
    start_color, end_color: Color,
}
Animation_Rotate :: struct {
    using base: Base_Animation,
    start_angle, end_angle: f32,
}

Element_Type :: enum {
    NONE,

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

    JUDGMENT,
    OTHER // note(isak): may reserve this for some custom map stuff?
}

Element_Flags :: distinct bit_set[Element_Flag; u32]
Element_Flag :: enum {
    ANIMATED
}

Element :: struct {
    id: int,
    type: Element_Type,
    flags: Element_Flags,

    pos: vec2,
    size: vec2,
    anchor: Layout_Anchor,
    color: Color,
    
    start_time, end_time: f64,
}

// mouse buttons
skin_element_for_type_table := #partial [Element_Type]Skin_Element_Type{
    .HIT_CIRCLE           = .HITCIRCLE,
    .HIT_CIRCLE_OVERLAY   = .HITCIRCLEOVERLAY,
    .APPROACH_CIRCLE      = .APPROACHCIRCLE,
    .COMBO_NUMBER         = .COMBO_1,
    .SLIDER_FOLLOW_CIRCLE = .LIGHTING,
}


write_animations :: proc(buf: ^queue.Queue(Animation), elems: ..Animation) -> []Animation {
    temp := buf.len
    for &e in elems {
        switch &v in e {
            case Animation_Translate:   v.variant = .TRANSLATE
            case Animation_Scale:       v.variant = .SCALE
            case Animation_Rotate:      v.variant = .ROTATE
            case Animation_Color:       v.variant = .COLOR
        }
    }
    queue.append_elems(buf, ..elems)

    return buf.data[temp:buf.len]
}

write_default_animations :: proc(buf: ^queue.Queue(Animation), osu_map: ^Osu_Map) {
    end := osu_map.preempt_ms

    game.bound_element_animations[.HIT_CIRCLE] = write_animations(buf, 
        Animation_Scale{
            start_time = 0, 
            end_time = end,
            start_scale = {1, 1}, 
            end_scale = {4, 1}
        }, 
        Animation_Scale{
            start_time = end * 0.5, 
            end_time = end,
            start_scale = {1, 4}, 
            end_scale = {0, 0}
        }, 
        Animation_Rotate{
            start_time = 0, 
            end_time = end,
            start_angle = 0, 
            end_angle = 60
        }, 
        Animation_Rotate{
            start_time = end * 0.5, 
            end_time = end,
            start_angle = 360, 
            end_angle = 300
        }
    )

    game.bound_element_animations[.APPROACH_CIRCLE] = write_animations(buf, Animation_Scale{
        start_time = 0, 
        end_time = end,
        start_scale = {3, 3}, 
        end_scale = {1, 1}
    })
}

write_default_elements_from_map :: proc(buf: ^queue.Queue(Element), osu_map: ^Osu_Map) {
    preempt: f64 = convert_approach_rate_to_preempt_ms(osu_map.diff_approach_rate)
    circle_diameter_osupx := convert_circle_size_to_radius_osupx(osu_map.diff_circle_size) * 2

    final_hobj_time_ms: f64
    i: int
    for &hobj in osu_map.hit_objects {
        hobj.start_time_ms -= preempt
        final_hobj_time_ms = max(final_hobj_time_ms, hobj.end_time_ms)

        hit_circle_el_types := [?]Element_Type{.COMBO_NUMBER, .HIT_CIRCLE_OVERLAY, .HIT_CIRCLE, .APPROACH_CIRCLE}
        for el_type in hit_circle_el_types {
            e := Element{
                type = el_type,
                pos = hobj.pos,
                size = circle_diameter_osupx,
                anchor = .CENTER,
                color = with_alpha(color_white, 1),
                start_time = hobj.start_time_ms,
                end_time = hobj.end_time_ms,
            }
            if el_type == .COMBO_NUMBER {
                e.size.x *= 0.2
                e.size.y *= -0.4
            }
            if el_type == .HIT_CIRCLE || el_type == .APPROACH_CIRCLE {
                e.color = color_purple
            }
            queue.append(buf, e)
        }
    }

    osu_map.length_ms = final_hobj_time_ms + 1000
}


// note(isak): uses relative time in ms (as with game.play_timer_ms)
render_element :: proc(e: ^Element, at_time: f64) {
    if at_time < 0 || e.end_time - e.start_time < at_time {
        return
    }

    rect := Rect{e.pos.x, e.pos.y, e.size.x, e.size.y}
    angle := f32(0)
    color := e.color
    seen_animation_of_type: [Animation_Variant]bool

    #reverse for &anim in game.bound_element_animations[e.type] {
        base := transmute(^Base_Animation)&anim
        if at_time < base.start_time || seen_animation_of_type[base.variant] {
            continue
        }
        t := min(f32((at_time - base.start_time) / (base.end_time - base.start_time)), 1)

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
                color.r = u8(linalg.lerp(f32(a.start_color.r), f32(a.end_color.r), t)*0xFF)
                color.g = u8(linalg.lerp(f32(a.start_color.g), f32(a.end_color.g), t)*0xFF)
                color.b = u8(linalg.lerp(f32(a.start_color.b), f32(a.end_color.b), t)*0xFF)
                color.a = u8(linalg.lerp(f32(a.start_color.a), f32(a.end_color.a), t)*0xFF)
        }
        seen_animation_of_type[base.variant] = true
    }

    skin_element := skin_element_for_type_table[e.type]
    tex := skin_texture(skin_element)

    r_draw_layout_rect(&window.renderer.quad_geometry, rect, e.anchor, color, tex, angle)
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


