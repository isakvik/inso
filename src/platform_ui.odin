package notosu

import imgui "imgui"
import imgui_gl3 "imgui/imgui_impl_opengl3"
import sdl "vendor:sdl3"


imgui_init :: proc() {
    imgui.CHECKVERSION()
    imgui.CreateContext()
    io := imgui.GetIO()
    io.ConfigFlags += {.NavEnableKeyboard}
    imgui.FontAtlas_AddFontFromFileTTF(io.Fonts, "data/Roboto-Regular.ttf", 14)
    imgui_gl3.Init("#version 460")
    ok := sdl.StartTextInput(window.handle)
    assert(ok)
    
    app.map_dropdown = Imgui_Dropdown{
        label    = "Map",
        items    = &app.map_reference_names,
        selected = 0,
    }
    app.skin_dropdown = Imgui_Dropdown{
        label    = "Skin",
        items    = &app.skin_reference_names,
        selected = 0,
    }
}

imgui_cleanup :: proc() {
    imgui_gl3.Shutdown()
    imgui.DestroyContext()
}


Imgui_Dropdown :: struct {
    label:    cstring,
    items:    ^[dynamic]cstring,
    selected: int,
    changed:  bool, // note(isak): set to true for one frame when selection changes
}

imgui_dropdown_update :: proc(dropdown: ^Imgui_Dropdown) {
    dropdown.changed = false
    if len(dropdown.items^) == 0 do return
    preview := dropdown.items^[dropdown.selected]
    if !imgui.BeginCombo(dropdown.label, preview) do return
    defer imgui.EndCombo()

    for item, i in dropdown.items^ {
        is_selected := i == dropdown.selected
        if imgui.Selectable(item, is_selected) && !is_selected {
            dropdown.selected = i
            dropdown.changed  = true
        }
        if is_selected do imgui.SetItemDefaultFocus()
    }
}


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
    case .A:          return .A
    case .C:          return .C
    case .V:          return .V
    case .X:          return .X
    case .Y:          return .Y
    case .Z:          return .Z
    }
    return .None
}
