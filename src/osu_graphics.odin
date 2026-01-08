package notosu

import "core:math/linalg"
import "core:math/ease"


Tween :: enum {
    LINEAR,
    ACCELERATE,
    DECELERATE,
    SMOOTH,
    SLEEP
}


Base_Animation :: struct {
    tween: Tween,
    start_time, end_time: f64,
}

Animation :: union {
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

test_animation: [4]Animation

element_store: [512]Element
test_elements: Buffer(Element)

bound_animations: [Element_Type][]Animation

@init init_bound_animations :: proc "contextless" () {
    test_animation = {
        0 = Animation_Scale{
            start_time = 0, 
            end_time = 1000,
            start_scale = {1, 1}, 
            end_scale = {3, 2}
        },
        1 = Animation_Scale{
            start_time = 1000, 
            end_time = 2000,
            start_scale = {3, 2}, 
            end_scale = {1, 1}
        },
        2 = Animation_Rotate{
            start_time = 500, 
            end_time = 1500,
            start_angle = 0, 
            end_angle = 90
        },
        3 = Animation_Scale{
            start_time = 0, 
            end_time = 1200,
            start_scale = {3, 3}, 
            end_scale = {1, 1}
        },
    }

    bound_animations[.APPROACH_CIRCLE] = test_animation[3:4]
}


// mouse buttons
skin_element_for_type_table := #partial [Element_Type]Skin_Element{
    .HIT_CIRCLE           = .HITCIRCLE,
    .HIT_CIRCLE_OVERLAY   = .HITCIRCLEOVERLAY,
    .APPROACH_CIRCLE      = .APPROACHCIRCLE,
    .COMBO_NUMBER         = .COMBO_1,
    .SLIDER_FOLLOW_CIRCLE = .LIGHTING,
}

// note(isak): uses relative time in ms (as with game.play_timer_ms)
render_element :: proc(e: ^Element, at_time: f64) {
    if at_time < 0 || e.end_time - e.start_time < at_time {
        return
    }

    rect := Rect{e.pos.x, e.pos.y, e.size.x, e.size.y}
    angle := f32(0)
    color := e.color

    #reverse for &anim in bound_animations[e.type] {
        base := transmute(^Base_Animation)&anim
        if at_time < base.start_time {
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
    }

    skin_element := skin_element_for_type_table[e.type]
    tex := skin_texture(skin_element)

    r_draw_layout_rect(&window.renderer.quad_geometry, rect, e.anchor, color, tex, angle)
}

/*
    animation plans

    init graphical entities that are drawn in time on the playfield
    entities are loosely coupled with game objects
    
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

    for it_has_next(element) {
        bind_pipeline(wave)
        push_element(hit_circle)
    }

    blend order:
    blend order within a layer is determined by push order... not a problem
    hitobjects must be drawn back to front

*/


