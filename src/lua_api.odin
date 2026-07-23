package inso

import "base:runtime"
import "core:log"
import "core:strings"
import q "core:container/queue"

import lua "luajit"
import "slotmap"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"


// note(isak): API versioning/compat policy (after initial release)
// maps declare a target API version in their .inso header. when making breaking changes:
//   - prefer add-only (rename new, keep old) until a clean break is necessary
//   - on a breaking change: write compat/vN.lua (loaded before the map script for old versions)
//   - shims can patch static methods directly (Hitobject.old = Hitobject.new) and instance
//     methods via get_class_meta("ClassName") -- see luaapi_get_class_meta
//   - things shims can't fix: event arg order changes, removed enum values the engine no
//     longer handles, structural drawable/hitobject relationship changes -- those need an
//     odin-side version check at the call site

// @beta
// todo(isak): expose score (the points number) once stable score v1 is implemented
// todo(isak): z-index within a layer (currently insertion-order only)

Lua_Class_Type :: enum {
    HITOBJECT,
    DRAWABLE,
    ELEMENT,
    ANIMATION,
    BUFFER,
    SOUND,
    COLOR,
    BEATMAP,
    PLAYFIELD,
    WINDOW,
    SHADER,
}

// note(isak): we use reflection to copy the names and associated enums directly to lua tables
luaapi_enum_constants := [?]struct { t: typeid, name: cstring }{
    { Layer, "Layer" },
    { Judgement_Type, "Judgement" },
    { Layout_Anchor, "Anchor" },
    { Tween, "Tween" },
    { Hitobject_Phase, "Phase" },
    { Slider_Part, "SliderPart" },
    { Animation_Time_Domain, "TimeDomain" },
}


lua_classes: [Lua_Class_Type]Lua_Class = {
    .HITOBJECT = {
        name            = "Hitobject",
        static_funcs    = luaapi_hitobject_static_funcs,
        instance_funcs  = luaapi_hitobject_instance_funcs,
    },
    .DRAWABLE = {
        name            = "Drawable",
        static_funcs    = luaapi_drawable_static_funcs,
        instance_funcs  = luaapi_drawable_instance_funcs,
    },
    .ELEMENT = {
        name            = "Element",
        static_funcs    = luaapi_element_static_funcs,
        instance_funcs  = luaapi_element_instance_funcs,
    },
    .ANIMATION = {
        name            = "Animation",
        static_funcs    = luaapi_animation_static_funcs,
        instance_funcs  = luaapi_animation_instance_funcs,
    },
    .BUFFER = {
        name            = "Buffer",
        static_funcs    = luaapi_buffer_static_funcs,
        instance_funcs  = luaapi_buffer_instance_funcs,
    },
    .SOUND = {
        name            = "Sound",
        static_funcs    = luaapi_sound_static_funcs,
        instance_funcs  = luaapi_sound_instance_funcs,
    },
    .BEATMAP = {
        name            = "Beatmap",
        static_funcs    = luaapi_beatmap_static_funcs,
    },
    .COLOR = {
        name            = "Color",
        static_funcs    = luaapi_color_static_funcs,
    },
    .PLAYFIELD = {
        name            = "Playfield",
        static_funcs    = luaapi_playfield_static_funcs,
    },
    .WINDOW = {
        name            = "Window",
        static_funcs    = luaapi_window_static_funcs,
    },
    .SHADER = {
        name            = "Shader",
        static_funcs    = luaapi_shader_static_funcs,
    },
}

luaapi_global_funcs := []Lua_Function {
  { "load_file", luaapi_load_file,
    "any load_file( string filename )",
    "loads and runs a lua file from the mapset folder, returning whatever it returns." },
  { "get_cursor_pos", luaapi_get_cursor_pos,
    "(float x, float y) get_cursor_pos( void )",
    "the cursor position in playfield (osupx) space." },
  { "set_cursor_visible", luaapi_set_cursor_visible,
    "void set_cursor_visible( bool visible )",
    "shows or hides the built-in skin cursor. hide it to draw your own from a Drawable." },
  { "set_cursor_layer", luaapi_set_cursor_layer,
    "void set_cursor_layer( Layer layer )",
    "moves the built-in skin cursor (trail, click expand and all) to the given render layer. put it on a captured layer to warp it with the scene, or on Layer.PLATFORM to keep it above post-processing. default is Layer.CURSOR." },
  { "controller_is_down", luaapi_controller_is_down,
    "bool controller_is_down( string key )",
    "true if the named gameplay key is held. key is one of \"k1\", \"k2\", \"m1\", \"m2\"." },
  { "controller_is_up", luaapi_controller_is_up,
    "bool controller_is_up( string key )",
    "true if the named gameplay key is not held. key is one of \"k1\", \"k2\", \"m1\", \"m2\"." },
  { "key_is_down", luaapi_key_is_down,
    "bool key_is_down( string|int key )",
    "true if the given keyboard key is held. accepts an sdl scancode name or a numeric scancode." },
  { "key_is_up", luaapi_key_is_up,
    "bool key_is_up( string|int key )",
    "true if the given keyboard key is not held. accepts an sdl scancode name or a numeric scancode." },
  { "trigger_event", luaapi_trigger_event,
    "void trigger_event( string name, ... )",
    "fires every callback registered under name. object callbacks get (self, ...), globals get (...)." },
  { "schedule_event", luaapi_schedule_event,
    "void schedule_event( string name, float delay_ms = 0 )",
    "fires trigger_event(name) after delay_ms of music time. scheduled from on_init it replays on backward seek; scheduled from a callback it fires once. safe to call again from within a callback." },
  { "schedule_at", luaapi_schedule_at,
    "void schedule_at( float time_ms, fn callback )",
    "runs callback on the first frame at or after music time time_ms. scheduled from on_init it replays on backward seek; scheduled from a callback it fires once. safe to call again from within a callback." },
  { "schedule_after", luaapi_schedule_after,
    "void schedule_after( float delay_ms, fn callback )",
    "runs callback on the first frame at least delay_ms of music time from now. scheduled from on_init it replays on backward seek; scheduled from a callback it fires once. safe to call again from within a callback." },
  { "register_global_event", luaapi_register_global_event,
    "void register_global_event( string name, fn callback )",
    "registers a callback not tied to any object; it receives only the extra args from trigger_event." },
  { "judgement_spawn", luaapi_judgement_spawn,
    "void judgement_spawn( Judgement judgement, float time_error_ms = 0, Hitobject hitobject = nil )",
    "creates a judgement as if the game had posted it, but no graphic is created and validate_judgement is skipped. an attached hitobject attributes the judgement (per-object callbacks fire, slider combo rules apply) without counting as that object's own final judgement. calling this while a judgement is dispatching (on_judgement/validate_judgement) is an error." },
}

luaapi_judgement_spawn :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    if lua_beatmap.in_judgement_dispatch {
        return lua.L_error(L, "judgement_spawn: cannot spawn while a judgement is dispatching (on_judgement/validate_judgement)")
    }

    type_int := lua.L_checkinteger(L, 1)
    if type_int <= cast(lua.Integer)Judgement_Type.NONE || type_int > cast(lua.Integer)max(Judgement_Type) {
        return lua.L_error(L, "judgement_spawn: invalid Judgement value")
    }
    time_error_ms := f64(lua.L_optnumber(L, 2, 0))

    hobj_index := -1
    hobj_type := Hitobject_Type.CIRCLE
    if i32(lua.gettop(L)) >= 3 && !lua.isnil(L, 3) {
        handle := cast(^int)lua.L_checkudata(L, 3, lua_classes[.HITOBJECT].name)
        if handle^ >= 0 && handle^ < len(game.beatmap.hitobjects) {
            hobj_index = handle^
            hobj_type = game.beatmap.hitobjects[hobj_index].type
        }
    }

    judgement_spawn_scripted(Judgement_Type(type_int), time_error_ms, hobj_index, hobj_type)
    return 0
}


// note(isak): trigger_event(name, ...) - fires all callbacks registered under 'name'.
// object callbacks receive (object_handle, ...), global callbacks receive (...) only.
luaapi_trigger_event :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    event_name := lua_string(1)
    n_extra_args := i32(lua.gettop(L)) - 1

    for reg in lua_beatmap.event_registrations {
        if reg.name != event_name do continue
        lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(reg.callback_ref))
        if !reg.is_global {
            _lua_push_event_target(L, reg.class, reg.handle_key)
        }
        for i in i32(0)..<n_extra_args {
            lua.pushvalue(L, lua.Index(2 + i))
        }
        n_args := n_extra_args if reg.is_global else 1 + n_extra_args
        lua_pcall_with_watchdog(L, n_args, 0, "trigger_event error:")
    }
    return 0
}

// note(isak): register_global_event(name, fn) - registers a callback not tied to any object.
// callback receives only the extra args passed to trigger_event, with no leading self.
luaapi_register_global_event :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    if !lua.isfunction(L, 2) {
        return lua.L_error(L, "register_global_event: argument 2 must be a function")
    }
    event_name, name_ref := lua_create_string_ref(1)
    lua.pushvalue(L, 2)
    callback_ref := lua.L_ref(L, lua.REGISTRYINDEX)
    append(&lua_beatmap.event_registrations, Lua_Event_Registration{
        name         = event_name,
        name_ref     = name_ref,
        callback_ref = callback_ref,
        is_global    = true,
    })
    return 0
}


luaapi_schedule_event :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    delay_ms             := f64(lua.L_checknumber(L, 2))
    event_name, name_ref := lua_create_string_ref(1)
    append(&lua_beatmap.scheduled_events, Scheduled_Event{
        event_name   = event_name,
        name_ref     = name_ref,
        callback_ref = lua.NOREF,
        fire_at_ms   = beatmap_music_time_ms(&game.beatmap) + delay_ms,
        persistent   = lua_beatmap.in_init,
    })
    return 0
}

luaapi_schedule_at :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    return _schedule_callback(L, f64(lua.L_checknumber(L, 1)))
}

luaapi_schedule_after :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    delay_ms := f64(lua.L_checknumber(L, 1))
    return _schedule_callback(L, beatmap_music_time_ms(&game.beatmap) + delay_ms)
}

//////////////////////////////////////////////////////
// note(isak): global beatmap communication API

luaapi_load_file :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    filename := lua.L_checkstring(L, 1)
    
    full_path_str := strings.concatenate({game.active_mapset.folder_path, string(filename)}, context.temp_allocator)
    _pad := new(byte, context.temp_allocator)
    full_path := strings.unsafe_string_to_cstring(full_path_str)
    
    if lua.L_loadfile(L, full_path) != lua.OK {
        return lua.L_error(L, "User error - script file not found: %s", full_path)
    }

    if lua.pcall(L, 0, 1, 0) != lua.OK {
        return i32(lua.error(L)) // re-raise the loaded script's runtime error instead of eating it
    }
    return 1
}

luaapi_get_cursor_pos :: proc "c" (L: ^lua.State) -> i32 {
    lua.pushnumber(L, lua.Number(game.input.mouse_pos.x))
    lua.pushnumber(L, lua.Number(game.input.mouse_pos.y))
    return 2
}

luaapi_set_cursor_visible :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua_beatmap.hide_skin_cursor = !lua_boolean(1)
    return 0
}

luaapi_set_cursor_layer :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    layer_val := int(lua_int(1))
    if layer_val >= 0 && layer_val < layer_slot_count() {
        lua_beatmap.cursor_layer = Layer_ID(layer_val)
    }
    return 0
}

luaapi_controller_is_down :: proc "c" (L: ^lua.State) -> i32 {
    key_name := lua.L_checkstring(L, 1)
    result: bool
    switch key_name {
    case "k1": result = button_is_down(game.input.k1)
    case "k2": result = button_is_down(game.input.k2)
    case "m1": result = button_is_down(game.input.m1)
    case "m2": result = button_is_down(game.input.m2)
    }
    lua.pushboolean(L, b32(result))
    return 1
}

luaapi_controller_is_up :: proc "c" (L: ^lua.State) -> i32 {
    key_name := lua.L_checkstring(L, 1)
    result: bool
    switch key_name {
    case "k1": result = !button_is_down(game.input.k1)
    case "k2": result = !button_is_down(game.input.k2)
    case "m1": result = !button_is_down(game.input.m1)
    case "m2": result = !button_is_down(game.input.m2)
    }
    lua.pushboolean(L, b32(result))
    return 1
}

luaapi_key_is_down :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    scancode, ok := lua_scancode_from_key_arg(L, 1)
    if !ok {
        lua.pushboolean(L, b32(false))
        return 1
    }
    lua.pushboolean(L, b32(key_is_down(scancode)))
    return 1
}

luaapi_key_is_up :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    scancode, ok := lua_scancode_from_key_arg(L, 1)
    if !ok {
        lua.pushboolean(L, b32(false))
        return 1
    }
    lua.pushboolean(L, b32(!key_is_down(scancode)))
    return 1
}


//////////////////////////////////////////////////////
// note(isak): hitobject object API

luaapi_hitobject_static_funcs := []Lua_Function {
  { "get_at_ms", luaapi_hitobject_get_at_ms,
    "Hitobject Hitobject.get_at_ms( int ms )",
    "the hitobject whose start time is exactly ms. errors if there's no object at that time." },
  { "get_in_range_ms", luaapi_hitobject_get_in_range_ms,
    "Hitobject[] Hitobject.get_in_range_ms( int from_ms, int to_ms )",
    "all hitobjects with start times in [from_ms, to_ms]." },
  { "get_visible", luaapi_hitobject_get_visible,
    "Hitobject[] Hitobject.get_visible( void )",
    "all hitobjects currently within their visible time window." },
  { "get_visible_incl_followpoints", luaapi_hitobject_get_visible_incl_followpoints,
    "Hitobject[] Hitobject.get_visible_incl_followpoints( void )",
    "like get_visible(), but also includes objects whose followpoint line is currently drawn (which can lead or trail their own approach window). use this set when positioning objects so their followpoints track the intended position before the object itself appears." },
  { "get_with_all_bits", luaapi_hitobject_get_with_all_bits,
    "Hitobject[] Hitobject.get_with_all_bits( int mask )",
    "all hitobjects with every extra-bit in mask set. a zero mask returns nothing." },
  { "get_with_any_bits", luaapi_hitobject_get_with_any_bits,
    "Hitobject[] Hitobject.get_with_any_bits( int mask )",
    "all hitobjects with at least one extra-bit in mask set. a zero mask returns nothing." },
}

luaapi_hitobject_instance_funcs := []Lua_Function {
  { "__gc", luaapi_hitobject_gc, "", "" },
  { "register_event", luaapi_hitobject_register_event,
    "self hitobject:register_event( string name, fn callback )",
    "registers callback to run when name is triggered for this object; it receives (self, ...)." },
  { "is_hitcircle", luaapi_hitobject_is_hitcircle,
    "bool hitobject:is_hitcircle( void )",
    "true if this object is a hitcircle." },
  { "is_slider", luaapi_hitobject_is_slider,
    "bool hitobject:is_slider( void )",
    "true if this object is a slider." },
  { "is_spinner", luaapi_hitobject_is_spinner,
    "bool hitobject:is_spinner( void )",
    "true if this object is a spinner." },
  { "hide", luaapi_hitobject_hide,
    "self hitobject:hide( void )",
    "stops the object (and its slider body) from rendering until unhide(). persists across phase transitions; still hittable." },
  { "unhide", luaapi_hitobject_unhide,
    "self hitobject:unhide( void )",
    "undoes hide()." },
  { "hide_combo_numbers", luaapi_hitobject_hide_combo_numbers,
    "self hitobject:hide_combo_numbers( void )",
    "stops drawing the combo number on this object's circle." },
  { "unhide_combo_numbers", luaapi_hitobject_unhide_combo_numbers,
    "self hitobject:unhide_combo_numbers( void )",
    "undoes hide_combo_numbers()." },
  { "hide_followpoints", luaapi_hitobject_hide_followpoints,
    "self hitobject:hide_followpoints( void )",
    "suppresses the followpoints both leaving and arriving at this object." },
  { "unhide_followpoints", luaapi_hitobject_unhide_followpoints,
    "self hitobject:unhide_followpoints( void )",
    "undoes hide_followpoints()." },
  { "hide_followpoint_in", luaapi_hitobject_hide_followpoint_in,
    "self hitobject:hide_followpoint_in( void )",
    "suppresses only the followpoint arriving at this object from the previous one." },
  { "unhide_followpoint_in", luaapi_hitobject_unhide_followpoint_in,
    "self hitobject:unhide_followpoint_in( void )",
    "undoes hide_followpoint_in()." },
  { "hide_followpoint_out", luaapi_hitobject_hide_followpoint_out,
    "self hitobject:hide_followpoint_out( void )",
    "suppresses only the followpoint leaving this object toward the next one." },
  { "unhide_followpoint_out", luaapi_hitobject_unhide_followpoint_out,
    "self hitobject:unhide_followpoint_out( void )",
    "undoes hide_followpoint_out()." },
  { "set_snake_in", luaapi_hitobject_set_snake_in,
    "self hitobject:set_snake_in( bool enabled )",
    "whether this slider's body snakes out of the head during the approach (default on). no-op on non-sliders; also gated by the user's snaking-in setting." },
  { "set_snake_out", luaapi_hitobject_set_snake_out,
    "self hitobject:set_snake_out( bool enabled )",
    "whether this slider's body retracts behind the ball on its final span (default on). no-op on non-sliders; also gated by the user's snaking-out setting." },
  { "get_index", luaapi_hitobject_get_index,
    "int hitobject:get_index( void )",
    "the object's index into the beatmap's hitobject list." },
  { "get_extra_bits", luaapi_hitobject_get_extra_bits,
    "int hitobject:get_extra_bits( void )",
    "the object's script-defined extra-bits mask used for filtering." },
  { "has_all_bits", luaapi_hitobject_has_all_bits,
    "bool hitobject:has_all_bits( int mask )",
    "true if every bit in mask is set on this object." },
  { "has_any_bits", luaapi_hitobject_has_any_bits,
    "bool hitobject:has_any_bits( int mask )",
    "true if at least one bit in mask is set on this object." },
  { "get_base_pos", luaapi_hitobject_get_base_pos,
    "(float x, float y) hitobject:get_base_pos( void )",
    "the object's current position in osupx before any script translation." },
  { "get_stack_count", luaapi_hitobject_get_stack_count,
    "int hitobject:get_stack_count( void )",
    "the object's note stacking level; 0 = unstacked. positive stacks offset up-left, negative (circles under a slider tail) down-right. the offset is already baked into the object's position." },
  { "get_pos", luaapi_hitobject_get_pos,
    "(float x, float y) hitobject:get_pos( void )",
    "the object's current position in osupx." },
  { "set_pos", luaapi_hitobject_set_pos,
    "self hitobject:set_pos( float x, float y )",
    "moves the object to an absolute osupx position." },
  { "set_pos_px", luaapi_hitobject_set_pos_px,
    "self hitobject:set_pos_px( float x, float y )",
    "moves the object to a screen-space pixel position, converted into playfield osupx." },
  { "get_start_time", luaapi_hitobject_get_start_time,
    "float hitobject:get_start_time( void )",
    "the object's start time in ms." },
  { "set_start_time", luaapi_hitobject_set_start_time,
    "self hitobject:set_start_time( float ms )",
    "sets the object's start time in ms." },
  { "get_end_time", luaapi_hitobject_get_end_time,
    "float hitobject:get_end_time( void )",
    "the object's end time in ms (equals start time for circles)." },
  { "set_end_time", luaapi_hitobject_set_end_time,
    "self hitobject:set_end_time( float ms )",
    "sets the object's end time in ms." },
  { "get_phase", luaapi_hitobject_get_phase,
    "Phase hitobject:get_phase( void )",
    "the object's current lifecycle phase." },
  { "add_element_for_phase", luaapi_hitobject_add_element_for_phase,
    "self hitobject:add_element_for_phase( Phase phase, Element element )",
    "adds a custom element to draw while the object is in the given phase, replacing the default graphics. max 16 elements per phase." },
  { "clear_drawables", luaapi_hitobject_clear_drawables,
    "self hitobject:clear_drawables( void )",
    "removes all of the object's current drawables." },
  { "get_hit_animation_length", luaapi_hitobject_get_hit_animation_length,
    "float hitobject:get_hit_animation_length( void )",
    "the object's hit animation length in ms." },
  { "set_hit_animation_length", luaapi_hitobject_set_hit_animation_length,
    "self hitobject:set_hit_animation_length( float ms )",
    "overrides the object's hit animation length in ms." },
  { "get_preempt", luaapi_hitobject_get_preempt,
    "float hitobject:get_preempt( void )",
    "the object's approach (preempt) time in ms." },
  { "set_preempt", luaapi_hitobject_set_preempt,
    "self hitobject:set_preempt( float ms )",
    "overrides the object's approach (preempt) time in ms." },
  { "get_ar", luaapi_hitobject_get_ar,
    "float hitobject:get_ar( void )",
    "the object's approach rate, derived from its preempt time." },
  { "set_ar", luaapi_hitobject_set_ar,
    "self hitobject:set_ar( float ar )",
    "overrides the object's approach rate (converted to a preempt time)." },
  { "get_cs", luaapi_hitobject_get_cs,
    "float hitobject:get_cs( void )",
    "the object's circle size, derived from its radius." },
  { "get_cs_radius", luaapi_hitobject_get_cs_radius,
    "float hitobject:get_cs_radius( void )",
    "the object's circle size radius in osupx." },
  { "set_cs", luaapi_hitobject_set_cs,
    "self hitobject:set_cs( float cs )",
    "overrides the object's circle size (converted to a radius)." },
  { "set_cs_radius", luaapi_hitobject_set_cs_radius,
    "self hitobject:set_cs_radius( float radius )",
    "overrides the object's circle size radius in osupx." },
  { "get_slider_distance", luaapi_hitobject_get_slider_distance,
    "float hitobject:get_slider_distance( void )",
    "the slider's path length in osupx (0 for non-sliders)." },
  { "get_slider_velocity", luaapi_hitobject_get_slider_velocity,
    "float hitobject:get_slider_velocity( void )",
    "the slider's velocity (0 for non-sliders)." },
  { "get_slider_duration_ms", luaapi_hitobject_get_slider_duration_ms,
    "float hitobject:get_slider_duration_ms( void )",
    "the duration of one slider traversal in ms (0 for non-sliders)." },
  { "get_slider_ball_pos", luaapi_hitobject_get_slider_ball_pos,
    "(float x, float y) hitobject:get_slider_ball_pos( void )",
    "the slider ball's current position in osupx (the head position for non-sliders)." },
  { "get_slider_ball_pos_at", luaapi_hitobject_get_slider_ball_pos_at,
    "(float x, float y) hitobject:get_slider_ball_pos_at( float ms )",
    "the slider ball's position at the given music time in osupx." },
  { "get_slider_ball_angle", luaapi_hitobject_get_slider_ball_angle,
    "float hitobject:get_slider_ball_angle( void )",
    "the slider ball's current travel angle in radians (0 for non-sliders)." },
  { "get_slider_ball_angle_at", luaapi_hitobject_get_slider_ball_angle_at,
    "float hitobject:get_slider_ball_angle_at( float ms )",
    "the slider ball's travel angle at the given music time in radians." },
  { "get_slider_follow_circle_radius", luaapi_hitobject_get_slider_follow_circle_radius,
    "float hitobject:get_slider_follow_circle_radius( void )",
    "the radius multiplier of the slider follow circle (0 for non-sliders). default value is 2.4." },
  { "set_slider_follow_circle_radius", luaapi_hitobject_set_slider_follow_circle_radius,
    "self hitobject:set_slider_follow_circle_radius( float mult )",
    "sets the radius multiplier of the slider follow circle." },
  { "set_slider_element", luaapi_hitobject_set_slider_element,
    "self hitobject:set_slider_element( SliderPart part, Element element )",
    "overrides the element used for a slider part (ball, follow circle, ticks, repeats, ends)." },

}

luaapi_hitobject_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    _log_lua_gc(.HITOBJECT, u64(handle^))
    lua_unregister_events_for_handle(.HITOBJECT, u64(handle^))
    return result
}

luaapi_hitobject_register_event :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    return _register_event(L, .HITOBJECT, u64(handle^))
}

luaapi_hitobject_get_at_ms :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    at_ms := lua_int(1)
    hitobject_index, found := game.active_mapset.hitobject_index_by_ms[int(at_ms)]
    if found {
        lua_create_userdata(L, hitobject_index, lua_classes[.HITOBJECT].name)
        result = 1
    } else {
        log.warn("User error - no hitobject at ms:", at_ms)
        notify_warn("lua: no hitobject at ms %v", at_ms)
    }
    return result
}

luaapi_hitobject_get_in_range_ms :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    from_ms, to_ms := lua_int(1), lua_int(2)

    start_index := hitobject_lower_bound_ms(f64(from_ms))

    default_array_size: i32 = 64
    lua.createtable(L, default_array_size, 0)

    table_i: i32 = 1
    for hobj, i in game.beatmap.hitobjects[start_index:] {
        if f64(to_ms) < hobj.start_time_ms do break
        lua_create_userdata(L, start_index + i, lua_classes[.HITOBJECT].name)
        lua.rawseti(L, -2, table_i)
        table_i += 1
    }
    return 1
}

luaapi_hitobject_get_visible :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    state := &game.beatmap.visible_hitobject_state
    count := i32(state.latest_i - state.earliest_i)

    lua.createtable(L, max(count, 0), 0)

    table_i: i32 = 1
    for i in state.earliest_i..<state.latest_i {
        if i >= len(game.beatmap.hitobjects) do break
        lua_create_userdata(L, i, lua_classes[.HITOBJECT].name)
        lua.rawseti(L, -2, table_i)
        table_i += 1
    }
    return 1
}

luaapi_hitobject_get_visible_incl_followpoints :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    lo, hi := beatmap_visible_incl_followpoints_bounds(&game.beatmap, beatmap_music_time_ms(&game.beatmap))

    lua.createtable(L, max(i32(hi - lo), 0), 0)

    table_i: i32 = 1
    for i in lo..<hi {
        lua_create_userdata(L, i, lua_classes[.HITOBJECT].name)
        lua.rawseti(L, -2, table_i)
        table_i += 1
    }
    return 1
}

// note(isak): collect handles for every hitobject matching the extra-bits mask. require_all means every bit
// in the mask must be set (bits & mask == mask); otherwise any shared bit is enough (bits & mask != 0). a zero
// mask returns an empty list - no criterion was given - rather than matching everything.
_luaapi_hitobject_collect_by_bits :: proc "c" (L: ^lua.State, require_all: bool) -> i32 {
    context = lua_beatmap.odin_context
    mask := u64(lua_int(1))

    lua.createtable(L, 0, 0)

    table_i: i32 = 1
    if mask != 0 {
        for hobj, i in game.beatmap.hitobjects {
            matched := (hobj.extra_bits & mask) == mask if require_all else (hobj.extra_bits & mask) != 0
            if !matched do continue
            lua_create_userdata(L, i, lua_classes[.HITOBJECT].name)
            lua.rawseti(L, -2, table_i)
            table_i += 1
        }
    }
    return 1
}

// note(isak): get_with_all_bits(mask) - hitobjects with every bit in mask set
luaapi_hitobject_get_with_all_bits :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_hitobject_collect_by_bits(L, require_all = true)
}

// note(isak): get_with_any_bits(mask) - hitobjects with at least one bit in mask set
luaapi_hitobject_get_with_any_bits :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_hitobject_collect_by_bits(L, require_all = false)
}

_luaapi_hitobject_op  :: proc "c" (L: ^lua.State, op: proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32) -> i32 { return _lua_op (L, _lua_resolve_hitobject, op) }
_luaapi_hitobject_get :: proc "c" (L: ^lua.State, op: proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32) -> i32 { return _lua_get(L, _lua_resolve_hitobject, op) }

luaapi_hitobject_is_hitcircle :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushboolean(L, b32(hobj.type == .CIRCLE))
        return 1
    })
}

luaapi_hitobject_is_slider :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushboolean(L, b32(hobj.type == .SLIDER))
        return 1
    })
}

luaapi_hitobject_is_spinner :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushboolean(L, b32(hobj.type == .SPINNER))
        return 1
    })
}

luaapi_hitobject_hide :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags |= {.HIDDEN_BY_SCRIPT}
        return 0
    })
}

luaapi_hitobject_unhide :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags &~= {.HIDDEN_BY_SCRIPT}
        return 0
    })
}

luaapi_hitobject_hide_combo_numbers :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags |= {.HIDE_COMBO_NUMBERS}
        return 0
    })
}

luaapi_hitobject_unhide_combo_numbers :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags &~= {.HIDE_COMBO_NUMBERS}
        return 0
    })
}

luaapi_hitobject_hide_followpoints :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags |= {.NO_FOLLOWPOINT_IN, .NO_FOLLOWPOINT_OUT}
        return 0
    })
}

luaapi_hitobject_unhide_followpoints :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags &~= {.NO_FOLLOWPOINT_IN, .NO_FOLLOWPOINT_OUT}
        return 0
    })
}

luaapi_hitobject_hide_followpoint_in :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags |= {.NO_FOLLOWPOINT_IN}
        return 0
    })
}

luaapi_hitobject_unhide_followpoint_in :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags &~= {.NO_FOLLOWPOINT_IN}
        return 0
    })
}

luaapi_hitobject_hide_followpoint_out :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags |= {.NO_FOLLOWPOINT_OUT}
        return 0
    })
}

luaapi_hitobject_unhide_followpoint_out :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.flags &~= {.NO_FOLLOWPOINT_OUT}
        return 0
    })
}

luaapi_hitobject_set_snake_in :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        if lua_boolean(2) {
            hobj.flags |= {.SLIDER_SNAKE_IN}
        } else {
            hobj.flags &~= {.SLIDER_SNAKE_IN}
        }
        return 0
    })
}

luaapi_hitobject_set_snake_out :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        if lua_boolean(2) {
            hobj.flags |= {.SLIDER_SNAKE_OUT}
        } else {
            hobj.flags &~= {.SLIDER_SNAKE_OUT}
        }
        return 0
    })
}

luaapi_hitobject_get_index :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushinteger(L, lua.Integer(hobj.index))
        return 1
    })
}

luaapi_hitobject_get_extra_bits :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushinteger(L, lua.Integer(hobj.extra_bits))
        return 1
    })
}

// note(isak): has_all_bits(mask) - true if every bit in mask is set on this object
luaapi_hitobject_has_all_bits :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        mask := u64(lua_int(2))
        lua.pushboolean(L, b32((hobj.extra_bits & mask) == mask))
        return 1
    })
}

// note(isak): has_any_bits(mask) - true if at least one bit in mask is set on this object
luaapi_hitobject_has_any_bits :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        mask := u64(lua_int(2))
        lua.pushboolean(L, b32((hobj.extra_bits & mask) != 0))
        return 1
    })
}


luaapi_hitobject_get_stack_count :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushinteger(L, lua.Integer(hobj.stack_count))
        return 1
    })
}

luaapi_hitobject_get_base_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.pos.x))
        lua.pushnumber(L, lua.Number(hobj.pos.y))
        return 2
    })
}
luaapi_hitobject_get_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.pos.x + hobj.script_pos_translation.x))
        lua.pushnumber(L, lua.Number(hobj.pos.y + hobj.script_pos_translation.y))
        return 2
    })
}
luaapi_hitobject_set_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        // note(isak): we forcibly make the translation non-relative. might not keep this?
        hobj.script_pos_translation.x = f32(lua_number(2)) - hobj.pos.x
        hobj.script_pos_translation.y = f32(lua_number(3)) - hobj.pos.y
        return 0
    })
}

luaapi_hitobject_set_pos_px :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        osupx := screenspace_to_playfield_osupx({f32(lua_number(2)), f32(lua_number(3))})
        hobj.script_pos_translation = osupx - hobj.pos
        return 0
    })
}

luaapi_hitobject_get_start_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.start_time_ms))
        return 1
    })
}
luaapi_hitobject_set_start_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.start_time_ms = f64(lua_number(2))
        return 0
    })
}

luaapi_hitobject_get_end_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.end_time_ms))
        return 1
    })
}
luaapi_hitobject_set_end_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        hobj.end_time_ms = f64(lua_number(2))
        return 0
    })
}

luaapi_hitobject_get_phase :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushinteger(L, lua.Integer(hobj.phase))
        return 1
    })
}

luaapi_hitobject_clear_drawables :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        hitobject_clear_drawables(hobj)
        return 0
    })
}

luaapi_hitobject_add_element_for_phase :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        phase := Hitobject_Phase(lua_int(2))
        el_id := (cast(^Element_ID)lua.L_checkudata(L, 3, lua_classes[.ELEMENT].name))^

        if hobj.custom_elements[phase] == nil {
            hobj.custom_elements[phase] = hitobject_reserve_phase_elements(hobj, phase)
        }

        if hobj.custom_element_nums[phase] < 16 {
            el_index := hobj.custom_element_nums[phase]
            hobj.custom_elements[phase][el_index] = el_id
            hobj.custom_element_nums[phase] += 1
        } else {
            notify_warn("add_element_for_phase: too many elements")
        }
        return 0
    })
}

luaapi_hitobject_set_slider_element :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        part_index := int(lua_int(2))
        if part_index < 0 || part_index >= len(Slider_Part) {
            notify_warn("set_slider_element: invalid SliderPart %d", part_index)
            return 0
        }
        el_id := (cast(^Element_ID)lua.L_checkudata(L, 3, lua_classes[.ELEMENT].name))^
        slider_set_part_element(hobj, Slider_Part(part_index), el_id)
        return 0
    })
}

luaapi_hitobject_get_hit_animation_length :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        hit_anim_len := hobj.custom_hit_animation_len_ms if hobj.custom_hit_animation_len_ms != 0 else OSU_HIT_ANIMATION_LENGTH
        lua.pushnumber(L, lua.Number(hit_anim_len))
        return 1
    })
}

luaapi_hitobject_set_hit_animation_length :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        hobj.custom_hit_animation_len_ms = f64(lua_number(2))
        return 0
    })
}

luaapi_hitobject_get_preempt :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        preempt := hobj.custom_preempt_ms if hobj.custom_preempt_ms != 0 else game.beatmap.preempt_ms
        lua.pushnumber(L, lua.Number(preempt))
        return 1
    })
}

luaapi_hitobject_set_preempt :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        hitobject_set_preempt(hobj, f64(lua_number(2)))
        return 0
    })
}

luaapi_hitobject_get_ar :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        preempt := hobj.custom_preempt_ms if hobj.custom_preempt_ms != 0 else game.beatmap.preempt_ms
        lua.pushnumber(L, lua.Number(convert_preempt_ms_to_approach_rate(preempt)))
        return 1
    })
}

luaapi_hitobject_set_ar :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        hitobject_set_preempt(hobj, convert_approach_rate_to_preempt_ms(f64(lua_number(2))))
        return 0
    })
}

luaapi_hitobject_get_cs :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        r := f64(hobj.custom_radius_osupx if hobj.custom_radius_osupx != 0 else game.beatmap.circle_radius_osupx)
        lua.pushnumber(L, lua.Number((54.4 * 1.00041 - r) / (4.48 * 1.00041)))
        return 1
    })
}

luaapi_hitobject_get_cs_radius :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        r := f64(hobj.custom_radius_osupx if hobj.custom_radius_osupx != 0 else game.beatmap.circle_radius_osupx)
        lua.pushnumber(L, lua.Number(r))
        return 1
    })
}

luaapi_hitobject_set_cs :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        cs := f64(lua_number(2))
        hobj.custom_radius_osupx = f32((54.4 - 4.48 * cs) * 1.00041)
        return 0
    })
}

luaapi_hitobject_set_cs_radius :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        cs_radius := f64(lua_number(2))
        hobj.custom_radius_osupx = f32(cs_radius)
        return 0
    })
}


luaapi_hitobject_get_slider_distance :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        distance := hobj.slider_state.distance if hobj.type == .SLIDER else 0
        lua.pushnumber(L, lua.Number(distance))
        return 1
    })
}

luaapi_hitobject_get_slider_velocity :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        velocity := hobj.slider_state.velocity if hobj.type == .SLIDER else 0
        lua.pushnumber(L, lua.Number(velocity))
        return 1
    })
}

luaapi_hitobject_get_slider_duration_ms :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        duration := hobj.slider_state.duration_ms if hobj.type == .SLIDER else 0
        lua.pushnumber(L, lua.Number(duration))
        return 1
    })
}

luaapi_hitobject_get_slider_ball_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        pos := hobj.pos
        if hobj.type == .SLIDER {
            context = lua_beatmap.odin_context
            path := game.beatmap.slider_paths[hobj.slider_path_index]
            pos = path_calculate_position_at(hobj, beatmap_music_time_ms(&game.beatmap), &path)
        }
        lua.pushnumber(L, lua.Number(pos.x))
        lua.pushnumber(L, lua.Number(pos.y))
        return 2
    })
}

luaapi_hitobject_get_slider_ball_pos_at :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        pos := hobj.pos
        if hobj.type == .SLIDER {
            context = lua_beatmap.odin_context
            path := game.beatmap.slider_paths[hobj.slider_path_index]
            pos = path_calculate_position_at(hobj, f64(lua_number(2)), &path)
        }
        lua.pushnumber(L, lua.Number(pos.x))
        lua.pushnumber(L, lua.Number(pos.y))
        return 2
    })
}

luaapi_hitobject_get_slider_ball_angle :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        angle: f32
        if hobj.type == .SLIDER {
            context = lua_beatmap.odin_context
            angle = slider_ball_angle_at(hobj, beatmap_music_time_ms(&game.beatmap))
        }
        lua.pushnumber(L, lua.Number(angle))
        return 1
    })
}
luaapi_hitobject_get_slider_ball_angle_at :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        angle: f32
        if hobj.type == .SLIDER {
            context = lua_beatmap.odin_context
            angle = slider_ball_angle_at(hobj, f64(lua_number(2)))
        }
        lua.pushnumber(L, lua.Number(angle))
        return 1
    })
}

luaapi_hitobject_get_slider_follow_circle_radius :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_get(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        mult: f32
        if hobj.type == .SLIDER {
            mult = hobj.slider_state.follow_circle_radius_mult
        }
        lua.pushnumber(L, lua.Number(mult))
        return 1
    })
}
luaapi_hitobject_set_slider_follow_circle_radius :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        if hobj.type == .SLIDER {
            hobj.slider_state.follow_circle_radius_mult = f32(lua_number(2))
        }
        return 0
    })
}


//////////////////////////////////////////////////////
// note(isak): drawable object API

luaapi_drawable_static_funcs := []Lua_Function {
  { "new", luaapi_drawable_new,
    "Drawable Drawable.new( string|Element source, float start_ms = 0, float end_ms = 0, Layer layer = Layer.BACKGROUND )",
    "creates a drawable from a texture name or an Element, on the current render layer. a texture name may be a mapset texture or a skin element via \"skin:<name>\" (e.g. \"skin:cursor\")." },
}

luaapi_drawable_instance_funcs := []Lua_Function {
  { "__gc", luaapi_drawable_gc, "", "" },
  { "register_event", luaapi_drawable_register_event,
    "self drawable:register_event( string name, fn callback )",
    "registers callback to run when name is triggered for this drawable; it receives (self, ...)." },
  { "clone", luaapi_drawable_clone,
    "Drawable drawable:clone( void )",
    "creates an independent copy of this drawable." },
  { "get_element", luaapi_drawable_get_element,
    "Element drawable:get_element( void )",
    "gets the underlying element type of the drawable." },
  { "set_element", luaapi_drawable_set_element,
    "self drawable:set_element( Element el )",
    "sets the underlying element type of the drawable to the given element." },
  { "set_animation", luaapi_drawable_set_animation,
    "self drawable:set_animation( Animation anim )",
    "overrides this drawable's animation with the given list, replacing the element template's for this instance only." },
  { "get_layer", luaapi_drawable_get_layer,
    "Layer drawable:get_layer( void )",
    "the drawable's render layer." },
  { "set_layer", luaapi_drawable_set_layer,
    "self drawable:set_layer( Layer layer )",
    "moves the drawable to the given render layer." },
  { "set_uv", luaapi_drawable_set_uv,
    "self drawable:set_uv( float x, float y, float w, float h )",
    "sets the uv sub-rect in [0,1] space, picking a region of the texture." },
  { "get_uv_angle", luaapi_drawable_get_uv_angle,
    "float drawable:get_uv_angle( void )",
    "the uv sub-rect's rotation in radians." },
  { "set_uv_angle", luaapi_drawable_set_uv_angle,
    "self drawable:set_uv_angle( float angle_rad )",
    "rotates the uv sub-rect around its center. set it equal to the drawable's angle and a rotated quad samples the screen region it covers with the content upright - the basis for angled scene cuts." },
  { "get_pos", luaapi_drawable_get_pos,
    "(float x, float y) drawable:get_pos( void )",
    "the drawable's position." },
  { "set_pos", luaapi_drawable_set_pos,
    "self drawable:set_pos( float x, float y )",
    "sets the drawable's position." },
  { "set_pos_px", luaapi_drawable_set_pos_px,
    "self drawable:set_pos_px( float x, float y )",
    "sets the drawable's position from a screen-space pixel position, converted into playfield osupx." },
  { "get_size", luaapi_drawable_get_size,
    "(float w, float h) drawable:get_size( void )",
    "the drawable's size in osupx." },
  { "set_size", luaapi_drawable_set_size,
    "self drawable:set_size( float w, float h )",
    "sets the drawable's size in osupx." },
  { "get_size_px", luaapi_drawable_get_size_px,
    "(float w, float h) drawable:get_size_px( void )",
    "the drawable's size in screen-space pixels." },
  { "set_size_px", luaapi_drawable_set_size_px,
    "self drawable:set_size_px( float w, float h )",
    "sets the drawable's size from a screen-space pixel size, converted into osupx." },
  { "get_anchor", luaapi_drawable_get_anchor,
    "Anchor drawable:get_anchor( void )",
    "the drawable's anchor point." },
  { "set_anchor", luaapi_drawable_set_anchor,
    "self drawable:set_anchor( Anchor anchor )",
    "sets the drawable's anchor point." },
  { "set_fullscreen", luaapi_drawable_set_fullscreen,
    "self drawable:set_fullscreen( bool enabled )",
    "makes the drawable cover the whole render target (size derived each frame, tracks resizes); pos still nudges it in osupx and set_pos_px in pixels. handy for compositing a captured layer." },
  { "set_beat_pulse", luaapi_drawable_set_beat_pulse,
    "self drawable:set_beat_pulse( bool enabled )",
    "pulses the drawable's size every beat: snaps up on the beat and eases back down before the next (the reverse arrow effect)." },
  { "set_hitobject_dim", luaapi_drawable_set_hitobject_dim,
    "self drawable:set_hitobject_dim( bool enabled )",
    "dims the drawable until shortly before its associated hitobject's hit time (or its own end time if unattached), matching approaching hitobjects." },
  { "get_color", luaapi_drawable_get_color,
    "int drawable:get_color( void )",
    "the drawable's color as a packed rgba integer." },
  { "set_color", luaapi_drawable_set_color,
    "self drawable:set_color( int color )",
    "sets the drawable's color from a packed rgba integer (see Color.rgb / Color.rgba)." },
  { "get_vel", luaapi_drawable_get_vel,
    "(float x, float y) drawable:get_vel( void )",
    "the drawable's linear velocity." },
  { "set_vel", luaapi_drawable_set_vel,
    "self drawable:set_vel( float x, float y )",
    "sets the drawable's linear velocity." },
  { "get_accel", luaapi_drawable_get_accel,
    "(float x, float y) drawable:get_accel( void )",
    "the drawable's linear acceleration." },
  { "set_accel", luaapi_drawable_set_accel,
    "self drawable:set_accel( float x, float y )",
    "sets the drawable's linear acceleration." },
  { "get_angle", luaapi_drawable_get_angle,
    "float drawable:get_angle( void )",
    "the drawable's rotation in radians." },
  { "set_angle", luaapi_drawable_set_angle,
    "self drawable:set_angle( float angle_rad )",
    "sets the drawable's rotation in radians." },
  { "get_angle_vel", luaapi_drawable_get_angle_vel,
    "float drawable:get_angle_vel( void )",
    "the drawable's angular velocity." },
  { "set_angle_vel", luaapi_drawable_set_angle_vel,
    "self drawable:set_angle_vel( float angle_vel )",
    "sets the drawable's angular velocity." },
  { "get_animation_rate", luaapi_drawable_get_animation_rate,
    "float drawable:get_animation_rate( void )",
    "the drawable's animation playback rate multiplier (1 = normal)." },
  { "set_animation_rate", luaapi_drawable_set_animation_rate,
    "self drawable:set_animation_rate( float rate )",
    "sets the drawable's animation playback rate multiplier (1 = normal)." },
  { "set_loop_animation", luaapi_drawable_set_loop_animation,
    "self drawable:set_loop_animation( bool enabled )",
    "loops the drawable's animation list instead of playing it once; the period comes from animation:set_loop_period (defaulting to the list's own extent)." },
  { "get_start_time", luaapi_drawable_get_start_time,
    "float drawable:get_start_time( void )",
    "the drawable's start time in ms." },
  { "set_start_time", luaapi_drawable_set_start_time,
    "self drawable:set_start_time( float ms )",
    "sets the drawable's start time in ms." },
  { "get_end_time", luaapi_drawable_get_end_time,
    "float drawable:get_end_time( void )",
    "the drawable's end time in ms." },
  { "set_end_time", luaapi_drawable_set_end_time,
    "self drawable:set_end_time( float ms )",
    "sets the drawable's end time in ms." },
  { "set_time", luaapi_drawable_set_time,
    "self drawable:set_time( float start_ms, float end_ms )",
    "sets the drawable's start and end time in ms." },
  { "hide", luaapi_drawable_hide,
    "self drawable:hide( void )",
    "stops the drawable from rendering without destroying it; pair with show() to bring it back." },
  { "show", luaapi_drawable_show,
    "self drawable:show( void )",
    "resumes rendering a hidden drawable." },
  { "destroy", luaapi_drawable_destroy,
    "self drawable:destroy( void )",
    "permanently reaps the drawable next frame; its handle becomes invalid." },
}

// note(isak): lifetime is owned by the map_expiring_gfx buffer, which destroys the drawable (and its events) 
// once it passes end_time or has .ACTIVE cleared via destroy()
luaapi_drawable_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    _log_lua_gc(.DRAWABLE, transmute(u64)handle^)
    return result
}

luaapi_drawable_register_event :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    return _register_event(L, .DRAWABLE, transmute(u64)handle^)
}

luaapi_drawable_new :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context

    element_id: Element_ID
    if lua.type(L, 1) == lua.TSTRING {
        tex_name := lua_string(1)
        tex_id, found := mapset_texture_slot(tex_name)
        if !found {
            log.warn("User error - texture not found:", tex_name)
            notify_warn("lua: Drawable.new texture not found '%s'", tex_name)
            return 0
        }
        element_id = element_new({ shader = builtin_pipeline_slot(.QUAD), tex = tex_id })
    } else {
        element_id = (cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name))^
    }

    start_time := f64(lua.L_optnumber(L, 2, 0))
    end_time   := f64(lua.L_optnumber(L, 3, 0))
    layer      := Layer_ID(lua.L_optnumber(L, 4, 0)) // note(isak): default is .BACKGROUND
    
    handle := cast(^Drawable_Handle)lua.newuserdata(L, size_of(Drawable_Handle))
    handle^ = drawable_new_expiring(&game.beatmap.map_expiring_gfx, {
        element = element_id,
        flags = {.ACTIVE},
        layer = layer,
        anchor = .TOP_LEFT,
        
        size = {40, 40}, // note(isak): default size just so we don't get confused when it's not set...
        color = {255, 255, 255, 255},
        
        start_time_ms = start_time,
        end_time_ms = end_time
    })
    
    lua.L_getmetatable(L, lua_classes[.DRAWABLE].name)
    lua.setmetatable(L, -2)
    
    return 1
}


luaapi_drawable_clone :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    d, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        lua.pop(L, 1)
        handle := cast(^Drawable_Handle)lua.newuserdata(L, size_of(Drawable_Handle))
        handle^ = drawable_new_expiring(&game.beatmap.map_expiring_gfx, d^)
        
        lua.L_getmetatable(L, lua_classes[.DRAWABLE].name)
        lua.setmetatable(L, -2)
        
        result = 1
    }
    return result
}

_lua_resolve_drawable :: proc "c" (L: ^lua.State) -> (^Drawable, bool) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    return slotmap.get(&game.beatmap.drawables, handle^)
}

_lua_resolve_hitobject :: proc "c" (L: ^lua.State) -> (^Hitobject, bool) {
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    if handle^ >= 0 && handle^ < len(game.beatmap.hitobjects) {
        return &game.beatmap.hitobjects[handle^], true
    }
    return nil, false
}

_luaapi_drawable_op  :: proc "c" (L: ^lua.State, op: proc "c" (L: ^lua.State, d: ^Drawable) -> i32) -> i32 { 
    return _lua_op (L, _lua_resolve_drawable, op) 
}
_luaapi_drawable_get :: proc "c" (L: ^lua.State, op: proc "c" (L: ^lua.State, d: ^Drawable) -> i32) -> i32 { 
    return _lua_get(L, _lua_resolve_drawable, op)
}

luaapi_drawable_set_layer :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.layer = Layer_ID(lua_int(2))
        return 0
    })
}

luaapi_drawable_set_fullscreen :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        if lua_boolean(2) {
            d.flags += {.FULLSCREEN}
        } else {
            d.flags -= {.FULLSCREEN}
        }
        return 0
    })
}
luaapi_drawable_set_beat_pulse :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        if lua_boolean(2) {
            d.flags += {.BEAT_PULSE}
        } else {
            d.flags -= {.BEAT_PULSE}
        }
        return 0
    })
}
luaapi_drawable_set_loop_animation :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        if lua_boolean(2) {
            d.flags += {.LOOP_ANIMATION}
        } else {
            d.flags -= {.LOOP_ANIMATION}
        }
        return 0
    })
}
luaapi_drawable_set_hitobject_dim :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        if lua_boolean(2) {
            d.flags += {.HITOBJECT_DIM}
        } else {
            d.flags -= {.HITOBJECT_DIM}
        }
        return 0
    })
}
luaapi_drawable_set_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        x, y := lua_number(2), lua_number(3)
        d.pos = vec2{f32(x), f32(y)}
        return 0
    })
}
luaapi_drawable_set_pos_px :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        context = lua_beatmap.odin_context
        d.pos = screenspace_to_playfield_osupx({f32(lua_number(2)), f32(lua_number(3))})
        return 0
    })
}
luaapi_drawable_set_size :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        w, h := lua_number(2), lua_number(3)
        d.size = vec2{f32(w), f32(h)}
        return 0
    })
}
luaapi_drawable_set_size_px :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.size = vec2{f32(lua_number(2)), f32(lua_number(3))} / playfield_px_per_osupx()
        return 0
    })
}
luaapi_drawable_set_anchor :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        val := lua_int(2)
        d.anchor = Layout_Anchor(val)
        return 0
    })
}
luaapi_drawable_set_color :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.color = color_from_pixel(u32(lua_int(2)))
        return 0
    })
}
luaapi_drawable_set_start_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.start_time_ms = f64(lua_number(2))
        return 0
    })
}
luaapi_drawable_set_end_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.end_time_ms = f64(lua_number(2))
        return 0
    })
}
luaapi_drawable_set_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.start_time_ms, d.end_time_ms = f64(lua_number(2)), f64(lua_number(3))
        return 0
    })
}

luaapi_drawable_set_uv :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        x := f32(lua_number(2))
        y := f32(lua_number(3))
        w := f32(lua_number(4))
        h := f32(lua_number(5))
        d.uv = {x, y, w, h}
        return 0
    })
}

luaapi_drawable_get_uv_angle :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.uv_angle_rad))
        return 1
    })
}
luaapi_drawable_set_uv_angle :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.uv_angle_rad = f32(lua_number(2))
        return 0
    })
}

luaapi_drawable_get_pos :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.pos.x))
        lua.pushnumber(L, lua.Number(d.pos.y))
        return 2
    })
}
luaapi_drawable_get_size :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.size.x))
        lua.pushnumber(L, lua.Number(d.size.y))
        return 2
    })
}
luaapi_drawable_get_size_px :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        k := playfield_px_per_osupx()
        lua.pushnumber(L, lua.Number(d.size.x * k))
        lua.pushnumber(L, lua.Number(d.size.y * k))
        return 2
    })
}
luaapi_drawable_get_color :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushinteger(L, lua.Integer(color_to_pixel_u8(d.color)))
        return 1
    })
}
luaapi_drawable_get_start_time :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.start_time_ms))
        return 1
    })
}
luaapi_drawable_get_end_time :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.end_time_ms))
        return 1
    })
}
luaapi_drawable_get_layer :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushinteger(L, lua.Integer(int(d.layer)))
        return 1
    })
}
luaapi_drawable_get_anchor :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushinteger(L, lua.Integer(d.anchor))
        return 1
    })
}
luaapi_drawable_get_vel :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.vel.x))
        lua.pushnumber(L, lua.Number(d.vel.y))
        return 2
    })
}
luaapi_drawable_get_accel :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.accel.x))
        lua.pushnumber(L, lua.Number(d.accel.y))
        return 2
    })
}
luaapi_drawable_get_angle_vel :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.angle_vel))
        return 1
    })
}
luaapi_drawable_get_animation_rate :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.animation_rate))
        return 1
    })
}
luaapi_drawable_set_vel :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.vel = vec2{f32(lua_number(2)), f32(lua_number(3))}
        return 0
    })
}
luaapi_drawable_set_accel :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.accel = vec2{f32(lua_number(2)), f32(lua_number(3))}
        return 0
    })
}
luaapi_drawable_set_animation_rate :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.animation_rate = f64(lua_number(2))
        return 0
    })
}
luaapi_drawable_get_angle :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua.pushnumber(L, lua.Number(d.angle_rad))
        return 1
    })
}
luaapi_drawable_set_angle :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.angle_rad = f32(lua_number(2))
        return 0
    })
}
luaapi_drawable_set_angle_vel :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.angle_vel = f32(lua_number(2))
        return 0
    })
}
luaapi_drawable_get_element :: proc "c" (L: ^lua.State) -> i32 {
    return _luaapi_drawable_get(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        lua_create_userdata(L, d.element, lua_classes[.ELEMENT].name)
        return 1
    })
}
luaapi_drawable_set_element :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.element = (cast(^Element_ID)lua.L_checkudata(L, 2, lua_classes[.ELEMENT].name))^
        return 0
    })
}
luaapi_drawable_set_animation :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        context = lua_beatmap.odin_context
        handle := cast(^Script_Animation_List)lua.L_checkudata(L, 2, lua_classes[.ANIMATION].name)
        d.animation_list = handle.id
        return 0
    })
}

luaapi_drawable_hide :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.flags |= {.HIDDEN}
        return 0
    })
}
luaapi_drawable_show :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.flags &= ~{.HIDDEN}
        return 0
    })
}
luaapi_drawable_destroy :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.flags &= ~{.ACTIVE}
        return 0
    })
}


//////////////////////////////////////////////////////
// note(isak): element object API

luaapi_element_static_funcs := []Lua_Function {
  { "new", luaapi_element_new,
    "Element Element.new( string texture_name = nil )",
    "creates a quad element using the default shader. with a texture name (a mapset texture, or a skin element via \"skin:<name>\") it sets that texture, otherwise a blank white quad." },
}

luaapi_element_instance_funcs := []Lua_Function {
  { "__gc", luaapi_element_gc, "", "" },
  { "clone", luaapi_element_clone,
    "Element element:clone( void )",
    "creates an independent copy of this element." },
  { "register_event", luaapi_element_register_event,
    "self element:register_event( string name, fn callback )",
    "registers callback to run when name is triggered for this element; it receives (self, ...)." },
  { "set_tex", luaapi_element_set_tex,
    "self element:set_tex( string texture_name )",
    "sets the element's texture by name: a mapset texture, or a skin element via \"skin:<name>\" (e.g. \"skin:hitcircle\")." },
  { "set_uv", luaapi_element_set_uv,
    "self element:set_uv( float x, float y, float w, float h )",
    "sets the uv sub-rect in [0,1] space, picking a region of the texture." },
  { "set_shader", luaapi_element_set_shader,
    "self element:set_shader( string shader_name )",
    "sets the element's shader by mapset pipeline name." },
  { "set_premultiplied", luaapi_element_set_premultiplied,
    "self element:set_premultiplied( bool enabled )",
    "composites the element as an already-premultiplied source (e.g. a captured render target sampled back out) using premultiplied-over blend instead of straight alpha. builtin quad shader only." },
  { "set_render_target", luaapi_element_set_render_target,
    "self element:set_render_target( string render_target_name )",
    "redirects this element's draws into the named render target instead of the screen." },
  { "set_animation", luaapi_element_set_animation,
    "self element:set_animation( Animation animation )",
    "attaches an animation list to the element." },
  { "set_mesh", luaapi_element_set_mesh,
    "self element:set_mesh( string buffer_name, int vertex_count = 0 )",
    "marks the element as mesh-drawn, sourcing geometry from the named SSBO instead of the quad batch." },
  { "use_combo_color", luaapi_element_use_combo_color,
    "self element:use_combo_color( bool enabled )",
    "when enabled, the element tints with the hitobject's combo color." },
}

luaapi_element_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    _log_lua_gc(.ELEMENT, u64(handle^))
    lua_unregister_events_for_handle(.ELEMENT, u64(handle^))
    return result
}

luaapi_element_new :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context

    tex := builtin_texture(.WHITE)
    if lua.type(L, 1) == lua.TSTRING {
        tex_name := lua_string(1)
        tex_id, found := mapset_texture_slot(tex_name)
        if !found {
            log.warn("User error - texture not found:", tex_name)
            notify_warn("lua: Element.new texture not found '%s'", tex_name)
            return 0
        }
        tex = tex_id
    }

    data := cast(^Element_ID)lua.newuserdata(L, size_of(Element_ID))
    data^ = element_new({
        shader = builtin_pipeline_slot(.QUAD),
        tex = tex,
    })

    lua.L_getmetatable(L, lua_classes[.ELEMENT].name)
    lua.setmetatable(L, -2)
    return 1
}


luaapi_element_clone :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    userdata := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    el_id := uint(userdata^)

    if el_id < game.beatmap.elements.len {
        el := q.get(&game.beatmap.elements, el_id)
        
        lua.pop(L, 1)
        handle := cast(^Element_ID)lua.newuserdata(L, size_of(Element_ID))
        handle^ = element_new(el)
        
        lua.L_getmetatable(L, lua_classes[.ELEMENT].name)
        lua.setmetatable(L, -2)
        
        result = 1
    }
    return
}

luaapi_element_register_event :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    handle := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    return _register_event(L, .ELEMENT, u64(handle^))
}

luaapi_element_set_tex :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    userdata := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    el_id := uint(userdata^)
    tex_name := lua_string(2)
    tex_id, found := mapset_texture_slot(tex_name)
    
    if found {
        if el_id < game.beatmap.elements.len {
            el := q.get_ptr(&game.beatmap.elements, el_id)
            el.tex = tex_id
        }
    } else {
        log.warn("User error - texture not found:", tex_name)
        notify_warn("lua: Element:set_tex texture not found '%s'", tex_name)
    }
    return lua_return_self()
}

// element:set_uv(x, y, w, h) - UV sub-rect in [0,1] space; picks a region of the texture
luaapi_element_set_uv :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    userdata := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    el_id := uint(userdata^)
    x := f32(lua_number(2))
    y := f32(lua_number(3))
    w := f32(lua_number(4))
    h := f32(lua_number(5))
    if el_id < game.beatmap.elements.len {
        el := q.get_ptr(&game.beatmap.elements, el_id)
        el.uv = {x, y, w, h}
    }
    return lua_return_self()
}

luaapi_element_set_shader :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    userdata := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    el_id := uint(userdata^)
    shader_name := lua_string(2)
    shader_id, found := mapset_pipeline_slot(shader_name)
    
    if found {
        if el_id < game.beatmap.elements.len {
            el := q.get_ptr(&game.beatmap.elements, el_id)
            el.shader = shader_id
        }
    } else {
        log.warn("User error - pipeline not found:", shader_name)
        notify_warn("lua: Element:set_shader pipeline not found '%s'", shader_name)
    }
    return lua_return_self()
}

luaapi_element_set_premultiplied :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    userdata := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    el_id := uint(userdata^)
    if el_id < game.beatmap.elements.len {
        el := q.get_ptr(&game.beatmap.elements, el_id)
        el.shader = builtin_pipeline_slot(.QUAD_PREMULTIPLIED_OVER if lua_boolean(2) else .QUAD)
    }
    return lua_return_self()
}

luaapi_element_set_render_target :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    userdata := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    el_id := uint(userdata^)
    name := lua_string(2)
    fb, found := mapset_render_target_fb(name)

    if found {
        if el_id < game.beatmap.elements.len {
            el := q.get_ptr(&game.beatmap.elements, el_id)
            el.render_target = fb
        }
    } else {
        log.warn("User error - render target not found:", name)
        notify_warn("lua: Element:set_render_target render target not found '%s'", name)
    }
    return lua_return_self()
}

luaapi_element_set_animation :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    list := cast(^Script_Animation_List)lua.L_checkudata(L, 2, lua_classes[.ANIMATION].name)
    el_id := uint(handle^)

    if el_id < game.beatmap.elements.len {
        el := q.get_ptr(&game.beatmap.elements, el_id)
        el.animation_list = list.id
    }
    return lua_return_self()
}

// element:set_mesh(buffer_name, vertex_count)
// marks the element as mesh-drawn: the vertex shader receives geometry from the named SSBO
// bound at VERTEX_BUFFER (binding 1), not from the quad batch.
luaapi_element_set_mesh :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    el_id := uint(handle^)
    buffer_name  := lua_string(2)
    vertex_count := int(lua.L_optinteger(L, 3, 0))

    buf, found := mapset_buffer(buffer_name)
    if !found {
        log.warn("User error - buffer not found:", buffer_name)
        notify_warn("lua: Element:set_mesh buffer not found '%s'", buffer_name)
        return lua_return_self()
    }
    // note(isak): mesh buffers loaded from a model are packed Mesh_Vertex, so a caller that
    // omits the count (or passes <= 0) gets the whole buffer's worth of vertices.
    if vertex_count <= 0 {
        vertex_count = buf.size / size_of(Mesh_Vertex)
    }
    if el_id < game.beatmap.elements.len {
        el := q.get_ptr(&game.beatmap.elements, el_id)
        el.flags |= {.STATIC_GEOMETRY}
        el.ssbo            = buf.id
        el.ssbo_size       = buf.size
        el.index_count     = u32(vertex_count)
    }
    return lua_return_self()
}

luaapi_element_use_combo_color :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    userdata := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    
    el_id := uint(userdata^)
    if el_id < game.beatmap.elements.len {
        el := q.get_ptr(&game.beatmap.elements, el_id)

        if lua_boolean(2) {
            el.flags |= {.USE_COMBO_COLOR}
        } else {
            el.flags &~= {.USE_COMBO_COLOR}
        }
    }
    return lua_return_self()
}

//////////////////////////////////////////////////////
// note(isak): animation list API

luaapi_animation_static_funcs := []Lua_Function {
  { "new", luaapi_animation_new,
    "Animation Animation.new( TimeDomain domain = 0 )",
    "creates an empty animation list to attach to an element. domain says what keyframe times mean, defaulting to TimeDomain.NORMALIZED." },
}

luaapi_animation_instance_funcs := []Lua_Function {
  { "move", luaapi_animation_move,
    "self animation:move( float start, float end, float from_x, float from_y, float to_x, float to_y, Tween tween = 0 )",
    "appends a positional tween from (from_x, from_y) to (to_x, to_y) over [start, end]." },
  { "move_x", luaapi_animation_move_x,
    "self animation:move_x( float start, float end, float from, float to, Tween tween = 0 )",
    "appends a horizontal tween from from to to over [start, end], leaving the y position alone." },
  { "move_y", luaapi_animation_move_y,
    "self animation:move_y( float start, float end, float from, float to, Tween tween = 0 )",
    "appends a vertical tween from from to to over [start, end], leaving the x position alone." },
  { "scale", luaapi_animation_scale,
    "self animation:scale( float start, float end, float from_x, float from_y, float to_x, float to_y, Tween tween = 0 )",
    "appends a scale tween from (from_x, from_y) to (to_x, to_y) over [start, end]." },
  { "scale_x", luaapi_animation_scale_x,
    "self animation:scale_x( float start, float end, float from, float to, Tween tween = 0 )",
    "appends a horizontal scale tween from from to to over [start, end], leaving the height alone." },
  { "scale_y", luaapi_animation_scale_y,
    "self animation:scale_y( float start, float end, float from, float to, Tween tween = 0 )",
    "appends a vertical scale tween from from to to over [start, end], leaving the width alone." },
  { "rotate", luaapi_animation_rotate,
    "self animation:rotate( float start, float end, float from, float to, Tween tween = 0 )",
    "appends a rotation tween in radians from from to to over [start, end]." },
  { "color", luaapi_animation_color,
    "self animation:color( float start, float end, int from_color, int to_color, Tween tween = 0 )",
    "appends a color tween between two packed rgba colors over [start, end]." },
  { "alpha", luaapi_animation_alpha,
    "self animation:alpha( float start, float end, float from, float to, Tween tween = 0 )",
    "appends an alpha tween from from to to over [start, end]." },
  { "texture", luaapi_animation_texture,
    "self animation:texture( float start, float end, string texture_name, float layer = 0 )",
    "appends a keyframe that swaps to the named texture (and array layer) over [start, end]." },
  { "frames", luaapi_animation_frames,
    "self animation:frames( float start, float end, string texture_name )",
    "spreads every layer of a texture array as evenly-spaced frames over [start, end]." },
  { "set_time_domain", luaapi_animation_set_time_domain,
    "self animation:set_time_domain( TimeDomain domain )",
    "sets what this list's keyframe times mean. NORMALIZED is [0,1] across the drawable's lifetime, MILLISECONDS counts from the drawable's start, MAP_MILLISECONDS is absolute map time like an osu storyboard. MAP_MILLISECONDS ignores the drawable's animation rate." },
  { "set_loop_period", luaapi_animation_set_loop_period,
    "self animation:set_loop_period( float ms )",
    "sets the loop period in ms for drawables flagged LOOP_ANIMATION. 0 (default) loops over the list's own extent. ignored in the NORMALIZED domain, which always loops over [0,1]." },
}

_lua_animation_list :: proc(L: ^lua.State) -> ^Animation_List {
    handle := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    return animation_list(handle.id)
}

// note(isak): an out-of-range domain matches no case in render_drawable, freezing the whole list at
// t=0, so we'd rather fall back loudly than trust the script
_lua_check_time_domain :: proc(L: ^lua.State, arg: i32) -> Animation_Time_Domain {
    domain := Animation_Time_Domain(lua.L_optinteger(L, arg, 0))
    if domain < min(Animation_Time_Domain) || domain > max(Animation_Time_Domain) {
        log.warn("User error - invalid animation time domain:", int(domain))
        notify_warn("lua: invalid Animation time domain, using NORMALIZED")
        domain = .NORMALIZED
    }
    return domain
}

_lua_animation_append :: proc(list: ^Animation_List, anim: Animation) {
    anim := anim
    q.append(&game.beatmap.animations, anim)
    list.num_animations += 1
    list.extent = max(list.extent, (cast(^Base_Animation)&anim).end_time)
}

// note(isak): appends from separate lists interleave in the shared animation queue, so a list that
// no longer ends at the tail has to be copied there before it can grow. this leaves holes, but is
// the best we can do while entries stay contiguous
_lua_animation_list_for_append :: proc(L: ^lua.State) -> ^Animation_List {
    list := _lua_animation_list(L)
    if (list.at + list.num_animations) != game.beatmap.animations.len {
        prev_at := list.at
        list.at = game.beatmap.animations.len
        if list.num_animations > 0 {
            unfinished_anim_list := game.beatmap.animations.data[prev_at:prev_at + list.num_animations]
            q.push_back_elems(&game.beatmap.animations, ..unfinished_anim_list)
            log.warn("Lua warning: relocated animation list to index:", list.at)
        }
    }
    return list
}

luaapi_animation_new :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    q.append(&game.beatmap.animation_lists, Animation_List{
        at          = game.beatmap.animations.len,
        time_domain = _lua_check_time_domain(L, 1),
    })
    handle := Script_Animation_List{ id = Animation_List_ID(game.beatmap.animation_lists.len - 1) }
    lua_create_userdata(L, handle, lua_classes[.ANIMATION].name)
    return 1
}

luaapi_animation_set_time_domain :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list(L)
    list.time_domain = _lua_check_time_domain(L, 2)
    return lua_return_self()
}

luaapi_animation_set_loop_period :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list(L)
    list.loop_period_ms = f64(lua_number(2))
    return lua_return_self()
}

luaapi_animation_move :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    list := _lua_animation_list_for_append(L)
    
    start, end     := lua_number(2), lua_number(3)
    from_x, from_y := lua_number(4), lua_number(5)
    to_x, to_y     := lua_number(6), lua_number(7)
    tween          := Tween(lua.L_optinteger(L, 8, 0))
    _lua_animation_append(list, Animation_Translate{
        tween      = tween,
        start_time = f64(start),
        end_time   = f64(end),
        start_pos  = {f32(from_x), f32(from_y)},
        end_pos    = {f32(to_x), f32(to_y)}
    })
    return lua_return_self()
}

luaapi_animation_move_x :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list_for_append(L)

    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    _lua_animation_append(list, Animation_Translate_X{
        tween      = tween,
        start_time = f64(start),
        end_time   = f64(end),
        start_x    = from,
        end_x      = to,
    })
    return lua_return_self()
}

luaapi_animation_move_y :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list_for_append(L)

    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    _lua_animation_append(list, Animation_Translate_Y{
        tween      = tween,
        start_time = f64(start),
        end_time   = f64(end),
        start_y    = from,
        end_y      = to,
    })
    return lua_return_self()
}

luaapi_animation_scale :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    list := _lua_animation_list_for_append(L)
    
    start, end := lua_number(2), lua_number(3)
    from       := vec2{f32(lua_number(4)), f32(lua_number(5))}
    to         := vec2{f32(lua_number(6)), f32(lua_number(7))}
    tween      := Tween(lua.L_optinteger(L, 8, 0))
    _lua_animation_append(list, Animation_Scale{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_scale = from,
        end_scale   = to,
    })
    return lua_return_self()
}

luaapi_animation_scale_x :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list_for_append(L)

    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    _lua_animation_append(list, Animation_Scale_X{
        tween         = tween,
        start_time    = f64(start),
        end_time      = f64(end),
        start_scale_x = from,
        end_scale_x   = to,
    })
    return lua_return_self()
}

luaapi_animation_scale_y :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list_for_append(L)

    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    _lua_animation_append(list, Animation_Scale_Y{
        tween         = tween,
        start_time    = f64(start),
        end_time      = f64(end),
        start_scale_y = from,
        end_scale_y   = to,
    })
    return lua_return_self()
}

luaapi_animation_rotate :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    list := _lua_animation_list_for_append(L)
    
    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    _lua_animation_append(list, Animation_Rotate{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_angle = from,
        end_angle   = to
    })
    return lua_return_self()
}

luaapi_animation_color :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    list := _lua_animation_list_for_append(L)
    
    start, end := lua_number(2), lua_number(3)
    from, to   := color_from_pixel(u32(lua_int(4))), color_from_pixel(u32(lua_int(5)))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    _lua_animation_append(list, Animation_Color{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_color = from,
        end_color   = to
    })
    return lua_return_self()
}

luaapi_animation_alpha :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    list := _lua_animation_list_for_append(L)
    
    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    _lua_animation_append(list, Animation_Alpha{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_alpha = from,
        end_alpha   = to
    })
    return lua_return_self()
}

// anim:texture(start, end, tex_name [, layer])
// note(isak): layer is optional; defaults to 0. use for manually picking a frame in a texture array.
luaapi_animation_texture :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list_for_append(L)

    start, end := lua_number(2), lua_number(3)
    tex_name := lua_string(4)
    layer := f32(lua.L_optnumber(L, 5, 0))
    tex_id, found := mapset_texture_slot(tex_name)
    if !found {
        log.warn("User error - texture not found:", tex_name)
        notify_warn("lua: Animation:texture texture not found '%s'", tex_name)
        tex_id = builtin_texture(.WHITE)
    }

    _lua_animation_append(list, Animation_Texture{
        start_time = f64(start),
        end_time   = f64(end),
        texture_id = tex_id,
        layer      = layer,
    })
    return lua_return_self()
}

// anim:frames(start, end, tex_name)
// note(isak): distributes all layers of a texture array as evenly-spaced Animation_Texture keyframes
// over [start, end]. start/end are normalized to [0,1] (drawable lifetime).
luaapi_animation_frames :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    list := _lua_animation_list_for_append(L)

    start    := f64(lua_number(2))
    end      := f64(lua_number(3))
    tex_name := lua_string(4)

    tex_slot, found := game.active_mapset.texture_slot_by_name[tex_name]
    if !found {
        log.warn("User error - texture not found:", tex_name)
        notify_warn("lua: Animation:frames texture not found '%s'", tex_name)
        return lua_return_self()
    }

    tex    := q.get_ptr(&game.active_mapset.textures, tex_slot)
    tex_id := user_texture(tex_slot)
    n      := int(tex.layer_count)
    if n == 0 do n = 1
    span   := f64(end - start)

    for frame := 0; frame < n; frame += 1 {
        frame_start := start + span * (f64(frame)   / f64(n))
        frame_end   := start + span * (f64(frame+1) / f64(n))
        _lua_animation_append(list, Animation_Texture{
            start_time = frame_start,
            end_time   = frame_end,
            texture_id = tex_id,
            layer      = f32(frame),
        })
    }
    return lua_return_self()
}

//////////////////////////////////////////////////////
// note(isak): Buffer object API

luaapi_buffer_static_funcs := []Lua_Function {
  { "get", luaapi_buffer_get,
    "Buffer Buffer.get( string name )",
    "looks up a mapset buffer (SSBO) by name; returns nil if not found." },
}

luaapi_buffer_instance_funcs := []Lua_Function {
  { "bind", luaapi_buffer_bind,
    "void buffer:bind( int user_slot )",
    "binds the buffer to a user SSBO slot (0-7, mapping to USER_0..USER_7)." },
  { "write_f32s", luaapi_buffer_write_f32s,
    "void buffer:write_f32s( int byte_offset, float value, ... )",
    "writes one or more f32s at byte_offset (must be 4-byte aligned)." },
  { "write_vec4", luaapi_buffer_write_vec4,
    "void buffer:write_vec4( int vec4_index, float x, float y, float z, float w )",
    "writes four f32s at vec4_index * 16 bytes." },
  { "size", luaapi_buffer_size,
    "int buffer:size( void )",
    "the buffer's size in bytes." },
}

// Buffer.get(name) -> Buffer
luaapi_buffer_get :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    name := lua_string(1)
    _, found := mapset_buffer(name)
    if !found {
        log.warn("User error - buffer not found:", name)
        notify_warn("lua: Buffer.get buffer not found '%s'", name)
        lua.pushnil(L)
        return 1
    }
    slot := game.active_mapset.buffer_slot_by_name[name]
    lua_create_userdata(L, slot, lua_classes[.BUFFER].name)
    return 1
}

luaapi_buffer_bind :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    slot_index := cast(^u32)lua.L_checkudata(L, 1, lua_classes[.BUFFER].name)
    user_slot  := int(lua_int(2))
    if user_slot < 0 || user_slot >= USER_SSBO_SLOT_COUNT {
        return lua.L_error(L, "Buffer:bind: user_slot must be 0-%d", i32(USER_SSBO_SLOT_COUNT - 1))
    }
    buf := q.get_ptr(&game.active_mapset.buffers, uint(slot_index^))
    bind_slot := Shader_SSBO_Bind_Slot(int(Shader_SSBO_Bind_Slot.USER_0) + user_slot)
    r_bind_ssbo_raw(buf.id, buf.size, bind_slot)
    return 0
}

// buffer:write_f32s(byte_offset, val, ...) -- write one or more f32s at byte_offset
luaapi_buffer_write_f32s :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    slot_index  := cast(^u32)lua.L_checkudata(L, 1, lua_classes[.BUFFER].name)
    byte_offset := int(lua_int(2))
    n_args      := int(lua.gettop(L))

    buf := q.get_ptr(&game.active_mapset.buffers, uint(slot_index^))
    if buf.data == nil {
        return lua.L_error(L, "Buffer:write_f32s: buffer is not writable")
    }
    n_values := n_args - 2
    if n_values <= 0 {
        return lua.L_error(L, "Buffer:write_f32s: expected at least one value")
    }
    if byte_offset < 0 {
        return lua.L_error(L, "Buffer:write_f32s: byte_offset must be >= 0")
    }
    if byte_offset % size_of(f32) != 0 {
        return lua.L_error(L, "Buffer:write_f32s: byte_offset must be 4-byte aligned")
    }
    bytes_to_write := n_values * size_of(f32)
    if bytes_to_write < 0 || byte_offset > buf.size - bytes_to_write {
        return lua.L_error(L, "Buffer:write_f32s: write out of bounds")
    }
    for i in 0..<n_values {
        val := f32(lua.L_checknumber(L, i32(3 + i)))
        write_at := byte_offset + i * size_of(f32)

        (cast(^f32)&buf.data[write_at])^ = val
    }
    return 0
}

// buffer:write_vec4(vec4_index, x, y, z, w) -- write 4 floats at vec4_index * 16 bytes
luaapi_buffer_write_vec4 :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    slot_index := cast(^u32)lua.L_checkudata(L, 1, lua_classes[.BUFFER].name)
    vec_index  := int(lua_int(2))
    if vec_index < 0 {
        return lua.L_error(L, "Buffer:write_vec4: vec4_index must be >= 0")
    }
    x := f32(lua.L_checknumber(L, 3))
    y := f32(lua.L_checknumber(L, 4))
    z := f32(lua.L_checknumber(L, 5))
    w := f32(lua.L_checknumber(L, 6))

    buf := q.get_ptr(&game.active_mapset.buffers, uint(slot_index^))
    if buf.data == nil {
        return lua.L_error(L, "Buffer:write_vec4: buffer is not writable")
    }
    byte_offset := vec_index * 16
    if byte_offset > buf.size - 16 {
        return lua.L_error(L, "Buffer:write_vec4: write out of bounds")
    }
    floats := cast(^[4]f32)&buf.data[byte_offset]
    floats[0] = x; floats[1] = y; floats[2] = z; floats[3] = w
    return 0
}

// buffer:size() -> int
luaapi_buffer_size :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    slot_index := cast(^u32)lua.L_checkudata(L, 1, lua_classes[.BUFFER].name)
    buf := q.get_ptr(&game.active_mapset.buffers, uint(slot_index^))
    lua.pushinteger(L, lua.Integer(buf.size))
    return 1
}

//////////////////////////////////////////////////////
// note(isak): sound object API

luaapi_sound_static_funcs := []Lua_Function {
    { "play", luaapi_sound_play,
      "void Sound.play( string name, float volume = 1.0, float pan = 0.0 )",
      "plays a mapset sample once at the given volume and stereo pan." },
    { "play_loop", luaapi_sound_play_loop,
      "Sound Sound.play_loop( string name, float volume = 1.0 )",
      "starts looping a mapset sample and returns a handle you can stop()." },
}

luaapi_sound_instance_funcs := []Lua_Function {
    { "__gc", luaapi_sound_gc, "", "" },
    { "stop", luaapi_sound_stop,
      "void sound:stop( void )",
      "stops a looping sound started by Sound.play_loop." },
}

// Sound.play(name, volume=1.0, pan=0.0)
luaapi_sound_play :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    name   := lua_string(1)
    volume := f32(lua.L_optnumber(L, 2, 1.0))
    pan    := f32(lua.L_optnumber(L, 3, 0.0))

    sample, found := mapset_sample(name)
    if !found {
        log.warn("User error - sound not found:", name)
        notify_warn("lua: Sound.play sound not found '%s'", name)
        return 0
    }
    sample_play(sample, volume, pan)
    return 0
}

// Sound.play_loop(name, volume=1.0) -> handle
luaapi_sound_play_loop :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    name   := lua_string(1)
    volume := f32(lua.L_optnumber(L, 2, 1.0))

    sample, found := mapset_sample(name)
    if !found {
        log.warn("User error - sound not found:", name)
        notify_warn("lua: Sound.play_loop sound not found '%s'", name)
        return 0
    }
    handle := game_sound_play(sample, loop = true, volume = volume)
    lua_create_userdata(L, handle, lua_classes[.SOUND].name)
    return 1
}

luaapi_sound_stop :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    handle := cast(^slotmap.Handle)lua.L_checkudata(L, 1, lua_classes[.SOUND].name)
    game_sound_stop(handle^)
    handle^ = {}
    return 0
}

luaapi_sound_gc :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    handle := cast(^slotmap.Handle)lua.L_checkudata(L, 1, lua_classes[.SOUND].name)
    _log_lua_gc(.SOUND, transmute(u64)handle^)
    if game_sound_is_playing(handle^) {
        log.info("lua: GC collected a Sound handle whose loop was still playing. keep the handle in a variable or call :stop() yourself if this wasn't intended.")
    }
    game_sound_stop(handle^)
    return 0
}


//////////////////////////////////////////////////////
// note(isak): beatmap info API

luaapi_beatmap_static_funcs := []Lua_Function {
  { "get_music_time_ms", luaapi_beatmap_get_music_time_ms,
    "float Beatmap.get_music_time_ms( void )",
    "the current music playback time in ms." },
  { "get_length_ms", luaapi_beatmap_get_length_ms,
    "float Beatmap.get_length_ms( void )",
    "the total length of the map's audio in ms." },
  { "get_bpm", luaapi_beatmap_get_bpm,
    "float Beatmap.get_bpm( void )",
    "the bpm at the current timing point." },
  { "get_beat_length_ms", luaapi_beatmap_get_beat_length_ms,
    "float Beatmap.get_beat_length_ms( void )",
    "the beat length in ms at the current timing point." },
  { "get_beat_proximity", luaapi_beatmap_get_beat_proximity,
    "float Beatmap.get_beat_proximity( float at_time_ms = now )",
    "1 exactly on the beat, easing off to 0 right before the next. drive your own pulse effects with this." },
  { "get_ar_ms", luaapi_beatmap_get_ar_ms,
    "float Beatmap.get_ar_ms( void )",
    "the map's approach (preempt) time in ms." },
  { "get_cs_osupx", luaapi_beatmap_get_cs_osupx,
    "float Beatmap.get_cs_osupx( void )",
    "the map's circle radius in osupx." },
  { "is_paused", luaapi_beatmap_is_paused,
    "bool Beatmap.is_paused( void )",
    "true if playback is currently paused." },
  { "add_layer", luaapi_beatmap_add_layer,
    "int Beatmap.add_layer( string name, { Layer anchor = Layer.HITOBJECTS, bool above = true } )",
    "declares a custom render layer positioned relative to a built-in anchor, returning its id. pass the id anywhere a Layer is taken (Drawable.new, set_cursor_layer, capture_layers, add_post_pass after). above=true draws it just after the anchor, false just before; ties among layers on the same anchor resolve in declaration order. capture it with capture_layers to route its drawables through a render target. declare these in on_init." },
  { "capture_layers", luaapi_beatmap_capture_layers,
    "void Beatmap.capture_layers( string render_target_name, table layers )",
    "redirects every drawable in the given layers into the named render target." },
  { "free_layers", luaapi_beatmap_free_layers,
    "void Beatmap.free_layers( table layers )",
    "stops redirecting the given layers into a render target." },
  { "set_skin_override", luaapi_beatmap_set_skin_override,
    "void Beatmap.set_skin_override( string skin_name )",
    "force loads a skin by folder name, as listed in the skin dropdown (e.g. \"gn\"). the override lasts as long as the map: it never touches the configured skin, and opening any map restores it. hitobjects already on screen keep the old skin's sizes until they expire." },
  { "clear_skin_override", luaapi_beatmap_clear_skin_override,
    "void Beatmap.clear_skin_override( void )",
    "restores the configured skin, dropping a set_skin_override. a no-op if nothing was overridden. opening a map does this on its own." },
  { "add_post_pass", luaapi_beatmap_add_post_pass,
    "void Beatmap.add_post_pass{ shader=, src=, dst=, Layer after }",
    "queues a fullscreen shader pass sampling src (string or table) into dst, running after the 'after' layer (default HITOBJECTS). src/dst names may be a render target, 'screen' (the window), or 'backbuffer' (the whole-frame capture; requires [General] Backbuffer: 1)." },
  { "get_accuracy", luaapi_beatmap_get_accuracy,
    "float Beatmap.get_accuracy( void )",
    "the running accuracy from 0 to 1 over objects judged so far. 1 before anything is judged." },
  { "get_combo", luaapi_beatmap_get_combo,
    "int Beatmap.get_combo( void )",
    "the current combo." },
  { "get_max_combo", luaapi_beatmap_get_max_combo,
    "int Beatmap.get_max_combo( void )",
    "the highest combo reached this play." },
  { "get_hit_counts", luaapi_beatmap_get_hit_counts,
    "(int marvelous, int good, int ok, int miss) Beatmap.get_hit_counts( void )",
    "per-result totals over objects judged so far." },
  { "get_unstable_rate", luaapi_beatmap_get_unstable_rate,
    "float Beatmap.get_unstable_rate( void )",
    "unstable rate over hits so far: 10x the standard deviation of hit timing errors. samples circle and slider head hits only." },
  { "get_hit_error_mean", luaapi_beatmap_get_hit_error_mean,
    "float Beatmap.get_hit_error_mean( void )",
    "the mean signed hit timing error in ms over hits so far. negative = early, positive = late." },
  { "get_timing_windows", luaapi_beatmap_get_timing_windows,
    "(float marvelous, float good, float ok, float miss) Beatmap.get_timing_windows( void )",
    "the current hit window half-widths in ms." },
  { "set_timing_windows", luaapi_beatmap_set_timing_windows,
    "void Beatmap.set_timing_windows( float marvelous, float good, float ok, float miss )",
    "sets the hit window half-widths in ms; expects marvelous <= good <= ok <= miss." },
}

luaapi_beatmap_get_music_time_ms :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(beatmap_music_time_ms(&game.beatmap)))
    return 1
}

luaapi_beatmap_get_length_ms :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(game.beatmap.length_ms))
    return 1
}

luaapi_beatmap_get_bpm :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    tp := game.active_map.timing_points[game.beatmap.current_timing_point_index_uninherited]
    lua.pushnumber(L, lua.Number(60000 / max(tp.beat_length, 1)))
    return 1
}

luaapi_beatmap_get_beat_length_ms :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    tp := game.active_map.timing_points[game.beatmap.current_timing_point_index_uninherited]
    lua.pushnumber(L, lua.Number(tp.beat_length))
    return 1
}

luaapi_beatmap_get_beat_proximity :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    at_time_ms := f64(lua.L_optnumber(L, 1, lua.Number(beatmap_music_time_ms(&game.beatmap))))
    lua.pushnumber(L, lua.Number(beat_proximity_factor(at_time_ms)))
    return 1
}

luaapi_beatmap_get_ar_ms :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(game.beatmap.preempt_ms))
    return 1
}

luaapi_beatmap_get_cs_osupx :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(game.beatmap.circle_radius_osupx))
    return 1
}

luaapi_beatmap_is_paused :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushboolean(L, b32(game.paused))
    return 1
}

luaapi_beatmap_set_skin_override :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    name := lua_string(1)

    index, found := skin_reference_find_by_name(name)
    if !found {
        log.warn("User error - skin not found:", name)
        notify_warn("lua: Beatmap.set_skin_override no skin named '%s'", name)
        return 0
    }

    skin_rebind(app.skin_references[index].folder_path)
    return 0
}

luaapi_beatmap_clear_skin_override :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    skin_clear_override()
    return 0
}

luaapi_beatmap_add_layer :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    mapset := game.active_mapset

    name := lua_string(1)

    anchor := Layer.HITOBJECTS
    above  := true
    if lua.istable(L, 2) {
        lua.getfield(L, 2, "anchor")
        if !lua.isnil(L, -1) {
            v := int(lua.tointeger(L, -1))
            if v >= 0 && v < len(Layer) do anchor = Layer(v)
        }
        lua.pop(L, 1)

        lua.getfield(L, 2, "above")
        if !lua.isnil(L, -1) do above = bool(lua.toboolean(L, -1))
        lua.pop(L, 1)
    }
    if anchor == .PLATFORM && above {
        notify_warn("lua: Beatmap.add_layer can't place a layer above PLATFORM")
        return 0
    }
    if len(mapset.custom_layers) >= MAX_CUSTOM_LAYERS {
        notify_warn("lua: Beatmap.add_layer exceeded MAX_CUSTOM_LAYERS (%d)", MAX_CUSTOM_LAYERS)
        return 0
    }

    id := Layer_ID(len(Layer) + len(mapset.custom_layers))
    append(&mapset.custom_layers, Custom_Layer{
        id     = id,
        name   = strings.clone(name, memory.allocators[.MAP_DATA]),
        anchor = anchor,
        above  = above,
    })
    r_rebuild_layer_flush_order(mapset.custom_layers[:])

    lua.pushinteger(L, lua.Integer(int(id)))
    return 1
}

luaapi_beatmap_capture_layers :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    name := lua_string(1)
    fb, found := mapset_render_target_fb(name)
    if !found {
        notify_warn("lua: Beatmap.capture_layers render target not found '%s'", name)
        return 0
    }

    lua.L_checktype(L, 2, lua.TTABLE)
    count := int(lua.objlen(L, 2))
    for i in 1..=count {
        lua.rawgeti(L, 2, lua.Integer(i))
        layer_val := int(lua.tointeger(L, -1))
        lua.pop(L, 1)
        if layer_val >= 0 && layer_val < layer_slot_count() {
            game.active_mapset.layer_capture[layer_val] = fb
        }
    }
    return 0
}

luaapi_beatmap_free_layers :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.L_checktype(L, 1, lua.TTABLE)
    count := int(lua.objlen(L, 1))
    for i in 1..=count {
        lua.rawgeti(L, 1, lua.Integer(i))
        layer_val := int(lua.tointeger(L, -1))
        lua.pop(L, 1)
        if layer_val >= 0 && layer_val < layer_slot_count() {
            game.active_mapset.layer_capture[layer_val] = builtin_framebuffer(.DEFAULT)
        }
    }
    return 0
}

luaapi_beatmap_add_post_pass :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.L_checktype(L, 1, lua.TTABLE)
    mapset := game.active_mapset

    if len(mapset.post_passes) >= MAX_POST_PASSES {
        notify_warn("lua: Beatmap.add_post_pass exceeded MAX_POST_PASSES (%d)", MAX_POST_PASSES)
        return 0
    }

    lua.getfield(L, 1, "shader")
    shader_name := string(lua.tostring(L, -1))
    pipeline, shader_found := mapset_pipeline_slot(shader_name)
    lua.pop(L, 1)
    if !shader_found {
        notify_warn("lua: Beatmap.add_post_pass shader not found '%s'", shader_name)
        return 0
    }

    lua.getfield(L, 1, "dst")
    dst_name := string(lua.tostring(L, -1))
    lua.pop(L, 1)
    dst: Framebuffer_ID
    if dst_name == BACKBUFFER_TEXTURE_NAME {
        dst = builtin_framebuffer(.BACKBUFFER)
    } else if dst_name != "screen" {
        dfb, dst_found := mapset_render_target_fb(dst_name)
        if !dst_found {
            notify_warn("lua: Beatmap.add_post_pass dst render target not found '%s'", dst_name)
            return 0
        }
        dst = dfb
    }

    after := layer_id(.HITOBJECTS)
    lua.getfield(L, 1, "after")
    if !lua.isnil(L, -1) {
        v := int(lua.tointeger(L, -1))
        if v >= 0 && v < layer_slot_count() do after = Layer_ID(v)
    }
    lua.pop(L, 1)

    pass := Post_Pass{
        pipeline   = pipeline,
        dst        = dst,
        after      = after,
        quad_index = u32(len(mapset.post_passes)),
    }

    add_src :: proc(pass: ^Post_Pass, name: string) {
        if pass.src_count >= 4 do return
        slot, ok := mapset_texture_slot(name)
        if ok {
            pass.src[pass.src_count] = slot
            pass.src_count += 1
        } else {
            notify_warn("lua: Beatmap.add_post_pass src not found '%s'", name)
        }
    }

    lua.getfield(L, 1, "src")
    if lua.istable(L, -1) {
        n := int(lua.objlen(L, -1))
        for i in 1..=n {
            lua.rawgeti(L, -1, lua.Integer(i))
            add_src(&pass, string(lua.tostring(L, -1)))
            lua.pop(L, 1)
        }
    } else {
        add_src(&pass, string(lua.tostring(L, -1)))
    }
    lua.pop(L, 1)

    // note(isak): tex_index carries src[0] for bindless sampling; non-bindless binds srcs to
    // texture units 0.. and samples those, so the quad just points at unit 0.
    quad_tex_index: u32 = pass.src[0] if window.bindless_supported else 0
    window.fullscreen_store.data[pass.quad_index] = Quad{
        pos_min   = {0, 0},
        pos_max   = {1, 1},
        uv_min    = {0, 0},
        uv_max    = {1, 1},
        color     = transmute(u32)color_white,
        tex_index = quad_tex_index,
        transform_index = TRANSFORM_SLOT_CLIPSPACE,
    }

    append(&mapset.post_passes, pass)
    return 0
}

luaapi_beatmap_get_accuracy :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(score_accuracy(&game.beatmap.score)))
    return 1
}

luaapi_beatmap_get_combo :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushinteger(L, lua.Integer(game.beatmap.score.combo))
    return 1
}

luaapi_beatmap_get_max_combo :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushinteger(L, lua.Integer(game.beatmap.score.max_combo))
    return 1
}

luaapi_beatmap_get_hit_counts :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    score := &game.beatmap.score
    lua.pushinteger(L, lua.Integer(score.hit_counts[.MARVELOUS]))
    lua.pushinteger(L, lua.Integer(score.hit_counts[.GOOD]))
    lua.pushinteger(L, lua.Integer(score.hit_counts[.OK]))
    lua.pushinteger(L, lua.Integer(score.hit_counts[.MISS]))
    return 4
}

luaapi_beatmap_get_unstable_rate :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(score_hit_error_stats().unstable_rate))
    return 1
}

luaapi_beatmap_get_hit_error_mean :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(score_hit_error_stats().mean))
    return 1
}

luaapi_beatmap_get_timing_windows :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    windows := game.beatmap.timing_windows
    lua.pushnumber(L, lua.Number(windows.marvelous))
    lua.pushnumber(L, lua.Number(windows.good))
    lua.pushnumber(L, lua.Number(windows.ok))
    lua.pushnumber(L, lua.Number(windows.miss))
    return 4
}

luaapi_beatmap_set_timing_windows :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    windows := Timing_Window{
        marvelous = f64(lua_number(1)),
        good      = f64(lua_number(2)),
        ok        = f64(lua_number(3)),
        miss      = f64(lua_number(4)),
    }

    if !(windows.marvelous <= windows.good && windows.good <= windows.ok && windows.ok <= windows.miss) {
        notify_warn("set_timing_windows: expected marvelous <= good <= ok <= miss, got %v, %v, %v, %v",
            windows.marvelous, windows.good, windows.ok, windows.miss)
    }

    game.beatmap.timing_windows = windows
    return 0
}



//////////////////////////////////////////////////////
// note(isak): color object API

luaapi_color_static_funcs := []Lua_Function {
  { "rgb", luaapi_color_rgb,
    "int Color.rgb( int r, int g, int b )",
    "packs r, g, b (each 0-255) into an rgba integer with alpha 1." },
  { "rgba", luaapi_color_rgba,
    "int Color.rgba( int r, int g, int b, int a )",
    "packs r, g, b, a (each 0-255) into an rgba integer." },
}

luaapi_color_rgb :: proc "c" (L: ^lua.State) -> (result: i32) {
    r, g, b := lua_int(1), lua_int(2), lua_int(3)
    color := Color{u8(min(r, 255)),u8(min(g, 255)),u8(min(b, 255)),255}
    lua.pushinteger(L, lua.Integer(color_to_pixel_u8(color)))
    return 1
}

luaapi_color_rgba :: proc "c" (L: ^lua.State) -> (result: i32) {
    r, g, b, a := lua_int(1), lua_int(2), lua_int(3), lua_int(4)
    color := Color{u8(min(r, 255)),u8(min(g, 255)),u8(min(b, 255)),u8(min(a, 255))}
    lua.pushinteger(L, lua.Integer(color_to_pixel_u8(color)))
    return 1
}


//////////////////////////////////////////////////////
// note(isak): playfield API

luaapi_playfield_static_funcs := []Lua_Function {
  { "set_translation", luaapi_playfield_set_translation,
    "void Playfield.set_translation( float x, float y )",
    "sets the playfield offset in osupx, on top of the base centering translation." },
  { "set_scale", luaapi_playfield_set_scale,
    "void Playfield.set_scale( float scale )",
    "sets the playfield scale multiplier (1.0 = default size)." },
  { "set_rotation", luaapi_playfield_set_rotation,
    "void Playfield.set_rotation( float radians )",
    "sets the playfield rotation in radians around the rotation anchor." },
  { "set_rotation_anchor", luaapi_playfield_set_rotation_anchor,
    "void Playfield.set_rotation_anchor( float x, float y )",
    "sets the rotation pivot in osupx (default 256, 192 = visible playfield center)." },
  { "translate", luaapi_playfield_translate,
    "void Playfield.translate( float x, float y )",
    "adds to the current playfield translation in osupx." },
  { "rotate", luaapi_playfield_rotate,
    "void Playfield.rotate( float radians )",
    "adds to the current playfield rotation in radians." },
  { "scale", luaapi_playfield_scale,
    "void Playfield.scale( float scale )",
    "multiplies the current playfield size by the value." },
}

luaapi_playfield_set_translation :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_translation_osupx = {f32(lua.L_checknumber(L, 1)), f32(lua.L_checknumber(L, 2))}
    game.playfield_dirty_transform = true
    return 0
}

luaapi_playfield_set_scale :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_scale = f32(lua.L_checknumber(L, 1))
    game.playfield_dirty_transform = true
    return 0
}

luaapi_playfield_set_rotation :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_rotation_rad = f32(lua.L_checknumber(L, 1))
    game.playfield_dirty_transform = true
    return 0
}

luaapi_playfield_set_rotation_anchor :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_rotation_anchor_osupx = {f32(lua.L_checknumber(L, 1)), f32(lua.L_checknumber(L, 2))}
    game.playfield_dirty_transform = true
    return 0
}

luaapi_playfield_translate :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_translation_osupx += {f32(lua.L_checknumber(L, 1)), f32(lua.L_checknumber(L, 2))}
    game.playfield_dirty_transform = true
    return 0
}

luaapi_playfield_rotate :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_rotation_rad += f32(lua.L_checknumber(L, 1))
    game.playfield_dirty_transform = true
    return 0
}

luaapi_playfield_scale :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_scale *= f32(lua.L_checknumber(L, 1))
    game.playfield_dirty_transform = true
    return 0
}



//////////////////////////////////////////////////////
// note(isak): shader object API

// todo(isak): this is mostly untested code.

luaapi_shader_static_funcs := []Lua_Function {
  { "set_param", luaapi_shader_set_param,
    "void Shader.set_param( int index, float value )",
    "writes a single float into the user param buffer at index (0-63)." },
  { "set_vec4", luaapi_shader_set_vec4,
    "void Shader.set_vec4( int index, float x, float y, float z, float w )",
    "writes a vec4 into the user param buffer at index (0-15)." },
}

luaapi_shader_set_param :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    index := int(lua_int(1))
    value := f32(lua_number(2))
    if index < 0 || index >= 64 {
        return lua.L_error(L, "Shader.set_param: index must be 0-63")
    }
    val := value
    gl.NamedBufferSubData(window.user_param_buffer.id,
        index * size_of(f32), size_of(f32), &val)
    return 0
}

luaapi_shader_set_vec4 :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    index := int(lua_int(1))
    x := f32(lua_number(2))
    y := f32(lua_number(3))
    z := f32(lua_number(4))
    w := f32(lua_number(5))
    if index < 0 || index >= 16 {
        return lua.L_error(L, "Shader.set_vec4: index must be 0-15")
    }
    vals := [4]f32{x, y, z, w}
    gl.NamedBufferSubData(window.user_param_buffer.id,
        index * size_of([4]f32), size_of([4]f32), &vals)
    return 0
}

//////////////////////////////////////////////////////
// note(Jacky): Window API

luaapi_window_static_funcs := []Lua_Function {
  { "get_size", luaapi_window_get_size,
    "(float x, float y) Window.get_size( void )",
    "returns the window size in pixels." },
  { "get_size_px", luaapi_window_get_size,
    "(float x, float y) Window.get_size_px( void )",
    "returns the window size in pixels (alias of get_size)." },
  { "get_size_osupx", luaapi_window_get_size_osupx,
    "(float w, float h) Window.get_size_osupx( void )",
    "returns the window size in playfield osupx. set a drawable's size to this to fill the screen, then move it freely in osupx. assumes no playfield rotation; use drawable:set_fullscreen for the rotated case." },
  { "px_to_osupx", luaapi_window_px_to_osupx,
    "(float x, float y) Window.px_to_osupx( float x, float y )",
    "converts a screen-space pixel position into playfield osupx (full transform: translate/scale/rotate)." },
  { "osupx_to_px", luaapi_window_osupx_to_px,
    "(float x, float y) Window.osupx_to_px( float x, float y )",
    "converts a playfield osupx position into screen-space pixels (full transform: translate/scale/rotate)." },
  { "get_pos", luaapi_window_get_pos,
    "(float x, float y) Window.get_pos( void )",
    "returns the window position in pixels." },
  { "set_size", luaapi_window_set_size,
    "(float width, float height) Window.set_size( float width, float height )",
    "sets the window size in pixels." },
  { "set_pos", luaapi_window_set_pos,
    "(float x, float y) Window.set_pos( float x, float y )",
    "sets the window position in pixels." },
  { "set_opacity", luaapi_window_set_opacity,
    "(float opacity) Window.set_opacity( float opacity )",
    "fades the background drawable to opacity (0-1) and toggles window transparency below 1." },
  { "debug", luaapi_window_debug,
    "(bool ok) Window.debug( bool ok )",
    "enables or disables debug mode." },
}

luaapi_window_get_size :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(window.rect.w))
    lua.pushnumber(L, lua.Number(window.rect.h))
    return 2
}

luaapi_window_get_size_osupx :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    k := playfield_px_per_osupx()
    lua.pushnumber(L, lua.Number(window.rect.w / k))
    lua.pushnumber(L, lua.Number(window.rect.h / k))
    return 2
}

luaapi_window_px_to_osupx :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    osupx := screenspace_to_playfield_osupx({f32(lua_number(1)), f32(lua_number(2))})
    lua.pushnumber(L, lua.Number(osupx.x))
    lua.pushnumber(L, lua.Number(osupx.y))
    return 2
}

luaapi_window_osupx_to_px :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    px := playfield_osupx_to_screenspace({f32(lua_number(1)), f32(lua_number(2))})
    lua.pushnumber(L, lua.Number(px.x))
    lua.pushnumber(L, lua.Number(px.y))
    return 2
}

luaapi_window_get_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    lua.pushnumber(L, lua.Number(window.rect.x))
    lua.pushnumber(L, lua.Number(window.rect.y))
    return 2
}

luaapi_window_set_size :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    width, height     := lua_number(1), lua_number(2)
    sdl.SetWindowSize(window.handle, i32(width), i32(height))
    return 0
}

luaapi_window_set_opacity :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    opacity     := lua_number(1)
    // sdl.SetWindowOpacity(window.handle, f32(opacity))
    bg, ok := slotmap.get(&game.beatmap.drawables, game.beatmap.bg_handle)
    if ok {
        bg.color.a = u8(opacity * 255)
    }
    if opacity >= 1 {
        window.transparent = false
    } else{
        window.transparent = true
    }
    return 0
}

luaapi_window_debug :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    bg, ok := slotmap.get(&game.beatmap.drawables, game.beatmap.bg_handle)
    lua.pushboolean(L, b32(ok))
    return 1
}

luaapi_window_set_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    x, y     := lua_number(1), lua_number(2)
    sdl.SetWindowPosition(window.handle, i32(x), i32(y))
    window.rect.x = f32(x)
    window.rect.y = f32(y)
    return 0
}
