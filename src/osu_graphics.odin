package notosu


Animation_Type :: enum {
    TRANSLATE,
    SCALE,
    FADE,
    ROTATE,
    COLOR,
    TEXTURE,
}

Animation :: struct {
    type: Animation_Type,
    start_time, end_time: f64,

}


Entity_Type :: enum {
    NONE,

    HIT_CIRCLE,
    HIT_CIRCLE_OVERLAY,
    APPROACH_CIRCLE,
    COMBO_NUMBER,

    SLIDER_BALL,
    SLIDER_FOLLOW_CIRCLE,
    SLIDER_END_CIRCLE,
    SLIDER_TICK,
    SLIDER_PATH,

    JUDGMENT,
    OTHER // note(isak): may reserve this for some custom map stuff?
}

Entity_Flags :: distinct bit_set[Entity_Flag; u32]
Entity_Flag :: enum {
    ANIMATED
}

Entity :: struct {
    id: int,
    type: Entity_Type,
    flags: Entity_Flags,

    pos: vec2,
    anchor: Layout_Anchor,
    
    start_time, end_time: f64,
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


