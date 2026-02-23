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

lua_ctx: struct {
    state: ^lua.State,
    odin_context: runtime.Context,
    
    last_rendered_timestamp_ms: f64,
}

Lua_Class_Type :: enum {
    ENTITY,
    ELEMENT,
}

Lua_Class :: struct {
    name: cstring,
    static_funcs: []lua.L_Reg,
    instance_funcs: []lua.L_Reg,
}

lua_classes: [Lua_Class_Type]Lua_Class = {
    .ENTITY = {
        name = "Entity",
        static_funcs = luaapi_entity_static_funcs,
        instance_funcs = luaapi_entity_instance_funcs,
    },
    .ELEMENT = {
        name = "Element",
        static_funcs = luaapi_element_static_funcs,
        instance_funcs = luaapi_element_instance_funcs,
    },
}

luaapi_global_funcs := []lua.L_Reg {
  { "load_file", lua_global_load_file },
}

//////////////////////////////////////////////////////
// note(isak): lua core

LUA_WATCHDOG_INSTRUCTION_COUNT :: 1_000_000


lua_init :: proc(script_path: string) {
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
    lua_ctx.state = state
    lua.open_base(state)
    lua.open_table(state)
    lua.open_string(state)
    lua.open_math(state)
    lua.open_debug(state)
    //lua.open_package(state) // don't need it
    
    // note(isak): unsafe libraries. you want a map where every note you hit deletes a random file from your PC?
    // this is how you get that
    //lua.open_io(lua_ctx.state) 
    //lua.open_os(lua_ctx.state) 
        
    lua_ctx.odin_context = context
    L:= lua_ctx.state
    
    lua_register_global_funcs(L)
    lua_register_classes(L)
    
    if lua.L_dofile(L, strings.clone_to_cstring(script_path)) != lua.OK {
        lua_log_error("Lua initialization error:")
    }
}

lua_cleanup :: proc() {
    if lua_ctx.state != nil {
        lua.close(lua_ctx.state)
    }
}

lua_reload :: proc(script_path: string) {
    lua_cleanup()
    lua_init(script_path)
}


lua_number :: proc "c" (at: i32) -> lua.Number { return lua.L_checknumber(lua_ctx.state, at) }
lua_string :: proc "c" (at: i32) -> string {
    len: uint
    ptr := transmute(^u8)lua.L_checklstring(lua_ctx.state, at, &len)
    return string(slice.from_ptr(ptr, int(len)))
}

lua_return_self :: proc "c" () -> i32 {
    lua.pushvalue(lua_ctx.state, 1)
    return 1
}


lua_log_error :: proc "c" (log_str: string = "Lua error:", location := #caller_location) {
    L:= lua_ctx.state
    context = lua_ctx.odin_context
    
    log.error(log_str, "\n", lua.tostring(L, -1), sep = "", location = location)
    lua.pop(L, 1)
}

lua_register_instruction_count_hook :: proc() {
    L:= lua_ctx.state
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
    L:= lua_ctx.state
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
    
    L:= lua_ctx.state
    if time_ms != lua_ctx.last_rendered_timestamp_ms {
        lua.getglobal(L, "on_update")
    
        if (lua.isfunction(L, -1)) {
            lua.pushnumber(L, lua.Number(time_ms))
    
            if (lua.pcall(L, 1, 0, 0) != lua.OK) {
                lua_log_error()
            }
        } else {
            lua.pop(L, 1)
        }
        
        lua_ctx.last_rendered_timestamp_ms = time_ms
    }
}

lua_global_load_file :: proc "c" (L: ^lua.State) -> i32 {
    context = lua_ctx.odin_context
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
    context = lua_ctx.odin_context
    log.info("GC triggered for entity: ")
    return result
}

luaapi_element_new :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_ctx.odin_context
    
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
    context = lua_ctx.odin_context
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
    context = lua_ctx.odin_context
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
// note(isak): entity object API

@(private="file")
luaapi_entity_static_funcs := []lua.L_Reg {
  { "new",           luaapi_entity_new },
  { nil,             nil               },
}

@(private="file")
luaapi_entity_instance_funcs := []lua.L_Reg {
  { "__gc", luaapi_entity_gc },
  { "set_pos", luaapi_entity_set_pos },
  { "set_size", luaapi_entity_set_size },
  //{ "set_anchor", luaapi_entity_set_anchor },
  //{ "set_color", luaapi_entity_set_color },
  //{ "set_vel", luaapi_entity_set_vel },
  //{ "set_accel", luaapi_entity_set_accel },
  //{ "set_angle_vel", luaapi_entity_set_angle_vel },
  //{ "set_start_time_ms", luaapi_entity_set_start_time_ms },
  //{ "set_end_time_ms", luaapi_entity_set_end_time_ms },
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

luaapi_entity_gc :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_ctx.odin_context
    handle := cast(^Entity_Handle)lua.L_checkudata(L, 1, lua_classes[.ENTITY].name)
    log.debug("GC triggered for entity:", handle.generation, handle.index)
    slotmap.remove(&game.beatmap.entities, handle^)
    return result
}

luaapi_entity_new :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_ctx.odin_context
    
    element := cast(^Element_ID)lua.L_checkudata(L, 1, lua_classes[.ELEMENT].name)
    // todo(isak) what happens when element isnt found
    
    handle := cast(^Entity_Handle)lua.newuserdata(L, size_of(Entity_Handle))
    handle^ = entity_new_expiring(&game.beatmap.map_expiring_gfx, {
        element = element^,
        flags = {.ACTIVE},
        layer = window.renderer.current_layer,
        anchor = .CENTER,
        
        color = {255, 255, 255, 255},
        
        start_time_ms = game.beatmap.start_time_ms,
        end_time_ms = game.beatmap.length_ms
    })
    
    lua.L_getmetatable(L, lua_classes[.ENTITY].name)
    lua.setmetatable(L, -2)
    
    return 1
}

luaapi_entity_set_pos :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_ctx.odin_context
    handle := cast(^Entity_Handle)lua.L_checkudata(L, 1, lua_classes[.ENTITY].name)
    x, y := lua_number(2), lua_number(3)
    
    e, found := slotmap.get(&game.beatmap.entities, handle^)
    if found {
        e.pos = vec2{f32(x), f32(y)}
    }
    return lua_return_self()
}

luaapi_entity_set_size :: proc "c" (L: ^lua.State) -> (result: i32) {
    context = lua_ctx.odin_context
    handle := cast(^Entity_Handle)lua.L_checkudata(L, 1, lua_classes[.ENTITY].name)
    w, h := lua_number(2), lua_number(3)
    
    e, found := slotmap.get(&game.beatmap.entities, handle^)
    if found {
        e.size = vec2{f32(w), f32(h)}
    }
    return lua_return_self()
}
