package notosu

import os "core:os/os2"
import "core:log"

import lua "vendor:lua/5.4"


lua_ctx: struct {
    state: ^lua.State
}

lua_init :: proc(script_path: string) {
    script, script_file_len, err := read_entire_file_to_cstring(script_path)
    if err != os.General_Error.None {
        log.errorf("loading lua script '{}' failed: {}", script_path, err)
        return
    }
    if script_file_len == 0 {
        log.errorf("loading lua script '{}' failed, empty file", script_path)
        return
    }
    
    state := lua.L_newstate()
    lua_ctx.state = state
    lua.open_base(state)
    lua.open_coroutine(state)
    lua.open_table(state)
    lua.open_string(state)
    lua.open_utf8(state)
    lua.open_math(state)
    lua.open_debug(state)
    lua.open_package(state)
    
    // note(isak): unsafe libraries. you want a map where every note you hit deletes a random file from your PC?
    // this is how you get that
    //lua.open_io(lua_ctx.state) 
    //lua.open_os(lua_ctx.state) 
    
    
    //lua.L_dostring(lua_ctx.state, script)
}

lua_cleanup :: proc() {
    if lua_ctx.state != nil {
        lua.close(lua_ctx.state)
    }
}
