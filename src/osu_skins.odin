package notosu

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import os "core:os"
import "core:strconv"
import "core:strings"


Skin :: struct {
    path: string,
    element_paths: [Skin_Element_Type]string,
    elements: [Skin_Element_Type]Skin_Element,
    hitsounds: [Skin_Sample_Set][Skin_Hitsound_Type]Hitsound,

    using ini_options: struct {
        slider_border: Color,
        slider_track_override: Color,
    
        font_hit_circle_prefix: string,
        font_hit_circle_overlap: f32,
    },

    has_sliderend: bool,
}

supported_image_extensions :: []string{".png", ".jpg"}
supported_audio_extensions :: []string{".wav", ".ogg"}


// -- skin image elements

Skin_Element_Type :: enum u32 {
    CURSOR,
    APPROACHCIRCLE,
    HITCIRCLE,
    HITCIRCLE_OVERLAY,
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

    FOLLOWPOINT,
}

Skin_Element :: struct {
    texture: u32,
    is_high_resolution: bool,
    metrics: vec2,
}

skin_element_names := [Skin_Element_Type]string {
    .CURSOR           = "cursor",
    .APPROACHCIRCLE   = "approachcircle",
    .HITCIRCLE        = "hitcircle",
    .HITCIRCLE_OVERLAY = "hitcircleoverlay",
    .LIGHTING         = "lighting",

    .HIT0   = "hit0",
    .HIT50  = "hit50",
    .HIT100 = "hit100",
    .HIT300 = "hit300",

    .COMBO_0 = "combo",
    .COMBO_1 = "combo",
    .COMBO_2 = "combo",
    .COMBO_3 = "combo",
    .COMBO_4 = "combo",
    .COMBO_5 = "combo",
    .COMBO_6 = "combo",
    .COMBO_7 = "combo",
    .COMBO_8 = "combo",
    .COMBO_9 = "combo",

    .SLIDER_BALL          = "sliderb",
    .SLIDER_FOLLOW_CIRCLE = "sliderfollowcircle",
    .SLIDER_REPEAT        = "reversearrow",
    .SLIDER_TICK          = "sliderscorepoint",
    .SLIDER_END           = "sliderendcircle",
    .SLIDER_END_OVERLAY   = "sliderendcircleoverlay",

    .FOLLOWPOINT          = "followpoint",
}

// note(isak): resolves a "skin:" texture expression suffix (e.g. "cursor", "sliderb") to its element
// by matching skin_element_names case-insensitively. "combo" maps to the first digit glyph.
skin_element_by_name :: proc(name: string) -> (result: Skin_Element_Type, found: bool) {
    for el_name, el in skin_element_names {
        if strings.equal_fold(name, el_name) {
            return el, true
        }
    }
    return {}, false
}

skin_load_element_paths :: proc(
    skin: ^Skin, alloc: runtime.Allocator = context.allocator
) -> (result: [Skin_Element_Type]string) {
    result = skin_element_names

    // note(isak): digits load from the skin's configurable prefix (skin.ini HitCirclePrefix), so they
    // override the "combo" handle with the actual per-digit file stems.
    digit_postfix := [10]string {"-0", "-1", "-2", "-3", "-4", "-5", "-6", "-7", "-8", "-9"}
    for digit in 0..<10 {
        type := .COMBO_0 + Skin_Element_Type(digit)
        result[type] = strings.concatenate({skin.font_hit_circle_prefix, digit_postfix[digit]}, alloc)
    }

    return result
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
    .HITNORMAL     = "hitnormal",
    .HITWHISTLE    = "hitwhistle",
    .HITFINISH     = "hitfinish",
    .HITCLAP       = "hitclap",
    .SLIDERSLIDE   = "sliderslide",
    .SLIDERWHISTLE = "sliderwhistle",
    .SLIDERTICK    = "slidertick",
}

Hitsound :: Sample


skin_load :: proc(skin_path: string) -> (result: ^Skin) {
    context.allocator = memory.allocators[.SKIN]
    
    load_start := time_s_since_beginning_of_program()
    result = new(Skin)
    result.path, _ = strings.clone(skin_path)

    os.change_directory(result.path)
    defer os.change_directory(app.base_dir)

    skin_handle_ini(result)
    result.element_paths = skin_load_element_paths(result)
    
    skin_load_elements(result)
    skin_load_hitsounds(result)
    
    notify_info("loaded skin '%s' in %.3vs", skin_path, time_s_since_beginning_of_program() - load_start)
    
    // --@temp waiting on menu mode ui
    for r, i in app.skin_references {
        if r == skin_path {
            app.skin_dropdown.selected = i
            break
        }
    }
    //--
    return result
}

skin_handle_ini :: proc(skin: ^Skin) {
    skin.ini_options = {
        font_hit_circle_prefix = "default",
        font_hit_circle_overlap = 3,

        slider_border = color_white,
        slider_track_override = 0
    }

    src, read_err := read_entire_file_to_string("skin.ini", context.temp_allocator)
    if read_err != nil {
        log.infof("skin '{}': no readable skin.ini ({}), using defaults", skin.path, read_err)
        return
    }

    sections := parse_osu_ini(src, context.temp_allocator)

    get :: proc(sections: map[string]map[string]string, section, key: string) -> (string, bool) {
        pairs, has_section := sections[section]
        if !has_section do return "", false
        v, has_key := pairs[key]
        return v, has_key && len(v) > 0
    }

    if v, ok := get(sections, "Fonts", "HitCirclePrefix"); ok {
        skin.font_hit_circle_prefix = strings.clone(v)
    }
    if v, ok := get(sections, "Fonts", "HitCircleOverlap"); ok {
        skin.font_hit_circle_overlap, _ = strconv.parse_f32(v)
    }
    if v, ok := get(sections, "Colours", "SliderBorder"); ok {
        if c, parsed := parse_osu_color(v); parsed do skin.slider_border = c
    }
    if v, ok := get(sections, "Colours", "SliderTrackOverride"); ok {
        if c, parsed := parse_osu_color(v); parsed do skin.slider_track_override = c
    }
}

skin_load_elements :: proc(skin: ^Skin) {
    for element in Skin_Element_Type {
        tex_store := &window.skin_textures[element]
        tex_err: os.Error

        for extension in supported_image_extensions {
            element_path := strings.concatenate({skin.element_paths[element], "@2x", extension})
            tex_store^, tex_err = texture_from_file(element_path)
            if tex_err == os.General_Error.None {
                skin.elements[element].is_high_resolution = true
                break
            }

            if tex_err == os.General_Error.Not_Exist {
                element_path = strings.concatenate({skin.element_paths[element], extension})
                tex_store^, tex_err = texture_from_file(element_path)
            }
            
            if tex_err == os.General_Error.Not_Exist {
                element_path = strings.concatenate({skin.element_paths[element], "0", extension})
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

    if skin.elements[.SLIDER_END].texture > 0 {
        skin.has_sliderend = true
    }
    
    // note(isak): fallbacks. copies the metadata (metrics) so anything reading the slider-end
    // element's size sees the hitcircle's. the texture itself is redirected separately at element
    // creation via skin_render_element - see the note there.
    for element in Skin_Element_Type {
        if window.skin_textures[element].tex_id == 0 {
            #partial switch element {
            case .SLIDER_END:
                skin.elements[element] = skin.elements[.HITCIRCLE]
            case .SLIDER_END_OVERLAY: 
                skin.elements[element] = skin.elements[.SLIDER_END if skin.has_sliderend else .HITCIRCLE_OVERLAY]
            }
        }
    }
}

// note(isak): resolves the skin slot an element should actually sample. we redirect to the fallback
// slot (rather than copying the texture into the slider-end slot) so the same bindless handle
// isn't duplicated across two slots - that would double-resident it and raise GL_INVALID_OPERATION.
skin_render_element :: proc(skin: ^Skin, el: Skin_Element_Type) -> Skin_Element_Type {
    if window.skin_textures[el].tex_id != 0 do return el
    #partial switch el {
    case .SLIDER_END:         return .HITCIRCLE
    case .SLIDER_END_OVERLAY: return .SLIDER_END if skin.has_sliderend else .HITCIRCLE_OVERLAY
    }
    return el
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
