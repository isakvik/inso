package notosu

import "base:runtime"
import "base:intrinsics"
import "core:log"
import os "core:os/os2"
import "core:slice"
import "core:strings"
import q "core:container/queue"
import "core:reflect"

import "slotmap"
import lua "luajit"
import sdl "vendor:sdl3"


// note(isak): implementation detail: we're using luajit, which in practice seems to be some kind of 
// wrapper of lua 5.1 that adds some extra stuff from 5.2 or so

lua_beatmap: struct {
    state: ^lua.State,
    odin_context: runtime.Context,
    registered_events: bit_set[Lua_Beatmap_Event_Type],
    
    last_rendered_timestamp_ms: f64,
}

Lua_Beatmap_Event_Type :: enum {
    ON_INIT,
    ON_UPDATE,
    /* todo(isak) hooks unimplemented */ ON_BEAT, 
    /* todo(isak) hooks unimplemented */ ON_BPM_CHANGE,
    /* todo(isak) hooks unimplemented */ ON_PAUSE_CHANGE,
    ON_CONTROLLER_PRESSED,
    ON_CONTROLLER_RELEASED,
    ON_KEY_DOWN,
    ON_KEY_UP,
    /* todo(isak) hooks unimplemented */ ON_CURSOR_MOVED,
    /* todo(isak) hooks unimplemented */ ON_JUDGEMENT,
}
lua_beatmap_event_names := [Lua_Beatmap_Event_Type]cstring {
    .ON_INIT = "on_init",
    .ON_UPDATE = "on_update",
    .ON_BEAT = "on_beat",
    .ON_BPM_CHANGE = "on_bpm_change",
    .ON_PAUSE_CHANGE = "on_pause_change",
    .ON_CONTROLLER_PRESSED = "on_controller_pressed",
    .ON_CONTROLLER_RELEASED = "on_controller_released",
    .ON_KEY_DOWN = "on_key_pressed",
    .ON_KEY_UP = "on_key_released",
    .ON_CURSOR_MOVED = "on_cursor_moved",
    .ON_JUDGEMENT = "on_judgement",
}


Lua_Class_Type :: enum {
    DRAWABLE,
    ELEMENT,
    ANIMATION,
    TWEEN,
    HITOBJECT,
    COLOR,
}

Lua_Class :: struct {
    name: cstring,
    static_funcs: []lua.L_Reg,
    instance_funcs: []lua.L_Reg,
}

lua_classes: [Lua_Class_Type]Lua_Class = {
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
    .TWEEN = {
        name            = "Tween",
        static_funcs    = luaapi_tween_static_funcs,
    },
    .HITOBJECT = {
        name            = "Hitobject",
        static_funcs    = luaapi_hitobject_static_funcs,
        instance_funcs  = luaapi_hitobject_instance_funcs,
    },
    .COLOR = {
        name            = "Color",
        static_funcs    = luaapi_color_static_funcs,
    },
}

luaapi_global_funcs := []lua.L_Reg {
  { "load_file", lua_global_load_file },
  { "controller_is_down", lua_controller_is_down },
  { "controller_is_up", lua_controller_is_up },
  { "key_is_down", lua_key_is_down },
  { "key_is_up", lua_key_is_up },
}

// note(isak): we use reflection to pull the names and associated enums directly to lua tables
luaapi_enum_constants := [?]struct { t: typeid, name: cstring }{
    { Layer, "Layer" },
    { Judgement, "Judgement" },
    { Layout_Anchor, "Anchor" },
}

//////////////////////////////////////////////////////
// note(isak): lua core

LUA_WATCHDOG_INSTRUCTION_COUNT :: 1_000_000

lua_create_beatmap_script_context :: proc(script_path: string) {
    script_file_len, err := file_size(script_path)
    if err != os.General_Error.None {
        log.errorf("loading lua script '{}' failed, error: {}", script_path, err)
        return
    }
    if script_file_len == 0 {
        log.errorf("loading lua script '{}' failed, empty file", script_path)
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
    
    if lua.L_dofile(L, strings.clone_to_cstring(script_path)) !=  lua.OK {
        lua_log_error("Lua initialization error:")
    } else {
        lua_check_registered_events(L)
    }
}

lua_cleanup :: proc() {
    if lua_beatmap.state != nil {
        lua.close(lua_beatmap.state)
    }
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
            lua.L_setfuncs(L, raw_data(class.instance_funcs), 0)
            lua.pop(L, 1)
        }
        
        // note(isak): sets up type methods like Class.new(...)
        if len(class.static_funcs) > 0 {
            lua.newtable(L)
            lua.L_setfuncs(L, raw_data(class.static_funcs), 0)
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
        } else {
            lua.pop(L, 1)
        }
    }
}

lua_cares_about_event :: proc(event: Lua_Beatmap_Event_Type) -> bool {
    return lua_beatmap.registered_events & {event} != {}
}

lua_int :: proc "c" (at: i32) -> lua.Integer { return lua.L_checkinteger(lua_beatmap.state, at) }
lua_number :: proc "c" (at: i32) -> lua.Number { return lua.L_checknumber(lua_beatmap.state, at) }
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
    
    log.error(log_str, "\n", lua.tostring(L, -1), sep = "", location = location)
    lua.pop(L, 1)
    
    intrinsics.debug_trap()
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
// note(isak): global beatmap communication API

lua_global_load_file :: proc "c" (L: ^lua.State) -> i32 {
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

lua_controller_is_down :: proc "c" (L: ^lua.State) -> i32 {
    key_name := lua.L_checkstring(L, 1)
    result: bool
    switch key_name {
    case "k1": result = is_down(game.input.k1)
    case "k2": result = is_down(game.input.k2)
    case "m1": result = is_down(game.input.m1)
    case "m2": result = is_down(game.input.m2)
    }
    lua.pushboolean(L, b32(result))
    return 1
}

lua_controller_is_up :: proc "c" (L: ^lua.State) -> i32 {
    key_name := lua.L_checkstring(L, 1)
    result: bool
    switch key_name {
    case "k1": result = !is_down(game.input.k1)
    case "k2": result = !is_down(game.input.k2)
    case "m1": result = !is_down(game.input.m1)
    case "m2": result = !is_down(game.input.m2)
    }
    lua.pushboolean(L, b32(result))
    return 1
}

lua_key_is_down :: proc "c" (L: ^lua.State) -> i32 {
    key_name := lua.L_checkstring(L, 1)
    scancode := sdl.GetScancodeFromName(key_name)
    lua.pushboolean(L, b32(is_key_down(scancode)))
    return 1
}

lua_key_is_up :: proc "c" (L: ^lua.State) -> i32 {
    key_name := lua.L_checkstring(L, 1)
    scancode := sdl.GetScancodeFromName(key_name)
    lua.pushboolean(L, b32(is_key_down(scancode)))
    return 1
}


//////////////////////////////////////////////////////
// note(isak): beatmap event API

lua_beatmap_on_update :: proc(time_ms: f64) {
    lua_call_beatmap_func("on_update", time_ms,
        proc(time_ms: f64) -> i32 {
            lua.pushnumber(lua_beatmap.state, lua.Number(time_ms))
            return 1
        }
    )
}

lua_beatmap_on_beat :: proc(beat: int) {
    lua_call_beatmap_func("on_beat", beat,
        proc(beat: int) -> i32 {
            lua.pushinteger(lua_beatmap.state, lua.Integer(beat))
            return 1
        }
    )
}

lua_beatmap_on_bpm_change :: proc(beat: int) {
    lua_call_beatmap_func("on_bpm_change", beat,
        proc(beat: int) -> i32 {
            lua.pushinteger(lua_beatmap.state, lua.Integer(beat))
            return 1
        }
    )
}

lua_beatmap_on_pause_change :: proc(paused: bool) {
    lua_call_beatmap_func("on_bpm_change", paused,
        proc(paused: bool) -> i32 {
            lua.pushboolean(lua_beatmap.state, b32(paused))
            return 1
        }
    )
}

lua_beatmap_on_controller_pressed :: proc(key: cstring) {
    lua_call_beatmap_func("on_controller_pressed", key,
        proc(key: cstring) -> i32 {
            lua.pushstring(lua_beatmap.state, key)
            return 1
        }
    )
}
lua_beatmap_on_controller_released :: proc(key: cstring) {
    lua_call_beatmap_func("on_controller_released", key,
        proc(key: cstring) -> i32 {
            lua.pushstring(lua_beatmap.state, key)
            return 1
        }
    )
}

lua_beatmap_on_key_pressed :: proc(key: sdl.Scancode) {
    lua_call_beatmap_func("on_key_pressed", key,
        proc(key: sdl.Scancode) -> i32 {
            lua.pushstring(lua_beatmap.state, sdl.GetScancodeName(key))
            return 1
        }
    )
}
lua_beatmap_on_key_released :: proc(key: sdl.Scancode) {
    lua_call_beatmap_func("on_key_released", key,
        proc(key: sdl.Scancode) -> i32 {
            lua.pushstring(lua_beatmap.state, sdl.GetScancodeName(key))
            return 1
        }
    )
}

lua_beatmap_on_cursor_moved :: proc(pos: vec2) {
    lua_call_beatmap_func("on_cursor_moved", pos,
        proc(pos: vec2) -> i32 {
            lua.pushnumber(lua_beatmap.state, lua.Number(pos.x))
            lua.pushnumber(lua_beatmap.state, lua.Number(pos.y))
            return 2
        }
    )
}

Lua_Judgement_Result :: struct {
    hobj_index: int,
    judgement: Judgement,
    timing_error_ms: f64,
}

lua_beatmap_on_judgement :: proc(judgement: Lua_Judgement_Result) {
    lua_call_beatmap_func("on_key_released", judgement,
        proc(judgement: Lua_Judgement_Result) -> i32 {
            
            judgement_name: cstring
            switch judgement.judgement {
            case .NONE: judgement_name = "None"
            case .MISS: judgement_name = "Miss"
            case .BAD: judgement_name = "Bad"
            case .GOOD: judgement_name = "Good"
            case .GREAT: judgement_name = "Great"
            case .SLIDER_SMALL_SCOREPOINT: judgement_name = "SliderSmallScorepoint"
            case .SLIDER_LARGE_SCOREPOINT: judgement_name = "SliderLargeScorepoint"
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
    lua_register_instruction_count_hook()
    lua.getglobal(L, name)
    
    param_count := param_writer(data)
    if (lua.pcall(L, param_count, 0, 0) != lua.OK) {
        lua_log_error()
    }
}

_lua_call_beatmap_func_no_params :: proc(name: cstring) {
    L:= lua_beatmap.state
    lua_register_instruction_count_hook()
    lua.getglobal(L, name)
    if (lua.pcall(L, 0, 0, 0) != lua.OK) {
        lua_log_error()
    }
} 

lua_call_beatmap_func :: proc {
    _lua_call_beatmap_func_no_params,
    _lua_call_beatmap_func_with_params,
}


//////////////////////////////////////////////////////
// note(isak): element object API

@(private="file")
luaapi_element_static_funcs := []lua.L_Reg {
  { "new",           luaapi_element_new },
  { nil,             nil               },
}

@(private="file")
luaapi_element_instance_funcs := []lua.L_Reg {
  { "__gc", luaapi_element_gc },
  { "set_tex", luaapi_element_set_tex },
  { "set_shader", luaapi_element_set_shader },
  { "set_animation", luaapi_element_set_animation },
  { nil, nil },
}

luaapi_element_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    //log.info("GC triggered for drawable: ")
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

//////////////////////////////////////////////////////
// note(isak): animation list API

@(private="file")
luaapi_animation_static_funcs := []lua.L_Reg {
  { "new", luaapi_animation_new },
  { nil, nil },
}

@(private="file")
luaapi_animation_instance_funcs := []lua.L_Reg {
  { "move", luaapi_animation_move },
  { "scale", luaapi_animation_scale },
  { "rotate", luaapi_animation_rotate },
  { "color", luaapi_animation_color },
  { "alpha", luaapi_animation_alpha },
  { "texture", luaapi_animation_texture },
  { nil, nil },
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
    q.append(&game.beatmap.animations, Animation_Translate{
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
    q.append(&game.beatmap.animations, Animation_Scale{
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
    q.append(&game.beatmap.animations, Animation_Rotate{
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
    
    q.append(&game.beatmap.animations, Animation_Color{
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
    q.append(&game.beatmap.animations, Animation_Alpha{
        start_time  = f64(start),
        end_time    = f64(end),
        start_alpha = from,
        end_alpha   = to
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

luaapi_animation_texture :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_beatmap.odin_context
    
    anim_list := cast(^Script_Animation_List)lua.L_checkudata(L, 1, lua_classes[.ANIMATION].name)
    _lua_check_animation_list_and_potentially_relocate(anim_list)
    
    start, end := lua_number(2), lua_number(3)
    tex_name := lua_string(4)
    tex_id, found := mapset_texture_slot(tex_name)
    if !found {
        log.error("User error - texture not found:", tex_name)
        tex_id = builtin_texture(.WHITE)
    }
    
    q.append(&game.beatmap.animations, Animation_Texture{
        start_time = f64(start),
        end_time   = f64(end),
        texture_id = tex_id 
    })
    anim_list.num_animations += 1
    return lua_return_self()
}

//////////////////////////////////////////////////////
// note(isak): tween API

@(private="file")
luaapi_tween_static_funcs := []lua.L_Reg {
  { nil, nil },
}

// todo(isak)

//////////////////////////////////////////////////////
// note(isak): drawable object API

@(private="file")
luaapi_drawable_static_funcs := []lua.L_Reg {
  { "new", luaapi_drawable_new },
  { nil, nil },
}

@(private="file")
luaapi_drawable_instance_funcs := []lua.L_Reg {
  { "__gc", luaapi_drawable_gc },
  { "clone", luaapi_drawable_clone },
  { "set_layer", luaapi_drawable_set_layer },
  { "set_pos", luaapi_drawable_set_pos },
  { "set_size", luaapi_drawable_set_size },
  { "set_anchor", luaapi_drawable_set_anchor },
  { "set_color", luaapi_drawable_set_color },
  //{ "set_vel", luaapi_drawable_set_vel },
  //{ "set_accel", luaapi_drawable_set_accel },
  //{ "set_angle_vel", luaapi_drawable_set_angle_vel },
  { "set_start_time", luaapi_drawable_set_start_time },
  { "set_end_time", luaapi_drawable_set_end_time },
  { "set_time", luaapi_drawable_set_time },
  { nil, nil },
}

luaapi_drawable_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    //log.debug("GC triggered for drawable:", handle.generation, handle.index)
    slotmap.remove(&game.beatmap.drawables, handle^)
    return result
}

luaapi_drawable_new :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    
    element := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    // todo(isak) what happens when element isnt found
    
    start_time := f64(lua.L_optnumber(L, 2, lua.Number(game.beatmap.start_time_ms)))
    end_time   := f64(lua.L_optnumber(L, 3, lua.Number(game.beatmap.length_ms)))
    
    handle := cast(^Drawable_Handle)lua.newuserdata(L, size_of(Drawable_Handle))
    handle^ = drawable_new_expiring(&game.beatmap.map_expiring_gfx, {
        element = element^,
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

//////////////////////////////////////////////////////
// note(isak): hitobject object API

@(private="file")
luaapi_hitobject_static_funcs := []lua.L_Reg {
  { "get_at_ms", luaapi_hitobject_get_at_ms },
  { "get_in_range_ms", luaapi_hitobject_get_in_range_ms },
  { nil, nil },
}

@(private="file")
luaapi_hitobject_instance_funcs := []lua.L_Reg {
  { "__gc", luaapi_hitobject_gc },
  { "hide", luaapi_hitobject_hide },
  { "unhide", luaapi_hitobject_unhide },
  { "get_pos", luaapi_hitobject_get_pos },
  { "set_pos", luaapi_hitobject_set_pos },
  { "get_start_time", luaapi_hitobject_get_start_time },
  { "set_start_time", luaapi_hitobject_set_start_time },
  { "get_end_time", luaapi_hitobject_get_end_time },
  { "set_end_time", luaapi_hitobject_set_end_time },
  { nil, nil },
}

luaapi_hitobject_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    //log.debug("GC triggered for drawable:", handle.generation, handle.index)
    return result
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
    }
    return result
}

luaapi_hitobject_get_in_range_ms :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    from_ms, to_ms := lua_int(1), lua_int(2)
    
    hitobject_index, found := game.active_mapset.hitobject_index_by_ms[int(from_ms)]
    if !found {
        log.warn("User warning - no hitobject at ms:", from_ms)
        hitobject_index = 0
    }
    
    default_array_size: i32 = 64
    lua.createtable(L, default_array_size, 0)
    
    for i in hitobject_index..<len(game.beatmap.hit_objects) {
        hobj := &game.beatmap.hit_objects[i]
        if hobj.start_time_ms < f64(from_ms) do continue
        if f64(to_ms) < hobj.start_time_ms do break
        
        lua_create_userdata(L, i, lua_classes[.HITOBJECT].name)
        
        lua.rawseti(L, -2, i32(i + 1))
    }
    return 1
}

_luaapi_hitobject_op :: proc "c" (
    L: ^lua.State, 
    op: proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32
) -> (result: i32) {
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    if handle^ < len(game.beatmap.hit_objects) {
        hobj := &game.beatmap.hit_objects[handle^]
        result = op(L, hobj) + lua_return_self()
    }
    return result
}

luaapi_hitobject_hide :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        context = lua_beatmap.odin_context
        for handle in hobj.gfx_handles {
            d, found := slotmap.get(&game.beatmap.drawables, handle)
            if found do d.flags &= ~{.ACTIVE}
        }
        return 0
    })
}

luaapi_hitobject_unhide :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        context = lua_beatmap.odin_context
        for handle in hobj.gfx_handles {
            d, found := slotmap.get(&game.beatmap.drawables, handle)
            if found do d.flags |= {.ACTIVE}
        }
        return 0
    })
}

luaapi_hitobject_get_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.pos.x))
        lua.pushnumber(L, lua.Number(hobj.pos.y))
        return 2
    })
}
luaapi_hitobject_set_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        // note(isak): we forcibly make the translation non-relative. might not keep this?
        hobj.script_pos_translation.x = f32(lua_number(2)) - hobj.pos.x
        hobj.script_pos_translation.y = f32(lua_number(3)) - hobj.pos.y
        return 0
    })
}

luaapi_hitobject_get_start_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.start_time_ms))
        return 1
    })
}
luaapi_hitobject_set_start_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        hobj.start_time_ms = f64(lua_number(2))
        return 0
    })
}

luaapi_hitobject_get_end_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        lua.pushnumber(L, lua.Number(hobj.end_time_ms))
        return 1
    })
}
luaapi_hitobject_set_end_time :: proc "c" (L: ^lua.State) -> (result: i32) {
    return _luaapi_hitobject_op(L, proc "c" (L: ^lua.State, hobj: ^Hit_Object) -> i32 {
        hobj.end_time_ms = f64(lua_number(2))
        return 0
    })
}

//////////////////////////////////////////////////////
// note(isak): color object API

@(private="file")
luaapi_color_static_funcs := []lua.L_Reg {
  { "rgb", luaapi_color_rgb },
  { "rgba", luaapi_color_rgba },
  { nil, nil },
}

luaapi_color_rgba :: proc "c" (L: ^lua.State) -> (result: i32) {
    r, g, b, a := lua_int(1), lua_int(2), lua_int(3), lua_int(4)
    color := Color{u8(min(r, 255)),u8(min(g, 255)),u8(min(b, 255)),u8(min(a, 255))}
    lua.pushinteger(L, lua.Integer(color_to_pixel_u8(color)))
    return 1
}

luaapi_color_rgb :: proc "c" (L: ^lua.State) -> (result: i32) {
    r, g, b := lua_int(1), lua_int(2), lua_int(3)
    color := Color{u8(min(r, 255)),u8(min(g, 255)),u8(min(b, 255)),255}
    lua.pushinteger(L, lua.Integer(color_to_pixel_u8(color)))
    return 1
}
