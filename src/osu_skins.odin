package notosu

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import os "core:os"
import "core:strings"


Skin :: struct {
    path: string,
    elements: [Skin_Element_Type]Skin_Element,
    hitsounds: [Skin_Sample_Set][Skin_Hitsound_Type]Hitsound,
}

supported_image_extensions :: []string{".png", ".jpg"}
supported_audio_extensions :: []string{".wav", ".ogg"}


// -- skin image elements

Skin_Element_Type :: enum u32 {
    CURSOR,
    APPROACHCIRCLE,
    HITCIRCLE,
    HITCIRCLEOVERLAY,
    LIGHTING,

    HIT0,
    HIT50,
    HIT100,
    HIT300,

    COMBO_0,
    COMBO_1,
    COMBO_2,
    COMBO_3,
    COMBO_4,
    COMBO_5,
    COMBO_6,
    COMBO_7,
    COMBO_8,
    COMBO_9,

    SLIDER_BALL,
    SLIDER_FOLLOW_CIRCLE,
    SLIDER_REPEAT,
    SLIDER_TICK,
    SLIDER_END,
    SLIDER_END_OVERLAY,
}

Skin_Element :: struct {
    texture: u32,
    is_high_resolution: bool,
    metrics: vec2,
}

Skin_Element_Path := [Skin_Element_Type]string {
    .CURSOR          = "cursor",
    .APPROACHCIRCLE  = "approachcircle",
    .HITCIRCLE       = "hitcircle",
    .HITCIRCLEOVERLAY = "hitcircleoverlay",
    .LIGHTING        = "lighting",

    .HIT0    = "hit0",
    .HIT50   = "hit50",
    .HIT100  = "hit100",
    .HIT300  = "hit300",

    .COMBO_0 = "default-0",
    .COMBO_1 = "default-1",
    .COMBO_2 = "default-2",
    .COMBO_3 = "default-3",
    .COMBO_4 = "default-4",
    .COMBO_5 = "default-5",
    .COMBO_6 = "default-6",
    .COMBO_7 = "default-7",
    .COMBO_8 = "default-8",
    .COMBO_9 = "default-9",

    .SLIDER_BALL = "sliderb0",
    .SLIDER_FOLLOW_CIRCLE = "sliderfollowcircle",
    .SLIDER_REPEAT = "reversearrow",
    .SLIDER_TICK = "sliderscorepoint",
    .SLIDER_END = "sliderendcircle",
    .SLIDER_END_OVERLAY = "sliderendcircleoverlay",
}

// -- skin hitsound elements

Skin_Sample_Set :: enum {
    NORMAL,
    SOFT,
    DRUM
}

Skin_Hitsound_Type :: enum u32 {
    HITNORMAL,
    HITWHISTLE,
    HITFINISH,
    HITCLAP,

    SLIDERSLIDE,
    SLIDERWHISTLE,
    SLIDERTICK,
}

skin_sample_set_name := [Skin_Sample_Set]string {
    .NORMAL = "normal",
    .SOFT   = "soft",
    .DRUM   = "drum",
}

skin_hitsound_type_name := [Skin_Hitsound_Type]string {
    .HITNORMAL   = "hitnormal",
    .HITWHISTLE  = "hitwhistle",
    .HITFINISH   = "hitfinish",
    .HITCLAP     = "hitclap",
    .SLIDERSLIDE = "sliderslide",
    .SLIDERWHISTLE = "sliderwhistle",
    .SLIDERTICK  = "slidertick",
}

Hitsound :: Sample


skin_load :: proc(skin_path: string) -> (result: ^Skin) {
    load_start := time_s_since_beginning_of_program()
    
    context.allocator = memory.allocators[.SKIN]
    result = new(Skin)
    result.path, _ = strings.clone(skin_path)

    os.change_directory(result.path)
    defer os.change_directory(app.base_dir)

    skin_load_elements(result)
    skin_load_hitsounds(result)
    
    notify_info("loaded skin '%s' in %.3vs", skin_path, time_s_since_beginning_of_program() - load_start)
    
    // --@temp waiting on menu mode ui
    for r, i in app.skin_references {
        if r == skin_path {
            window.skin_dropdown.selected = i
            break
        }
    }
    //--
    return result
}

skin_load_elements :: proc(skin: ^Skin) {
    for element in Skin_Element_Type {
        tex_store := &window.skin_textures[element]
        tex_err: os.Error

        for extension in supported_image_extensions {
            element_path := strings.concatenate({Skin_Element_Path[element], "@2x", extension})
            tex_store^, tex_err = texture_from_file(element_path)
            if tex_err == os.General_Error.None {
                skin.elements[element].is_high_resolution = true
                break
            }

            if tex_err == os.General_Error.Not_Exist {
                element_path = strings.concatenate({Skin_Element_Path[element], extension})
                tex_store^, tex_err = texture_from_file(element_path)
            }

            if tex_err == os.General_Error.None {
                skin.elements[element].texture = tex_store.tex_id
                break
            }
        }

        // todo(isak): we handle as much as we handle here, but can supply a default skin like osu here
        if tex_err != os.General_Error.None {
            log.debugf("skin warning: attempted searching for {}, but got error: {}", 
                fmt.enum_value_to_string(element), tex_err)
        }

        // note(isak): natural display size. @2x textures are double-resolution for the same visual size
        display_scale: f32 = skin.elements[element].is_high_resolution ? 0.5 : 1.0
        skin.elements[element].metrics = {f32(tex_store.w) * display_scale, f32(tex_store.h) * display_scale}
    }
    
    
    // note(isak): fallbacks
    for element in Skin_Element_Type {
        if skin.elements[element].texture == 0 {
            #partial switch element {
            case .SLIDER_END:         skin.elements[element] = skin.elements[.HITCIRCLE]
            case .SLIDER_END_OVERLAY: skin.elements[element] = skin.elements[.HITCIRCLEOVERLAY]
            }
        }
    }
}

skin_load_hitsounds :: proc(skin: ^Skin) {
    for sample_set in Skin_Sample_Set {
        for hitsound_type in Skin_Hitsound_Type {
            stem := strings.concatenate({
                skin_sample_set_name[sample_set], "-",
                skin_hitsound_type_name[hitsound_type],
            }, context.temp_allocator)

            for extension in supported_audio_extensions {
                // note(isak): path is persisted
                path := strings.concatenate({stem, extension}, context.allocator)
                if !os.exists(path) {
                    continue
                }
                
                sample, ok := sample_load_file(path)
                if ok {
                    skin.hitsounds[sample_set][hitsound_type] = sample
                    break
                }
            }
        }
    }
}

skin_unload :: proc(skin: ^Skin) {
    for &set in skin.hitsounds {
        for &hitsound in set {
            if hitsound.handle != 0 {
                sample_destroy(&hitsound)
            }
        }
    }

    texture_ids: [len(Skin_Element_Type)]u32
    for element in Skin_Element_Type {
        texture_ids[element] = window.skin_textures[element].tex_id
    }
    texture_free(texture_ids[:])

    virtual.arena_free_all(&memory.arenas[.SKIN])
}

skin_reload :: proc(skin: ^Skin) {
    temp_path := strings.clone(skin.path, context.temp_allocator)
    skin_unload(skin)
    skin_load(temp_path)
}

// note(isak): register every skin directory found in skins_dir
// allocates with given alloc + context.temp_allocator
discover_skins :: proc(skins_dir: string, alloc: runtime.Allocator = context.allocator) {
    dir_handle, err := os.open(skins_dir)
    if err != nil {
        log.errorf("couldn't open '{}': {}", skins_dir, err)
        return
    }

    clear(&app.skin_references)
    clear(&app.skin_reference_names)

    dirs, _ := os.read_dir(dir_handle, 256, context.temp_allocator)

    count := 0
    for dir in dirs {
        if dir.type != .Directory do continue

        folder_path  := strings.concatenate({skins_dir, dir.name, "/"}, alloc)
        display_cstr := fmt.caprintf("%s", dir.name)

        append(&app.skin_references, folder_path)
        append(&app.skin_reference_names, display_cstr)
        count += 1
    }
    notify_info("discover_skins: found %v skins in '%s'", count, skins_dir)
}
