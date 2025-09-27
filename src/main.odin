package notosu

import "core:fmt"

import lua "vendor:lua/5.4"


main :: proc() {
    L := lua.L_newstate(); // Create a new Lua state
    defer lua.close(L); // Clean up later
    
    lua.L_openlibs(L); // Load Lua standard libraries
    
    script : cstring = "print('Hello from Lua!')"
    lua.L_dostring(L, script)
}
