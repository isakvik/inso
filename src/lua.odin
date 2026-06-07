package notosu

import "base:runtime"
import c "core:c"
import "core:fmt"
import "core:log"
import os "core:os"
import "core:slice"
import "core:strings"
import q "core:container/queue"
import "core:reflect"

import "slotmap"
import lua "luajit"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"


// note(isak): implementation detail: we're using luajit, which in practice seems to be some kind of
// wrapper of lua 5.1 that adds some extra stuff from 5.2 or so

// note(isak): API versioning/compat policy
// maps declare a target API version in their .notosu header. when making breaking changes:
//   - prefer add-only (rename new, keep old) until a clean break is necessary
//   - on a breaking change: write compat/vN.lua (loaded before the map script for old versions)
//   - shims can patch static methods directly (Hitobject.old = Hitobject.new) and instance
//     methods via get_class_meta("ClassName") -- see luaapi_get_class_meta
//   - things shims can't fix: event arg order changes, removed enum values the engine no
//     longer handles, structural drawable/hitobject relationship changes -- those need an
//     odin-side version check at the call site

// @beta
// todo(isak): expose scoring state to lua (combo, score, accuracy)
// todo(isak): UV sub-rect support on Element for sprite sheet / atlas workflows
// todo(isak): z-index within a layer (currently insertion-order only)
// todo(isak): animation list relocation is a silent footgun - ordering constraint should be enforced or surfaced clearly

lua_beatmap: struct {
    state: ^lua.State,
    odin_context: runtime.Context,
    registered_events: bit_set[Lua_Beatmap_Event_Type],
    event_registrations: [dynamic]Lua_Event_Registration,
    scheduled_events: [dynamic]Scheduled_Event,

    last_callback: cstring, // last event name dispatched, for crash diagnostics
}

Lua_Beatmap_Event_Type :: enum {
    ON_INIT,
    ON_UPDATE,
    ON_BEAT, 
    ON_TIMING_CHANGE,
    ON_PAUSE_CHANGE,
    ON_CONTROLLER_PRESSED,
    ON_CONTROLLER_RELEASED,
    ON_KEY_DOWN,
    ON_KEY_UP,
    ON_CURSOR_MOVED,
    ON_JUDGEMENT,
    ON_KIAI_CHANGE,
}
lua_beatmap_event_names := [Lua_Beatmap_Event_Type]cstring {
    .ON_INIT = "on_init",
    .ON_UPDATE = "on_update",
    .ON_BEAT = "on_beat",
    .ON_TIMING_CHANGE = "on_timing_change",
    .ON_PAUSE_CHANGE = "on_pause_change",
    .ON_CONTROLLER_PRESSED = "on_controller_pressed",
    .ON_CONTROLLER_RELEASED = "on_controller_released",
    .ON_KEY_DOWN = "on_key_pressed",
    .ON_KEY_UP = "on_key_released",
    .ON_CURSOR_MOVED = "on_cursor_moved",
    .ON_JUDGEMENT = "on_judgement",
    .ON_KIAI_CHANGE = "on_kiai_change",
}


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
}

// note(isak): our own registration entry, a superset of lua.L_Reg that also carries the doc signature and
// description inline so lua_docs.odin can generate the API reference straight from these tables - the docs
// can never drift from what's actually registered. registration synthesizes the lua calls from name/func.
Lua_Function :: struct {
    name:        cstring,
    func:        lua.CFunction,
    signature:   string,  // typed call form shown in the docs, e.g. "(float x, float y) hitobject:get_pos( void )"
    description: string,
}

Lua_Class :: struct {
    name: cstring,
    static_funcs: []Lua_Function,
    instance_funcs: []Lua_Function,
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
}

luaapi_global_funcs := []Lua_Function {
  { "load_file", luaapi_load_file,
    "any load_file( string filename )",
    "loads and runs a lua file from the mapset folder, returning whatever it returns." },
  { "get_cursor_pos", luaapi_get_cursor_pos,
    "(float x, float y) get_cursor_pos( void )",
    "the cursor position in playfield (osupx) space." },
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
    "void schedule_event( string name, float delay_ms )",
    "fires trigger_event(name) after delay_ms of music time. safe to call again from within a callback." },
  { "register_global_event", luaapi_register_global_event,
    "void register_global_event( string name, fn callback )",
    "registers a callback not tied to any object; it receives only the extra args from trigger_event." },
}

// note(isak): we use reflection to pull the names and associated enums directly to lua tables
luaapi_enum_constants := [?]struct { t: typeid, name: cstring }{
    { Layer, "Layer" },
    { Judgement_Type, "Judgement" },
    { Layout_Anchor, "Anchor" },
    { Tween, "Tween" },
    { Hitobject_Phase, "Phase" },
    { Slider_Part, "SliderPart" },
}

Lua_Event_Registration :: struct {
    name:         string,   // points into Lua state memory - valid until Lua state is closed
    callback_ref: lua.Ref,  // luaL_ref into LUA_REGISTRYINDEX
    class:        Lua_Class_Type,
    handle_key:   u64,      // raw handle bits used for GC identification
    is_global:    bool,     // if true: no object arg, callback receives only extra args
}

Scheduled_Event :: struct {
    event_name: string,  // points into Lua state memory - valid until Lua state is closed
    fire_at_ms: f64,
}


//////////////////////////////////////////////////////
// note(isak): lua core

LUA_WATCHDOG_INSTRUCTION_COUNT :: 1_000_000

lua_create_beatmap_script_context :: proc(script_path: string) {
    script_file_len, err := file_size(script_path)
    if err != os.General_Error.None {
        log.errorf("loading lua script '{}' failed, error: {}", script_path, err)
        notify_error("loading lua script '%s' failed, error: %v", script_path, err)
        return
    }
    if script_file_len == 0 {
        log.errorf("loading lua script '{}' failed, empty file", script_path)
        notify_error("loading lua script '%s' failed, empty file", script_path)
        return
    }
    
    state := lua.L_newstate()
    lua_beatmap.state = state
    lua.open_base(state)
    lua.open_table(state)
    lua.open_string(state)
    lua.open_math(state)
    if ODIN_DEBUG {
        lua.open_debug(state)
    }
    //lua.open_package(state) // don't need it
    
    // note(isak): unsafe libraries. you want a map where every note you hit deletes a random file from your PC?
    // this is how you get that
    //lua.open_io(lua_ctx.state) 
    //lua.open_os(lua_ctx.state) 
        
    lua_beatmap.odin_context = context
    L:= lua_beatmap.state

    lua_register_global_funcs(L)
    lua_register_classes(L)
    //lua_register_shader_global(L)
    for e in luaapi_enum_constants {
        lua_register_enum(L, e.t, e.name)
    }
    
    if lua.L_dofile(L, strings.clone_to_cstring(script_path)) == lua.OK {
        lua_check_registered_events(L)
    } else {
        lua_log_error("Lua initialization error:")
    }
}

lua_cleanup :: proc() {
    if lua_beatmap.state != nil {
        lua.close(lua_beatmap.state)
    }
    clear(&lua_beatmap.event_registrations)
    clear(&lua_beatmap.scheduled_events)
    lua_beatmap = {}
}

lua_reload :: proc(script_path: string) {
    lua_cleanup()
    lua_create_beatmap_script_context(script_path)
}


lua_register_instruction_count_hook :: proc() {
    L:= lua_beatmap.state
    lua_watchdog_instruction_count_hook :: proc "c" (L: ^lua.State, ar: ^lua.Debug) {
        lua.L_error(L, "Lua execution error: Exceeded 1 million instructions. Check for infinite loops or increase frame budget")
    }
    lua.sethook(L, lua_watchdog_instruction_count_hook, i32(lua.MASKCOUNT), LUA_WATCHDOG_INSTRUCTION_COUNT)
}

// note(isak): reset count hook before each protected call so the watchdog counter is per callback dispatch, 
// not cumulative across frames
lua_pcall_with_watchdog :: proc(L: ^lua.State, nargs, nresults: i32, error_prefix: string = "Lua error:") -> bool {
    lua_register_instruction_count_hook()
    if lua.pcall(L, nargs, nresults, 0) != lua.OK {
        lua_log_error(error_prefix)
        return false
    }
    return true
}

lua_register_global_funcs :: proc(L: ^lua.State) {
    for global_func in luaapi_global_funcs {
        lua.pushcfunction(L, global_func.func)
        lua.setglobal(L, global_func.name)
    }
}

lua_register_classes :: proc(L: ^lua.State) {
    for class in lua_classes {
        // note(isak): sets up object methods like instance:set_xyz(...)
        if len(class.instance_funcs) > 0 {
            lua.L_newmetatable(L, class.name)
            lua.pushvalue(L, -1)
            lua.setfield(L, -2, "__index")
            for reg in class.instance_funcs {
                lua.pushcfunction(L, reg.func)
                lua.setfield(L, -2, reg.name)
            }
            lua.pop(L, 1)
        }

        // note(isak): sets up type methods like Class.new(...)
        if len(class.static_funcs) > 0 {
            lua.newtable(L)
            for reg in class.static_funcs {
                lua.pushcfunction(L, reg.func)
                lua.setfield(L, -2, reg.name)
            }
            lua.setglobal(L, class.name)
        }
    }
}

lua_register_enum :: proc(L: ^lua.State, e: typeid, tablename: cstring) {
    lua.newtable(L) // storage table
    
    names  := reflect.enum_field_names(e)
    values := reflect.enum_field_values(e)
    for name, i in names {
        lua.pushinteger(L, cast(lua.Integer)values[i])
        fieldname: cstring = strings.unsafe_string_to_cstring(name)
        lua.setfield(L, -2, fieldname)
    }

    lua.newtable(L) // indexable proxy table
    lua.newtable(L) // metatable

    // Move the Storage table into the metatable's __index 
    // This makes the Proxy "redirect" all reads to the Storage table
    lua.pushvalue(L, -3)
    lua.setfield(L, -2, "__index")

    lua.pushcfunction(L, proc "c" (L: ^lua.State) -> i32 {
        return lua.L_error(L, "Cannot modify registered constants.")
    })
    lua.setfield(L, -2, "__newindex")

    lua.setmetatable(L, -2)

    lua.setglobal(L, tablename)
    lua.pop(L, 1)
}

lua_check_registered_events :: proc(L: ^lua.State) {
    for event in Lua_Beatmap_Event_Type {
        lua.getglobal(L, lua_beatmap_event_names[event])
        if (lua.isfunction(L, -1)) {
            lua_beatmap.registered_events |= {event}
        }
        lua.pop(L, 1)
    }
}

lua_cares_about_event :: proc(event: Lua_Beatmap_Event_Type) -> bool {
    return lua_beatmap.registered_events & {event} != {}
}

lua_int :: proc "c" (at: i32) -> lua.Integer { return lua.L_checkinteger(lua_beatmap.state, at) }
lua_number :: proc "c" (at: i32) -> lua.Number { return lua.L_checknumber(lua_beatmap.state, at) }
lua_boolean :: proc "c" (at: i32) -> b32 { return lua.toboolean(lua_beatmap.state, lua.Index(at)) }
lua_string :: proc "c" (at: i32) -> string {
    len: uint
    ptr := transmute(^u8)lua.L_checklstring(lua_beatmap.state, at, &len)
    return string(slice.from_ptr(ptr, int(len)))
}

lua_return_self :: proc "c" () -> i32 {
    lua.pushvalue(lua_beatmap.state, 1)
    return 1
}


lua_log_error :: proc "c" (log_str: string = "Lua error:", location := #caller_location) {
    L:= lua_beatmap.state
    context = lua_beatmap.odin_context

    from_lua := lua.tostring(L, -1)
    lua.pop(L, 1)
    
    log.error(log_str, "\n", from_lua, sep = "", location = location)
    notify_error("%s\n%s", log_str, from_lua)
    //intrinsics.debug_trap()
}

// note(isak): pushes a handle and associates it with the given name. 
// to lua, the handle is opaque
lua_create_userdata :: proc "c" (L: ^lua.State, handle: $T, name: cstring) {
    data := cast(^T)lua.newuserdata(L, size_of(T))
    data^ = handle
    lua.L_getmetatable(L, name)
    lua.setmetatable(L, -2)
}

//////////////////////////////////////////////////////
// note(isak): custom event hook API

// note(isak): pushes the object userdata for the given class + handle_key onto the Lua stack.
// called at trigger time - we reconstruct the userdata rather than holding a ref to it,
// so the object's GC can fire freely.
_lua_push_event_target :: proc(L: ^lua.State, class: Lua_Class_Type, handle_key: u64) {
    #partial switch class {
    case .HITOBJECT: lua_create_userdata(L, int(handle_key), lua_classes[.HITOBJECT].name)
    case .DRAWABLE: lua_create_userdata(L, transmute(Drawable_Handle)handle_key, lua_classes[.DRAWABLE].name)
    case .ELEMENT: lua_create_userdata(L, Element_ID(handle_key), lua_classes[.ELEMENT].name)
    case:
        lua.pushnil(L)
    }
}

// note(isak): called from each object's __gc to clean up its registered events
// and release the callback refs back to the Lua registry.
_unregister_events_for_handle :: proc(class: Lua_Class_Type, handle_key: u64) {
    L := lua_beatmap.state
    i := 0
    for i < len(lua_beatmap.event_registrations) {
        reg := lua_beatmap.event_registrations[i]
        if reg.class == class && reg.handle_key == handle_key {
            lua.L_unref(L, lua.REGISTRYINDEX, c.int(reg.callback_ref))
            unordered_remove(&lua_beatmap.event_registrations, i)
        } else {
            i += 1
        }
    }
}

// note(isak): shared implementation for all three :register_event instance methods.
// called after context is set and the class/handle_key are extracted from the userdata.
//
// also note that the handles are casted into a 64 byte key, so there's a limitation on handle types here
_register_event :: proc(L: ^lua.State, class: Lua_Class_Type, handle_key: u64) -> i32 {
    event_name := lua_string(2)
    if !lua.isfunction(L, 3) {
        return lua.L_error(L, "register_event: argument 3 must be a function")
    }
    lua.pushvalue(L, 3)
    callback_ref := lua.L_ref(L, lua.REGISTRYINDEX)
    append(&lua_beatmap.event_registrations, Lua_Event_Registration{
        name         = event_name,
        callback_ref = callback_ref,
        class        = class,
        handle_key   = handle_key,
    })
    return lua_return_self()
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
    event_name := lua_string(1)
    if !lua.isfunction(L, 2) {
        return lua.L_error(L, "register_global_event: argument 2 must be a function")
    }
    lua.pushvalue(L, 2)
    callback_ref := lua.L_ref(L, lua.REGISTRYINDEX)
    append(&lua_beatmap.event_registrations, Lua_Event_Registration{
        name         = event_name,
        callback_ref = callback_ref,
        is_global    = true,
    })
    return 0
}

// note(isak): schedule_event(delay_ms, name) - fires trigger_event(name) after delay_ms of music time.
// fires even if the script has no on_update. re-entrant safe: callbacks may call schedule_event again.
luaapi_schedule_event :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    event_name := lua_string(1)
    delay_ms   := f64(lua.L_checknumber(L, 2))
    append(&lua_beatmap.scheduled_events, Scheduled_Event{
        event_name = event_name,
        fire_at_ms = beatmap_music_time_ms(&game.beatmap) + delay_ms,
    })
    return 0
}

// note(isak): called each frame from beatmap_on_update. fires any scheduled events whose
// fire_at_ms has passed. uses unordered_remove so callbacks may safely append new entries.
lua_drain_scheduled_events :: proc(time_ms: f64) {
    L := lua_beatmap.state
    if L == nil do return
    i := 0
    for i < len(lua_beatmap.scheduled_events) {
        ev := lua_beatmap.scheduled_events[i]
        if ev.fire_at_ms <= time_ms {
            unordered_remove(&lua_beatmap.scheduled_events, i)
            for reg in lua_beatmap.event_registrations {
                if reg.name != ev.event_name do continue
                lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(reg.callback_ref))
                if !reg.is_global {
                    _lua_push_event_target(L, reg.class, reg.handle_key)
                }
                n_args := i32(0) if reg.is_global else i32(1)
                lua_pcall_with_watchdog(L, n_args, 0, "schedule_event error:")
            }
        } else {
            i += 1
        }
    }
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
    
    lua.pcall(L, 0, 1, 0)
    return 1
}

luaapi_get_cursor_pos :: proc "c" (L: ^lua.State) -> i32 {
    lua.pushnumber(L, lua.Number(game.input.mouse_pos.x))
    lua.pushnumber(L, lua.Number(game.input.mouse_pos.y))
    return 2
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

lua_scancode_from_key_arg :: proc(L: ^lua.State, arg_index: i32) -> (sdl.Scancode, bool) {
    if lua.type(L, lua.Index(arg_index)) == lua.TNUMBER {
        scancode_index := int(lua.L_checkinteger(L, arg_index))
        if scancode_index < 0 || scancode_index >= len(Keyboard_State) {
            return cast(sdl.Scancode)0, false
        }
        return cast(sdl.Scancode)scancode_index, true
    }

    key_name := lua.L_checkstring(L, arg_index)
    return sdl.GetScancodeFromName(key_name), true
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
// note(isak): beatmap event API

lua_beatmap_on_update :: proc(time_ms: f64) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_UPDATE], time_ms,
        proc(time_ms: f64) -> i32 {
            lua.pushnumber(lua_beatmap.state, lua.Number(time_ms))
            return 1
        }
    )
}

lua_beatmap_on_beat :: proc(beat: int) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_BEAT], beat,
        proc(beat: int) -> i32 {
            lua.pushinteger(lua_beatmap.state, lua.Integer(beat))
            return 1
        }
    )
}

lua_beatmap_on_timing_change :: proc(beat: int, bpm: f64) {
    Lua_Timing_Change_Params :: struct {
        beat: int, 
        bpm: f64
    }
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_TIMING_CHANGE], Lua_Timing_Change_Params{beat, bpm},
        proc(params: Lua_Timing_Change_Params) -> i32 {
            lua.pushinteger(lua_beatmap.state, lua.Integer(params.beat))
            lua.pushnumber(lua_beatmap.state, lua.Number(params.bpm))
            return 2
        }
    )
}

lua_beatmap_on_pause_change :: proc(paused: bool) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_PAUSE_CHANGE], paused,
        proc(paused: bool) -> i32 {
            lua.pushboolean(lua_beatmap.state, b32(paused))
            return 1
        }
    )
}

lua_beatmap_on_kiai_change :: proc(kiai: bool) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_KIAI_CHANGE], kiai,
        proc(kiai: bool) -> i32 {
            lua.pushboolean(lua_beatmap.state, b32(kiai))
            return 1
        }
    )
}

lua_beatmap_on_controller_pressed :: proc(key: cstring) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_CONTROLLER_PRESSED], key,
        proc(key: cstring) -> i32 {
            lua.pushstring(lua_beatmap.state, key)
            return 1
        }
    )
}
lua_beatmap_on_controller_released :: proc(key: cstring) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_CONTROLLER_RELEASED], key,
        proc(key: cstring) -> i32 {
            lua.pushstring(lua_beatmap.state, key)
            return 1
        }
    )
}

lua_beatmap_on_key_pressed :: proc(key: sdl.Scancode) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_KEY_DOWN], key,
        proc(key: sdl.Scancode) -> i32 {
            lua.pushstring(lua_beatmap.state, sdl.GetScancodeName(key))
            return 1
        }
    )
}
lua_beatmap_on_key_released :: proc(key: sdl.Scancode) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_KEY_UP], key,
        proc(key: sdl.Scancode) -> i32 {
            lua.pushstring(lua_beatmap.state, sdl.GetScancodeName(key))
            return 1
        }
    )
}

lua_beatmap_on_cursor_moved :: proc(pos: vec2) {
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_CURSOR_MOVED], pos,
        proc(pos: vec2) -> i32 {
            lua.pushnumber(lua_beatmap.state, lua.Number(pos.x))
            lua.pushnumber(lua_beatmap.state, lua.Number(pos.y))
            return 2
        }
    )
}

lua_beatmap_on_judgement :: proc(hobj_index: int, judgement: Judgement_Type, timing_error_ms: f64) {
    Lua_Judgement_Result :: struct {
        hobj_index: int,
        judgement: Judgement_Type,
        timing_error_ms: f64,
    }
    lua_call_beatmap_func(lua_beatmap_event_names[.ON_JUDGEMENT], Lua_Judgement_Result{hobj_index, judgement, timing_error_ms},
        proc(judgement: Lua_Judgement_Result) -> i32 {
            
            judgement_name: cstring
            switch judgement.judgement {
            case .NONE: judgement_name = "None"
            case .MISS: judgement_name = "Miss"
            case .OK: judgement_name = "Ok"
            case .GOOD: judgement_name = "Good"
            case .MARVELOUS: judgement_name = "Marvelous"
            case .SLIDER_SMALL_SCOREPOINT: judgement_name = "SliderSmallScorepoint"
            case .SLIDER_LARGE_SCOREPOINT: judgement_name = "SliderLargeScorepoint"
            case .SLIDER_SCOREPOINT_MISS: judgement_name = "SliderScorepointMiss"
            case .IGNORED_HIT: judgement_name = "IgnoredHit"
            case .COMBO_BREAK: judgement_name = "ComboBreak"
            }
            
            lua_create_userdata(lua_beatmap.state, judgement.hobj_index, lua_classes[.HITOBJECT].name)
            lua.pushstring(lua_beatmap.state, judgement_name)
            lua.pushnumber(lua_beatmap.state, lua.Number(judgement.timing_error_ms))
            return 3
        }
    )
}


_lua_call_beatmap_func_with_params :: proc(name: cstring, data: $T, param_writer: proc(data: T) -> i32) {
    L:= lua_beatmap.state
    lua_beatmap.last_callback = name
    lua.getglobal(L, name)
    
    param_count := param_writer(data)
    lua_pcall_with_watchdog(L, param_count, 0)
}

_lua_call_beatmap_func_no_params :: proc(name: cstring) {
    L:= lua_beatmap.state
    lua_beatmap.last_callback = name
    lua.getglobal(L, name)
    lua_pcall_with_watchdog(L, 0, 0)
} 

lua_call_beatmap_func :: proc {
    _lua_call_beatmap_func_no_params,
    _lua_call_beatmap_func_with_params,
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
  { "get_pos", luaapi_hitobject_get_pos,
    "(float x, float y) hitobject:get_pos( void )",
    "the object's position in osupx (before any script translation)." },
  { "set_pos", luaapi_hitobject_set_pos,
    "self hitobject:set_pos( float x, float y )",
    "moves the object to an absolute osupx position." },
  { "set_pos_screenspace", luaapi_hitobject_set_pos_screenspace,
    "self hitobject:set_pos_screenspace( float x, float y )",
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
    "adds a custom element to draw while the object is in the given phase, replacing the default graphics." },
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
  { "set_cs", luaapi_hitobject_set_cs,
    "self hitobject:set_cs( float cs )",
    "overrides the object's circle size (converted to a radius)." },

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
    _unregister_events_for_handle(.HITOBJECT, u64(handle^))
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
        log.error("User error - no hitobject at ms:", at_ms)
        notify_error("lua: no hitobject at ms %v", at_ms)
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

_luaapi_hitobject_op :: proc "c" (
    L: ^lua.State,
    op: proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32
) -> (result: i32) {
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    if handle^ < len(game.beatmap.hitobjects) {
        hobj := &game.beatmap.hitobjects[handle^]
        result = op(L, hobj) + lua_return_self()
    }
    return result
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

luaapi_hitobject_get_index :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushinteger(L, lua.Integer(hobj.index))
        return 1
    })
}

luaapi_hitobject_get_extra_bits :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushinteger(L, lua.Integer(hobj.extra_bits))
        return 1
    })
}

// note(isak): has_all_bits(mask) - true if every bit in mask is set on this object
luaapi_hitobject_has_all_bits :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        mask := u64(lua_int(2))
        lua.pushboolean(L, b32((hobj.extra_bits & mask) == mask))
        return 1
    })
}

// note(isak): has_any_bits(mask) - true if at least one bit in mask is set on this object
luaapi_hitobject_has_any_bits :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        mask := u64(lua_int(2))
        lua.pushboolean(L, b32((hobj.extra_bits & mask) != 0))
        return 1
    })
}

luaapi_hitobject_get_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.pos.x))
        lua.pushnumber(L, lua.Number(hobj.pos.y))
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

luaapi_hitobject_set_pos_screenspace :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        osupx := screenspace_to_playfield_osupx({f32(lua_number(2)), f32(lua_number(3))})
        hobj.script_pos_translation = osupx - hobj.pos
        return 0
    })
}

luaapi_hitobject_get_start_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
        phase := Hitobject_Phase(lua_int(2))
        el_id := (cast(^Element_ID)lua.L_checkudata(L, 3, lua_classes[.ELEMENT].name))^

        if hobj.custom_elements[phase] == nil {
            context = lua_beatmap.odin_context
            hobj.custom_elements[phase] = hitobject_reserve_phase_elements(hobj, phase)
        }

        el_index := hobj.custom_element_nums[phase]
        hobj.custom_elements[phase][el_index] = el_id
        hobj.custom_element_nums[phase] += 1
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        context = lua_beatmap.odin_context
        hit_anim_len := hobj.custom_hit_animation_len_ms if hobj.custom_hit_animation_len_ms != 0 else OSU_HIT_ANIMATION_LENGTH
        lua.pushnumber(L, lua.Number(hit_anim_len))
        return 0
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        r := f64(hobj.custom_radius_osupx if hobj.custom_radius_osupx != 0 else game.beatmap.circle_radius_osupx)
        lua.pushnumber(L, lua.Number((54.4 * 1.00041 - r) / (4.48 * 1.00041)))
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


luaapi_hitobject_get_slider_distance :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        distance := hobj.slider_state.distance if hobj.type == .SLIDER else 0
        lua.pushnumber(L, lua.Number(distance))
        return 1
    })
}

luaapi_hitobject_get_slider_velocity :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        velocity := hobj.slider_state.velocity if hobj.type == .SLIDER else 0
        lua.pushnumber(L, lua.Number(velocity))
        return 1
    })
}

luaapi_hitobject_get_slider_duration_ms :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        duration := hobj.slider_state.duration_ms if hobj.type == .SLIDER else 0
        lua.pushnumber(L, lua.Number(duration))
        return 1
    })
}

luaapi_hitobject_get_slider_ball_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        angle: f32
        if hobj.type == .SLIDER {
            context = lua_beatmap.odin_context
            path := game.beatmap.slider_paths[hobj.slider_path_index]
            angle = slider_ball_angle_at(hobj, beatmap_music_time_ms(&game.beatmap))
        }
        lua.pushnumber(L, lua.Number(angle))
        return 1
    })
}
luaapi_hitobject_get_slider_ball_angle_at :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
        angle: f32
        if hobj.type == .SLIDER {
            context = lua_beatmap.odin_context
            path := game.beatmap.slider_paths[hobj.slider_path_index]
            angle = slider_ball_angle_at(hobj, f64(lua_number(2)))
        }
        lua.pushnumber(L, lua.Number(angle))
        return 1
    })
}

luaapi_hitobject_get_slider_follow_circle_radius :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hitobject) -> i32 {
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
        return lua_return_self()
    })
}


//////////////////////////////////////////////////////
// note(isak): drawable object API

luaapi_drawable_static_funcs := []Lua_Function {
  { "new", luaapi_drawable_new,
    "Drawable Drawable.new( string|Element source, float start_ms = 0, float end_ms = 0 )",
    "creates a drawable from a texture name or an Element, on the current render layer." },
}

luaapi_drawable_instance_funcs := []Lua_Function {
  { "__gc", luaapi_drawable_gc, "", "" },
  { "register_event", luaapi_drawable_register_event,
    "self drawable:register_event( string name, fn callback )",
    "registers callback to run when name is triggered for this drawable; it receives (self, ...)." },
  { "clone", luaapi_drawable_clone,
    "Drawable drawable:clone( void )",
    "creates an independent copy of this drawable." },
  { "set_layer", luaapi_drawable_set_layer,
    "self drawable:set_layer( Layer layer )",
    "moves the drawable to the given render layer." },
  { "get_pos", luaapi_drawable_get_pos,
    "(float x, float y) drawable:get_pos( void )",
    "the drawable's position." },
  { "set_pos", luaapi_drawable_set_pos,
    "self drawable:set_pos( float x, float y )",
    "sets the drawable's position." },
  { "set_pos_screenspace", luaapi_drawable_set_pos_screenspace,
    "self drawable:set_pos_screenspace( float x, float y )",
    "sets the drawable's position from a screen-space pixel position, converted into playfield osupx." },
  { "get_size", luaapi_drawable_get_size,
    "(float w, float h) drawable:get_size( void )",
    "the drawable's size." },
  { "set_size", luaapi_drawable_set_size,
    "self drawable:set_size( float w, float h )",
    "sets the drawable's size." },
  { "set_anchor", luaapi_drawable_set_anchor,
    "self drawable:set_anchor( Anchor anchor )",
    "sets the drawable's anchor point." },
  { "get_color", luaapi_drawable_get_color,
    "int drawable:get_color( void )",
    "the drawable's color as a packed rgba integer." },
  { "set_color", luaapi_drawable_set_color,
    "self drawable:set_color( int color )",
    "sets the drawable's color from a packed rgba integer (see Color.rgb / Color.rgba)." },
  { "set_vel", luaapi_drawable_set_vel,
    "self drawable:set_vel( float x, float y )",
    "sets the drawable's linear velocity." },
  { "set_accel", luaapi_drawable_set_accel,
    "self drawable:set_accel( float x, float y )",
    "sets the drawable's linear acceleration." },
  { "set_angle_vel", luaapi_drawable_set_angle_vel,
    "self drawable:set_angle_vel( float angle_vel )",
    "sets the drawable's angular velocity." },
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
    "stops the drawable from rendering (clears its active flag)." },
  { "show", luaapi_drawable_show,
    "self drawable:show( void )",
    "resumes rendering the drawable (sets its active flag)." },
}

luaapi_drawable_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    slotmap.remove(&game.beatmap.drawables, handle^)
    _unregister_events_for_handle(.DRAWABLE, transmute(u64)handle^)
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
            log.error("User error - texture not found:", tex_name)
            notify_error("lua: Drawable.new texture not found '%s'", tex_name)
            return 0
        }
        element_id = element_new({ shader = builtin_pipeline_slot(.QUAD), tex = tex_id })
    } else {
        element_id = (cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name))^
    }

    start_time := f64(lua.L_optnumber(L, 2, 0))
    end_time   := f64(lua.L_optnumber(L, 3, 0))
    
    handle := cast(^Drawable_Handle)lua.newuserdata(L, size_of(Drawable_Handle))
    handle^ = drawable_new_expiring(&game.beatmap.map_expiring_gfx, {
        element = element_id,
        flags = {.ACTIVE},
        layer = window.renderer.current_layer,
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

_luaapi_drawable_op :: proc "c" (
    L: ^lua.State, 
    op: proc "c" (L: ^lua.State, d: ^Drawable) -> i32
) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    d, found := slotmap.get(&game.beatmap.drawables, handle^)
    
    if found {
        result = op(L, d) + lua_return_self()
    }
    return result
}

luaapi_drawable_set_layer :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.layer = Layer(lua_int(2))
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
luaapi_drawable_set_pos_screenspace :: proc "c" (L: ^lua.State) -> (result: i32) {
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
luaapi_drawable_get_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    d, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        lua.pushnumber(L, lua.Number(d.pos.x))
        lua.pushnumber(L, lua.Number(d.pos.y))
        result = 2
    }
    return result
}
luaapi_drawable_get_size :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    d, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        lua.pushnumber(L, lua.Number(d.size.x))
        lua.pushnumber(L, lua.Number(d.size.y))
        result = 2
    }
    return result
}
luaapi_drawable_get_color :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    d, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        lua.pushinteger(L, lua.Integer(color_to_pixel_u8(d.color)))
        result = 1
    }
    return result
}
luaapi_drawable_get_start_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    d, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        lua.pushnumber(L, lua.Number(d.start_time_ms))
        result = 1
    }
    return result
}
luaapi_drawable_get_end_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    d, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        lua.pushnumber(L, lua.Number(d.end_time_ms))
        result = 1
    }
    return result
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
luaapi_drawable_set_angle_vel :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.angle_vel = f32(lua_number(2))
        return 0
    })
}

luaapi_drawable_hide :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.flags &= ~{.ACTIVE}
        return 0
    })
}
luaapi_drawable_show :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_drawable_op(L, proc "c" (L: ^lua.State, d: ^Drawable) -> i32 {
        d.flags |= {.ACTIVE}
        return 0
    })
}


//////////////////////////////////////////////////////
// note(isak): element object API

luaapi_element_static_funcs := []Lua_Function {
  { "new", luaapi_element_new,
    "Element Element.new( void )",
    "creates a blank white quad element using the default shader." },
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
    "sets the element's texture by mapset texture name." },
  { "set_uv", luaapi_element_set_uv,
    "self element:set_uv( float x, float y, float w, float h )",
    "sets the uv sub-rect in [0,1] space, picking a region of the texture." },
  { "set_shader", luaapi_element_set_shader,
    "self element:set_shader( string shader_name )",
    "sets the element's shader by mapset pipeline name." },
  { "set_render_target", luaapi_element_set_render_target,
    "self element:set_render_target( string render_target_name )",
    "redirects this element's draws into the named render target instead of the screen." },
  { "set_animation", luaapi_element_set_animation,
    "self element:set_animation( Animation animation )",
    "attaches an animation list to the element." },
  { "set_mesh", luaapi_element_set_mesh,
    "self element:set_mesh( string buffer_name, int vertex_count )",
    "marks the element as mesh-drawn, sourcing geometry from the named SSBO instead of the quad batch." },
  { "use_combo_color", luaapi_element_use_combo_color,
    "self element:use_combo_color( bool enabled )",
    "when enabled, the element tints with the hitobject's combo color." },
}

luaapi_element_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    _unregister_events_for_handle(.ELEMENT, u64(handle^))
    return result
}

luaapi_element_new :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    
    data := cast(^Element_ID)lua.newuserdata(L, size_of(Element_ID))
    data^ = element_new({
        shader = builtin_pipeline_slot(.QUAD),
        tex = builtin_texture(.WHITE),
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
        log.error("User error - texture not found:", tex_name)
        notify_error("lua: Element:set_tex texture not found '%s'", tex_name)
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
        log.error("User error - pipeline not found:", shader_name)
        notify_error("lua: Element:set_shader pipeline not found '%s'", shader_name)
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
        log.error("User error - render target not found:", name)
        notify_error("lua: Element:set_render_target render target not found '%s'", name)
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
        el.animations = game.beatmap.animations.data[list.at:list.at + list.num_animations]
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
    vertex_count := int(lua_int(3))

    buf, found := mapset_buffer(buffer_name)
    if !found {
        log.error("User error - buffer not found:", buffer_name)
        notify_error("lua: Element:set_mesh buffer not found '%s'", buffer_name)
        return lua_return_self()
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
    "Animation Animation.new( void )",
    "creates an empty animation list to attach to an element." },
}

luaapi_animation_instance_funcs := []Lua_Function {
  { "move", luaapi_animation_move,
    "self animation:move( float start, float end, float from_x, float from_y, float to_x, float to_y, Tween tween = 0 )",
    "appends a positional tween from (from_x, from_y) to (to_x, to_y) over [start, end]." },
  { "scale", luaapi_animation_scale,
    "self animation:scale( float start, float end, float from_x, float from_y, float to_x, float to_y, Tween tween = 0 )",
    "appends a scale tween from (from_x, from_y) to (to_x, to_y) over [start, end]." },
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
}

_lua_check_animation_list_and_potentially_relocate :: proc(anim_list: ^Script_Animation_List) {
    if (anim_list.at + anim_list.num_animations) != game.beatmap.animations.len {
        prev_at := anim_list.at
        anim_list.at = game.beatmap.animations.len
        if anim_list.num_animations > 0 {
            // note(isak): we relocate the slice to the end of the animation list if it's not at the end.
            // this leaves holes, but is the best we can do given the stable pointer requirement
            unfinished_anim_list := game.beatmap.animations.data[prev_at:prev_at + anim_list.num_animations]
            q.push_back_elems(&game.beatmap.animations, ..unfinished_anim_list)
            log.warn("Lua warning: relocated animation list to index:", anim_list.at)
        }
    }
}

luaapi_animation_new :: proc "c" (L: ^lua.State) -> i32 {
    handle := Script_Animation_List{ at = game.beatmap.animations.len }
    lua_create_userdata(L, handle, lua_classes[.ANIMATION].name)
    return 1
}

luaapi_animation_move :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)
    
    start, end     := lua_number(2), lua_number(3)
    from_x, from_y := lua_number(4), lua_number(5)
    to_x, to_y     := lua_number(6), lua_number(7)
    tween          := Tween(lua.L_optinteger(L, 8, 0))
    q.append(&game.beatmap.animations, Animation_Translate{
        tween      = tween,
        start_time = f64(start),
        end_time   = f64(end),
        start_pos  = {f32(from_x), f32(from_y)},
        end_pos    = {f32(to_x), f32(to_y)}
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

luaapi_animation_scale :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)
    
    start, end := lua_number(2), lua_number(3)
    from       := vec2{f32(lua_number(4)), f32(lua_number(5))}
    to         := vec2{f32(lua_number(6)), f32(lua_number(7))}
    tween      := Tween(lua.L_optinteger(L, 8, 0))
    q.append(&game.beatmap.animations, Animation_Scale{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_scale = from,
        end_scale   = to,
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

luaapi_animation_rotate :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)
    
    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    q.append(&game.beatmap.animations, Animation_Rotate{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_angle = from,
        end_angle   = to
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

luaapi_animation_color :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)
    
    start, end := lua_number(2), lua_number(3)
    from, to   := color_from_pixel(u32(lua_int(4))), color_from_pixel(u32(lua_int(5)))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    q.append(&game.beatmap.animations, Animation_Color{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_color = from,
        end_color   = to
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

luaapi_animation_alpha :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)
    
    start, end := lua_number(2), lua_number(3)
    from, to   := f32(lua_number(4)), f32(lua_number(5))
    tween      := Tween(lua.L_optinteger(L, 6, 0))
    q.append(&game.beatmap.animations, Animation_Alpha{
        tween       = tween,
        start_time  = f64(start),
        end_time    = f64(end),
        start_alpha = from,
        end_alpha   = to
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

// anim:texture(start, end, tex_name [, layer])
// note(isak): layer is optional; defaults to 0. use for manually picking a frame in a texture array.
luaapi_animation_texture :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)

    start, end := lua_number(2), lua_number(3)
    tex_name := lua_string(4)
    layer := f32(lua.L_optnumber(L, 5, 0))
    tex_id, found := mapset_texture_slot(tex_name)
    if !found {
        log.error("User error - texture not found:", tex_name)
        notify_error("lua: Animation:texture texture not found '%s'", tex_name)
        tex_id = builtin_texture(.WHITE)
    }

    q.append(&game.beatmap.animations, Animation_Texture{
        start_time = f64(start),
        end_time   = f64(end),
        texture_id = tex_id,
        layer      = layer,
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

// anim:frames(start, end, tex_name)
// note(isak): distributes all layers of a texture array as evenly-spaced Animation_Texture keyframes
// over [start, end]. start/end are normalized to [0,1] (drawable lifetime).
luaapi_animation_frames :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context

    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)

    start    := f64(lua_number(2))
    end      := f64(lua_number(3))
    tex_name := lua_string(4)

    tex_slot, found := game.active_mapset.texture_slot_by_name[tex_name]
    if !found {
        log.error("User error - texture not found:", tex_name)
        notify_error("lua: Animation:frames texture not found '%s'", tex_name)
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
        q.append(&game.beatmap.animations, Animation_Texture{
            start_time = frame_start,
            end_time   = frame_end,
            texture_id = tex_id,
            layer      = f32(frame),
        })
        anim_list.num_animations += 1
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
        log.error("User error - buffer not found:", name)
        notify_error("lua: Buffer.get buffer not found '%s'", name)
        lua.pushnil(L)
        return 1
    }
    slot := game.active_mapset.buffer_slot_by_name[name]
    lua_create_userdata(L, slot, lua_classes[.BUFFER].name)
    return 1
}

// buffer:bind(user_slot) -- user_slot is 0-7, maps to USER_0..USER_7
luaapi_buffer_bind :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    slot_index := cast(^u32)lua.L_checkudata(L, 1, lua_classes[.BUFFER].name)
    user_slot  := int(lua_int(2))
    if user_slot < 0 || user_slot > 7 {
        return lua.L_error(L, "Buffer:bind: user_slot must be 0-7")
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
        log.error("User error - sound not found:", name)
        notify_error("lua: Sound.play sound not found '%s'", name)
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
        log.error("User error - sound not found:", name)
        notify_error("lua: Sound.play_loop sound not found '%s'", name)
        return 0
    }
    handle := game_sound_play(sample, loop = true, volume = volume)
    lua_create_userdata(L, handle, lua_classes[.SOUND].name)
    return 1
}

// handle:stop()
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
  { "get_ar_ms", luaapi_beatmap_get_ar_ms,
    "float Beatmap.get_ar_ms( void )",
    "the map's approach (preempt) time in ms." },
  { "get_cs_osupx", luaapi_beatmap_get_cs_osupx,
    "float Beatmap.get_cs_osupx( void )",
    "the map's circle radius in osupx." },
  { "is_paused", luaapi_beatmap_is_paused,
    "bool Beatmap.is_paused( void )",
    "true if playback is currently paused." },
  { "capture_layers", luaapi_beatmap_capture_layers,
    "void Beatmap.capture_layers( string render_target_name, table layers )",
    "redirects every drawable in the given layers into the named render target." },
  { "add_post_pass", luaapi_beatmap_add_post_pass,
    "void Beatmap.add_post_pass{ shader=, src=, dst=, after= }",
    "queues a fullscreen shader pass sampling src (string or table) into dst ('screen' or a target name), running after the `after` layer (default HITOBJECTS)." },
  { "set_timing_windows", luaapi_beatmap_set_timing_windows,
    "void Beatmap.set_timing_windows( float marvelous, float good, float ok, float miss )",
    "sets the hit window half-widths in ms; expects marvelous <= good <= ok <= miss." },
  { "get_timing_windows", luaapi_beatmap_get_timing_windows,
    "(float marvelous, float good, float ok, float miss) Beatmap.get_timing_windows( void )",
    "the current hit window half-widths in ms." },
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

luaapi_beatmap_capture_layers :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    name := lua_string(1)
    fb, found := mapset_render_target_fb(name)
    if !found {
        notify_error("lua: Beatmap.capture_layers render target not found '%s'", name)
        return 0
    }

    lua.L_checktype(L, 2, lua.TTABLE)
    count := int(lua.objlen(L, 2))
    for i in 1..=count {
        lua.rawgeti(L, 2, lua.Integer(i))
        layer_val := int(lua.tointeger(L, -1))
        lua.pop(L, 1)
        if layer_val >= 0 && layer_val < len(Layer) {
            game.active_mapset.layer_capture[Layer(layer_val)] = fb
        }
    }
    return 0
}

luaapi_beatmap_add_post_pass :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    lua.L_checktype(L, 1, lua.TTABLE)
    mapset := game.active_mapset

    if len(mapset.post_passes) >= MAX_POST_PASSES {
        notify_error("lua: Beatmap.add_post_pass exceeded MAX_POST_PASSES (%d)", MAX_POST_PASSES)
        return 0
    }

    lua.getfield(L, 1, "shader")
    shader_name := string(lua.tostring(L, -1))
    pipeline, shader_found := mapset_pipeline_slot(shader_name)
    lua.pop(L, 1)
    if !shader_found {
        notify_error("lua: Beatmap.add_post_pass shader not found '%s'", shader_name)
        return 0
    }

    lua.getfield(L, 1, "dst")
    dst_name := string(lua.tostring(L, -1))
    lua.pop(L, 1)
    dst: Framebuffer_ID
    if dst_name != "screen" {
        dfb, dst_found := mapset_render_target_fb(dst_name)
        if !dst_found {
            notify_error("lua: Beatmap.add_post_pass dst render target not found '%s'", dst_name)
            return 0
        }
        dst = dfb
    }

    after := Layer.HITOBJECTS
    lua.getfield(L, 1, "after")
    if !lua.isnil(L, -1) {
        v := int(lua.tointeger(L, -1))
        if v >= 0 && v < len(Layer) do after = Layer(v)
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
            notify_error("lua: Beatmap.add_post_pass src not found '%s'", name)
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
    }

    append(&mapset.post_passes, pass)
    return 0
}

// note(isak): set_timing_windows(marvelous, good, ok, miss) - hit window half-widths in ms
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

// note(isak): get_timing_windows() -> marvelous, good, ok, miss (hit window half-widths in ms)
luaapi_beatmap_get_timing_windows :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    windows := game.beatmap.timing_windows
    lua.pushnumber(L, lua.Number(windows.marvelous))
    lua.pushnumber(L, lua.Number(windows.good))
    lua.pushnumber(L, lua.Number(windows.ok))
    lua.pushnumber(L, lua.Number(windows.miss))
    return 4
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
// note(isak): Playfield API

luaapi_playfield_static_funcs := []Lua_Function {
  { "set_translation", luaapi_playfield_set_translation,
    "void Playfield.set_translation( float x, float y )",
    "sets the playfield offset in osupx, on top of the base centering translation." },
  { "set_scale", luaapi_playfield_set_scale,
    "void Playfield.set_scale( float scale )",
    "sets the playfield scale multiplier (1.0 = default size)." },
  { "set_rotation", luaapi_playfield_set_rotation,
    "void Playfield.set_rotation( float radians )",
    "sets the playfield rotation in radians around its center." },
  { "translate", luaapi_playfield_translate,
    "void Playfield.translate( float x, float y )",
    "adds to the current playfield translation in osupx." },
  { "rotate", luaapi_playfield_rotate,
    "void Playfield.rotate( float radians )",
    "adds to the current playfield rotation in radians." },
}

// set_translation(x, y) - offset in osupx, applied on top of the base centering translation
luaapi_playfield_set_translation :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_translation_osupx = {f32(lua.L_checknumber(L, 1)), f32(lua.L_checknumber(L, 2))}
    game.playfield_dirty_transform = true
    return 0
}

// set_scale(s) - multiplier on top of the base scale (1.0 = default size)
luaapi_playfield_set_scale :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_scale = f32(lua.L_checknumber(L, 1))
    game.playfield_dirty_transform = true
    return 0
}

// set_rotation(rad) - rotation in radians around the playfield center
luaapi_playfield_set_rotation :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_rotation_rad = f32(lua.L_checknumber(L, 1))
    game.playfield_dirty_transform = true
    return 0
}

// translate(x, y) - adds to the current translation in osupx
luaapi_playfield_translate :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_translation_osupx += {f32(lua.L_checknumber(L, 1)), f32(lua.L_checknumber(L, 2))}
    game.playfield_dirty_transform = true
    return 0
}

// rotate(rad) - adds to the current rotation in radians
luaapi_playfield_rotate :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    game.beatmap.playfield_rotation_rad += f32(lua.L_checknumber(L, 1))
    game.playfield_dirty_transform = true
    return 0
}



//////////////////////////////////////////////////////
// note(isak): shader object API

// todo(isak): this is untested code. it's handled in a slightly strange way, so it should be rewritten.
// currently not hooked up anywhere.

luaapi_shader_funcs := []lua.L_Reg {
  { "set_param", luaapi_shader_set_param },
  { "set_vec4",  luaapi_shader_set_vec4  },
  { nil,         nil                     },
}

lua_register_shader_global :: proc(L: ^lua.State) {
    lua.newtable(L)
    lua.L_setfuncs(L, raw_data(luaapi_shader_funcs), 0)
    lua.setglobal(L, "Shader")
}

// Shader.set_param(index, value) -- write f32 at index (0-63) into the user param UBO
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

// Shader.set_vec4(index, x, y, z, w) -- write 4 floats starting at index*4 (0-15)
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
