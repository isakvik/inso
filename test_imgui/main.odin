package test_imgui

import "core:fmt"

import gl  "vendor:OpenGL"
import sdl "vendor:sdl3"

import imgui     "../src/imgui"
import imgui_gl3 "../src/imgui/imgui_impl_opengl3"


main :: proc() {
    _ = sdl.Init({.VIDEO})
    defer sdl.Quit()

    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 4)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 6)

    win := sdl.CreateWindow("imgui test", 1280, 720, sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    defer sdl.DestroyWindow(win)

    gl_ctx := sdl.GL_CreateContext(win)
    defer sdl.GL_DestroyContext(gl_ctx)

    sdl.GL_MakeCurrent(win, gl_ctx)
    sdl.GL_SetSwapInterval(1)

    gl.load_up_to(4, 6, sdl.gl_set_proc_address)

    imgui.CHECKVERSION()
    ctx := imgui.CreateContext()
    defer imgui.DestroyContext(ctx)

    io := imgui.GetIO()
    io.ConfigFlags += {.NavEnableKeyboard}

    imgui_gl3.Init("#version 460")
    defer imgui_gl3.Shutdown()

    show_demo := true

    running := true
    for running {
        event: sdl.Event
        for sdl.PollEvent(&event) {
            #partial switch event.type {
            case .QUIT:
                running = false
            case .MOUSE_MOTION:
                imgui.IO_AddMousePosEvent(io, event.motion.x, event.motion.y)
            case .MOUSE_BUTTON_DOWN:
                imgui.IO_AddMouseButtonEvent(io, sdl_button_to_imgui(event.button.button), true)
            case .MOUSE_BUTTON_UP:
                imgui.IO_AddMouseButtonEvent(io, sdl_button_to_imgui(event.button.button), false)
            case .MOUSE_WHEEL:
                imgui.IO_AddMouseWheelEvent(io, event.wheel.x, event.wheel.y)
            case .TEXT_INPUT:
                imgui.IO_AddInputCharactersUTF8(io, event.text.text)
            case .KEY_DOWN:
                imgui.IO_AddKeyEvent(io, sdl_scancode_to_imgui(event.key.scancode), true)
            case .KEY_UP:
                imgui.IO_AddKeyEvent(io, sdl_scancode_to_imgui(event.key.scancode), false)
            }
        }

        w, h: i32
        sdl.GetWindowSize(win, &w, &h)
        io.DisplaySize = {f32(w), f32(h)}
        io.DeltaTime   = 1.0 / 60.0

        imgui_gl3.NewFrame()
        imgui.NewFrame()

        imgui.ShowDemoWindow(&show_demo)

        imgui.Render()

        gl.Viewport(0, 0, w, h)
        gl.ClearColor(0.1, 0.1, 0.1, 1.0)
        gl.Clear(gl.COLOR_BUFFER_BIT)

        imgui_gl3.RenderDrawData(imgui.GetDrawData())

        sdl.GL_SwapWindow(win)
    }

    fmt.println("done!")
}

sdl_button_to_imgui :: proc(button: u8) -> i32 {
    switch button {
    case sdl.BUTTON_LEFT:   return 0
    case sdl.BUTTON_RIGHT:  return 1
    case sdl.BUTTON_MIDDLE: return 2
    }
    return -1
}

// minimal scancode mapping - enough to navigate the demo window
sdl_scancode_to_imgui :: proc(sc: sdl.Scancode) -> imgui.Key {
    #partial switch sc {
    case .TAB:        return .Tab
    case .LEFT:       return .LeftArrow
    case .RIGHT:      return .RightArrow
    case .UP:         return .UpArrow
    case .DOWN:       return .DownArrow
    case .PAGEUP:     return .PageUp
    case .PAGEDOWN:   return .PageDown
    case .HOME:       return .Home
    case .END:        return .End
    case .INSERT:     return .Insert
    case .DELETE:     return .Delete
    case .BACKSPACE:  return .Backspace
    case .SPACE:      return .Space
    case .RETURN:     return .Enter
    case .ESCAPE:     return .Escape
    case .LCTRL:      return .LeftCtrl
    case .LSHIFT:     return .LeftShift
    case .LALT:       return .LeftAlt
    case .RCTRL:      return .RightCtrl
    case .RSHIFT:     return .RightShift
    case .RALT:       return .RightAlt
    }
    return .None
}
