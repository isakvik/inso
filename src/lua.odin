package notosu

import "base:runtime"
import "core:log"
import os "core:os/os2"
import "core:slice"
import "core:strings"
import q "core:container/queue"

import "slotmap"
import lua "luajit"


// note(isak): implementation detail: we're using luajit, which in practice seems to be some kind of 
// wrapper of lua 5.1 that adds some extra stuff from 5.2 or so it might be 

lua_beatmap: struct {
    state: ^lua.State,
    odin_context: runtime.Context,
    
    last_rendered_timestamp_ms: f64,
}

Lua_Class_Type :: enum {
    DRAWABLE,
    ELEMENT,
    HITOBJECT,
}

Lua_Class :: struct {
    name: cstring,
    static_funcs: []lua.L_Reg,
    instance_funcs: []lua.L_Reg,
}

lua_classes: [Lua_Class_Type]Lua_Class = {
    .DRAWABLE = {
        name = "Drawable",
        static_funcs = luaapi_drawable_static_funcs,
        instance_funcs = luaapi_drawable_instance_funcs,
    },
    .ELEMENT = {
        name = "Element",
        static_funcs = luaapi_element_static_funcs,
        instance_funcs = luaapi_element_instance_funcs,
    },
    .HITOBJECT = {
        name = "Hitobject",
        static_funcs = luaapi_hitobject_static_funcs,
        instance_funcs = luaapi_hitobject_instance_funcs,
    },
}

luaapi_global_funcs := []lua.L_Reg {
  { "load_file", lua_global_load_file },
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
    
    if lua.L_dofile(L, strings.clone_to_cstring(script_path)) != lua.OK {
        lua_log_error("Lua initialization error:")
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
        lua.L_newmetatable(L, class.name)
        lua.pushvalue(L, -1)
        lua.setfield(L, -2, "__index")
        lua.L_setfuncs(L, raw_data(class.instance_funcs), 0)
        
        // note(isak): sets up type methods like Class.new(...)
        lua.newtable(L)
        lua.L_setfuncs(L, raw_data(class.static_funcs), 0)
        lua.setglobal(L, class.name)
        
        lua.pop(L, 1)
    }   
}

// note(isak): pushes a handle and associates it with the given name
lua_create_object :: proc "c" (L: ^lua.State, handle: $T, name: cstring) {
    data := cast(^T)lua.newuserdata(L, size_of(T))
    data^ = handle
    lua.L_getmetatable(L, name)
    lua.setmetatable(L, -2)
}

//////////////////////////////////////////////////////
// note(isak): global beatmap communication API

/*
reminders while i learn this stuff:

LUA IS 1-INDEXED WHICH INCLUDES ARGUMENT COUNTERS LOL

C to lua:
    lua.pcall(L, num_push_arguments, num_return_values, error_handler_stack_index)
    (we can just check the return value for errors, and the default error handler pushes the error string)

lua to C:
    complicated, we can have 3 different forms:
    - globally registered functions
    - functions registered in a namespace of sorts
    - instance functions that operate on an object
        this is how we wanna register our API functions (can do method chaining)
    
    
*/ 

lua_beatmap_on_init :: proc() {
    L:= lua_beatmap.state
    lua.getglobal(L, "on_init")
    
    if (lua.isfunction(L, -1)) {
        
        if (lua.pcall(L, 0, 0, 0) != lua.OK) {
            lua_log_error()
        }
    } else {
        lua.pop(L, 1)
    }
}

lua_beatmap_on_update :: proc(time_ms: f64) {
    lua_register_instruction_count_hook()
    
    L:= lua_beatmap.state
    //if time_ms != lua_beatmap.last_rendered_timestamp_ms {
        lua.getglobal(L, "on_update")
    
        if (lua.isfunction(L, -1)) {
            lua.pushnumber(L, lua.Number(time_ms))
    
            if (lua.pcall(L, 1, 0, 0) != lua.OK) {
                lua_log_error()
            }
        } else {
            lua.pop(L, 1)
        }
        
        lua_beatmap.last_rendered_timestamp_ms = time_ms
    //}
}

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


//////////////////////////////////////////////////////
// note(isak): element object API

/*
shader: Pipeline_ID,
static_geometry: bool,
ssbo: u32,
index_count: u32,

tex: u32,
animations: []Animation,
*/

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

//////////////////////////////////////////////////////
// note(isak): drawable object API

@(private="file")
luaapi_drawable_static_funcs := []lua.L_Reg {
  { "new",           luaapi_drawable_new },
  { nil,             nil               },
}

@(private="file")
luaapi_drawable_instance_funcs := []lua.L_Reg {
  { "__gc", luaapi_drawable_gc },
  { "set_pos", luaapi_drawable_set_pos },
  { "set_size", luaapi_drawable_set_size },
  //{ "set_anchor", luaapi_drawable_set_anchor },
  //{ "set_color", luaapi_drawable_set_color },
  //{ "set_vel", luaapi_drawable_set_vel },
  //{ "set_accel", luaapi_drawable_set_accel },
  //{ "set_angle_vel", luaapi_drawable_set_angle_vel },
  //{ "set_start_time_ms", luaapi_drawable_set_start_time_ms },
  //{ "set_end_time_ms", luaapi_drawable_set_end_time_ms },
  { nil, nil },
}

/*
size: vec2,
angle_deg: f32,
anchor: Layout_Anchor,
color: Color,

vel: vec2,
accel: vec2,
angle_vel: f32,

start_time_ms, end_time_ms: f64,
*/

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
    
    handle := cast(^Drawable_Handle)lua.newuserdata(L, size_of(Drawable_Handle))
    handle^ = drawable_new_expiring(&game.beatmap.map_expiring_gfx, {
        element = element^,
        flags = {.ACTIVE},
        layer = window.renderer.current_layer,
        anchor = .TOP_LEFT,
        
        color = {255, 255, 255, 255},
        
        start_time_ms = game.beatmap.start_time_ms,
        end_time_ms = game.beatmap.length_ms
    })
    
    lua.L_getmetatable(L, lua_classes[.DRAWABLE].name)
    lua.setmetatable(L, -2)
    
    return 1
}

luaapi_drawable_set_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    x, y := lua_number(2), lua_number(3)
    
    e, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        e.pos = vec2{f32(x), f32(y)}
    }
    return lua_return_self()
}

luaapi_drawable_set_size :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^Drawable_Handle)lua.L_checkudata(L, 1, lua_classes[.DRAWABLE].name)
    w, h := lua_number(2), lua_number(3)
    
    e, found := slotmap.get(&game.beatmap.drawables, handle^)
    if found {
        e.size = vec2{f32(w), f32(h)}
    }
    return lua_return_self()
}

//////////////////////////////////////////////////////
// note(isak): hitobject object API

@(private="file")
luaapi_hitobject_static_funcs := []lua.L_Reg {
  { "get_at_ms", luaapi_hitobject_get_at_ms },
  { "range_ms", luaapi_hitobject_range_ms },
  { nil, nil },
}

@(private="file")
luaapi_hitobject_instance_funcs := []lua.L_Reg {
  { "__gc", luaapi_hitobject_gc },
  { "get_pos", luaapi_hitobject_get_pos },
  { "set_pos", luaapi_hitobject_set_pos },
  { nil, nil },
}

/*
size: vec2,
angle_deg: f32,
anchor: Layout_Anchor,
color: Color,

vel: vec2,
accel: vec2,
angle_vel: f32,

start_time_ms, end_time_ms: f64,
*/

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
        lua_create_object(L, hitobject_index, lua_classes[.HITOBJECT].name)
        result = 1
    } else {
        log.error("User error - no hitobject at ms:", at_ms)
    }
    return result
}

luaapi_hitobject_range_ms :: proc "c" (L: ^lua.State) -> (result: i32) {
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
        if hobj.start_time_ms < f64(from_ms) {
            continue
        }
        if f64(to_ms) < hobj.start_time_ms {
            break
        }
        lua_create_object(L, i, lua_classes[.HITOBJECT].name)
        
        lua.rawseti(L, -2, i32(i + 1))
    }
    return 1
}

luaapi_hitobject_get_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    
    if handle^ < len(game.beatmap.hit_objects) {
        hobj := &game.beatmap.hit_objects[handle^]
        lua.pushnumber(L, lua.Number(hobj.pos.x))
        lua.pushnumber(L, lua.Number(hobj.pos.y))
        result = lua_return_self() + 2
    }
    return result
}

luaapi_hitobject_set_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_beatmap.odin_context
    handle := cast(^int)lua.L_checkudata(L, 1, lua_classes[.HITOBJECT].name)
    x, y := lua_number(2), lua_number(3)
    
    if handle^ < len(game.beatmap.hit_objects) {
        hobj := &game.beatmap.hit_objects[handle^]
        hobj.script_pos_translation = {f32(x), f32(y)} - hobj.pos
        
        result = lua_return_self()
    }
    return result
}
