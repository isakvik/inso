package notosu

import "core:fmt"

import lua "vendor:lua/5.4"
import sdl3 "vendor:sdl3"



main :: proc() {
    L := lua.L_newstate(); // Create a new Lua state
    defer lua.close(L); // Clean up later
    
    lua.L_openlibs(L); // Load Lua standard libraries
    
    script : cstring = "print('Hello from Lua!')"
    lua.L_dostring(L, script)

    if (!sdl3.Init(sdl3.INIT_VIDEO | sdl3.INIT_AUDIO)) {
        fmt.println("init error");
        return
    }

    event: sdl3.Event
    quit := false
    for (!quit) {
        for sdl3.PollEvent(&event) {
            if (event.type == sdl3.EventType.QUIT) {
                quit = true
                break
            }


        }
    }
}
