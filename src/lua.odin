package inso

import "base:runtime"
import c "core:c"
import "core:log"
import os "core:os"
import "core:slice"
import "core:strings"
import "core:reflect"

import lua "luajit"
import sdl "vendor:sdl3"


// note(isak): implementation detail: we're using luajit, which in practice seems to be some kind of
// wrapper of lua 5.1 that adds some extra stuff from 5.2 or so

lua_beatmap: struct {
    state: ^lua.State,
    odin_context: runtime.Context,
    registered_events: bit_set[Lua_Beatmap_Event_Type],
    event_registrations: [dynamic]Lua_Event_Registration,
    scheduled_events: [dynamic]Scheduled_Event,
    in_init: bool,
    in_judgement_dispatch: bool,

    last_callback: cstring,

    hide_skin_cursor: bool,
    cursor_layer: Layer_ID,
}

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


Lua_Event_Registration :: struct {
    name:         string,
    name_ref:     lua.Ref,  // luaL_ref pinning the name string against GC so name stays valid
    callback_ref: lua.Ref,  // luaL_ref into LUA_REGISTRYINDEX
    class:        Lua_Class_Type,
    handle_key:   u64,      // raw handle bits used for GC identification
    is_global:    bool,     // if true: no object arg, callback receives only extra args
}

Scheduled_Event :: struct {
    fire_at_ms:       f64,

    // note(isak): if callback_ref is set, call directly, or if unset, use event_name
    callback_ref:     lua.Ref,
    event_name:       string,  // borrows the name_ref'd Lua string's bytes; valid while name_ref is held
    name_ref:         lua.Ref, // luaL_ref pinning the name string against GC; released when the event fires
    
    persistent:       bool,
    persistent_fired: bool,
}


//////////////////////////////////////////////////////
// note(isak): lua core

LUA_WATCHDOG_INSTRUCTION_COUNT :: 1_000_000

// note(isak): luajit's dofile/load accept precompiled bytecode (leading signature byte). we error on these
// so mappers can't hide code
LUA_BYTECODE_SIGNATURE :: '\x1b'

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
    if lua_script_is_bytecode(script_path) {
        log.errorf("loading lua script '{}' failed, precompiled bytecode scripts are not allowed", script_path)
        notify_error("loading lua script '%s' failed, precompiled bytecode scripts are not allowed", script_path)
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
    for e in luaapi_enum_constants {
        lua_register_enum(L, e.t, e.name)
    }
    
    if lua.L_dofile(L, strings.clone_to_cstring(script_path, context.temp_allocator)) == lua.OK {
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

lua_script_is_bytecode :: proc(script_path: string) -> bool {
    f, open_err := os.open(script_path)
    if open_err != nil do return false
    defer os.close(f)

    header: [1]u8
    n, read_err := os.read(f, header[:])
    return read_err == nil && n == 1 && header[0] == LUA_BYTECODE_SIGNATURE
}


lua_register_instruction_count_hook :: proc() {
    L:= lua_beatmap.state
    lua_watchdog_instruction_count_hook :: proc "c" (L: ^lua.State, ar: ^lua.Debug) {
        lua.L_error(L, "Lua execution error: Exceeded 1 million instructions. Check for infinite loops or increase frame budget")
    }
    lua.sethook(L, lua_watchdog_instruction_count_hook, i32(lua.MASKCOUNT), LUA_WATCHDOG_INSTRUCTION_COUNT)
}

// note(isak): reset count hook before each protected call so the watchdog counter counts per callback dispatch, 
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
    ptr := cast(^u8)lua.L_checklstring(lua_beatmap.state, at, &len)
    return string(slice.from_ptr(ptr, int(len)))
}

lua_return_self :: proc "c" () -> i32 {
    lua.pushvalue(lua_beatmap.state, 1)
    return 1
}

// note(isak): creates a reference to the string at the given stack index in the registry so its
// TString never gets GCed. valid until L_unref is called. used for event names we save across calls
lua_create_string_ref :: proc "c" (at: i32) -> (borrowed: string, ref: lua.Ref) {
    L := lua_beatmap.state
    borrowed = lua_string(at)
    lua.pushvalue(L, lua.Index(at))
    ref = lua.L_ref(L, lua.REGISTRYINDEX)
    return
}

lua_log_error :: proc "c" (log_str: string = "Lua error:", location := #caller_location) {
    L:= lua_beatmap.state
    context = lua_beatmap.odin_context

    from_lua := lua.tostring(L, -1)
    lua.pop(L, 1)
    
    log.error(log_str, "\n", from_lua, sep = "", location = location)
    notify_error("%s - %s", log_str, from_lua)
    //intrinsics.debug_trap()
}

// note(isak): pushes a handle and associates it with the given name
lua_create_userdata :: proc "c" (L: ^lua.State, handle: $T, name: cstring) {
    data := cast(^T)lua.newuserdata(L, size_of(T))
    data^ = handle
    lua.L_getmetatable(L, name)
    lua.setmetatable(L, -2)
}

//////////////////////////////////////////////////////
// note(isak): custom event hook API

// note(isak): pushes the object userdata for the given class + handle_key onto the Lua stack.
// called at trigger time
_lua_push_event_target :: proc(L: ^lua.State, class: Lua_Class_Type, handle_key: u64) {
    #partial switch class {
    case .HITOBJECT: lua_create_userdata(L, int(handle_key), lua_classes[.HITOBJECT].name)
    case .DRAWABLE: lua_create_userdata(L, transmute(Drawable_Handle)handle_key, lua_classes[.DRAWABLE].name)
    case .ELEMENT: lua_create_userdata(L, Element_ID(handle_key), lua_classes[.ELEMENT].name)
    case:
        lua.pushnil(L)
    }
}

_log_lua_gc :: proc(class: Lua_Class_Type, handle_key: u64) {
    if !app.debug_log_lua_gc do return
    log.infof("lua gc: collected %s handle %v", lua_classes[class].name, handle_key)
}

// note(isak): releases an object's registered callback and name refs back to the Lua registry
lua_unregister_events_for_handle :: proc(class: Lua_Class_Type, handle_key: u64) {
    L := lua_beatmap.state
    i := 0
    for i < len(lua_beatmap.event_registrations) {
        reg := lua_beatmap.event_registrations[i]
        if reg.class == class && reg.handle_key == handle_key {
            lua.L_unref(L, lua.REGISTRYINDEX, c.int(reg.callback_ref))
            lua.L_unref(L, lua.REGISTRYINDEX, c.int(reg.name_ref))
            unordered_remove(&lua_beatmap.event_registrations, i)
        } else {
            i += 1
        }
    }
}

// note(isak): shared implementation for all three :register_event instance methods
_register_event :: proc(L: ^lua.State, class: Lua_Class_Type, handle_key: u64) -> i32 {
    if !lua.isfunction(L, 3) {
        return lua.L_error(L, "register_event: argument 3 must be a function")
    }
    event_name, name_ref := lua_create_string_ref(2)
    lua.pushvalue(L, 3)
    callback_ref := lua.L_ref(L, lua.REGISTRYINDEX)
    append(&lua_beatmap.event_registrations, Lua_Event_Registration{
        name         = event_name,
        name_ref     = name_ref,
        callback_ref = callback_ref,
        class        = class,
        handle_key   = handle_key,
    })
    return lua_return_self()
}

_schedule_callback :: proc "c" (L: ^lua.State, fire_at_ms: f64) -> i32 {
    context = lua_beatmap.odin_context
    if !lua.isfunction(L, 2) {
        return lua.L_error(L, "schedule: argument 2 must be a function")
    }
    lua.pushvalue(L, 2)
    callback_ref := lua.L_ref(L, lua.REGISTRYINDEX)
    append(&lua_beatmap.scheduled_events, Scheduled_Event{
        fire_at_ms   = fire_at_ms,
        callback_ref = callback_ref,
        name_ref     = lua.NOREF,
        persistent   = lua_beatmap.in_init,
    })
    return 0
}


// note(isak): called each frame from beatmap_on_update. fires any scheduled events whose
// fire_at_ms has passed
lua_drain_scheduled_events :: proc(time_ms: f64) {
    L := lua_beatmap.state
    if L == nil do return
    i := 0
    for i < len(lua_beatmap.scheduled_events) {
        ev := lua_beatmap.scheduled_events[i]
        if ev.persistent_fired || ev.fire_at_ms > time_ms {
            i += 1
            continue
        }

        // flag/remove before dispatch so a re-entrant schedule from the callback can't refire this one
        if ev.persistent {
            lua_beatmap.scheduled_events[i].persistent_fired = true
            i += 1
        } else {
            unordered_remove(&lua_beatmap.scheduled_events, i)
        }

        if ev.callback_ref != lua.NOREF {
            lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ev.callback_ref))
            lua_pcall_with_watchdog(L, 0, 0, "schedule_at error:")
            if !ev.persistent do lua.L_unref(L, lua.REGISTRYINDEX, c.int(ev.callback_ref))
        } else {
            for reg in lua_beatmap.event_registrations {
                if reg.name != ev.event_name do continue
                lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(reg.callback_ref))
                if !reg.is_global {
                    _lua_push_event_target(L, reg.class, reg.handle_key)
                }
                n_args := i32(0) if reg.is_global else i32(1)
                lua_pcall_with_watchdog(L, n_args, 0, "schedule_event error:")
            }
            if !ev.persistent do lua.L_unref(L, lua.REGISTRYINDEX, c.int(ev.name_ref))
        }
    }
}

lua_rearm_scheduled_events :: proc(time_ms: f64) {
    L := lua_beatmap.state
    if L == nil do return
    i := 0
    for i < len(lua_beatmap.scheduled_events) {
        ev := &lua_beatmap.scheduled_events[i]
        if ev.persistent {
            if ev.fire_at_ms > time_ms do ev.persistent_fired = false
            i += 1
            continue
        }
        if ev.callback_ref != lua.NOREF {
            lua.L_unref(L, lua.REGISTRYINDEX, c.int(ev.callback_ref))
        } else {
            lua.L_unref(L, lua.REGISTRYINDEX, c.int(ev.name_ref))
        }
        unordered_remove(&lua_beatmap.scheduled_events, i)
    }
}

// note(isak): this appends self for chainable setters, _lua_get doesn't
_lua_op :: proc "c" (
    L: ^lua.State,
    resolve: proc "c" (L: ^lua.State) -> (^$T, bool),
    op: proc "c" (L: ^lua.State, it: ^T) -> i32,
) -> i32 {
    context = lua_beatmap.odin_context
    it, ok := resolve(L)
    if !ok do return 0
    return op(L, it) + lua_return_self()
}

_lua_get :: proc "c" (
    L: ^lua.State,
    resolve: proc "c" (L: ^lua.State) -> (^$T, bool),
    op: proc "c" (L: ^lua.State, it: ^T) -> i32,
) -> i32 {
    context = lua_beatmap.odin_context
    it, ok := resolve(L)
    if !ok do return 0
    return op(L, it)
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
