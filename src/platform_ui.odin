package inso

import imgui "dep:imgui"
import imgui_gl3 "dep:imgui/imgui_impl_opengl3"
import "core:fmt"
import sdl "vendor:sdl3"


imgui_init :: proc() {
    imgui.CHECKVERSION()
    imgui.CreateContext()
    io := imgui.GetIO()
    io.ConfigFlags += {.NavEnableKeyboard}
    io.ConfigWindowsMoveFromTitleBarOnly = true

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
    app.audio_device_dropdown = Imgui_Dropdown{
        label    = "Audio output",
        items    = &app.audio_device_names,
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

imgui_dropdown_draw :: proc(dropdown: ^Imgui_Dropdown) {
    dropdown.changed = false
    if len(dropdown.items^) == 0 do return
    dropdown.selected = clamp(dropdown.selected, 0, len(dropdown.items^) - 1)
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


audio_device_dropdown_rebuild :: proc() {
    clear(&app.audio_device_names)
    clear(&app.audio_device_row)

    default_label := cstring("Default")
    if len(audio.default_device_name) > 0 {
        default_label = fmt.caprintf("Default (%s)", audio.default_device_name)
    }
    append(&app.audio_device_names, default_label)

    seen: map[string]int
    defer delete(seen)

    for dev, i in audio.devices {
        app.audio_device_row[dev.index] = i + 1

        count := seen[dev.name] + 1
        seen[dev.name] = count
        label := fmt.caprintf("%s##%d", dev.name, i)
        if count > 1 {
            label = fmt.caprintf("%s (%d)##%d", dev.name, count, i)
        }
        append(&app.audio_device_names, label)
    }
}

audio_device_dropdown_apply :: proc() {
    if !app.audio_device_dropdown.changed do return

    target := DEVICE_DEFAULT
    name := "default"
    if app.audio_device_dropdown.selected > 0 {
        if len(audio.devices) == 0 do return
        row := app.audio_device_dropdown.selected - 1
        target = audio.devices[row].index
        name  = audio.devices[row].name
    }

    if audio_set_device(target) {
        game.user_config.audio_device = target
        audio_apply_config_volumes()
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
