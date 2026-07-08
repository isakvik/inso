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

        combo_colors: [8]Color,
        num_combo_colors: int,
    },

    has_sliderend: bool,
}

DEFAULT_SKIN_COMBO_COLORS := [4]Color {
    {255, 192, 0, 0xFF},
    {0, 202, 0, 0xFF},
    {18, 124, 255, 0xFF},
    {242, 24, 57, 0xFF},
}

supported_image_extensions :: []string{".png", ".jpg"}
supported_audio_extensions :: []string{".wav", ".ogg", ".mp3"}


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

    // note(isak): frame 0 lives in this element's own slot; frames 1..frame_count-1 are contiguous in
    // window.skin_frame_textures from frame_slot_base. frame_count == 1 means static. see skin_frame_texture.
    frame_slot_base: u32,
    frame_count: int,
}

skin_element_animatable := #partial [Skin_Element_Type]bool {
    .FOLLOWPOINT = true,
    .SLIDER_BALL = true,
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

Hitsound_Key :: struct {
    sample_set: Skin_Sample_Set,
    type:       Skin_Hitsound_Type,
    index:      u32,
}

// note(isak): parses "soft-hitclap2.wav" into {SOFT, HITCLAP, 2}; a bare "soft-hitclap.wav" is bank 1
hitsound_key_from_filename :: proc(filename: string) -> (key: Hitsound_Key, is_hitsound: bool) {
    stem := filename
    if dot := strings.last_index_byte(stem, '.'); dot >= 0 do stem = stem[:dot]

    dash := strings.index_byte(stem, '-')
    if dash < 0 do return {}, false

    set_matched := false
    for set_name, set in skin_sample_set_name {
        if stem[:dash] == set_name {
            key.sample_set = set
            set_matched = true
            break
        }
    }
    if !set_matched do return {}, false

    rest := stem[dash + 1:]
    for type_name, type in skin_hitsound_type_name {
        if !strings.has_prefix(rest, type_name) do continue
        key.type = type

        index_suffix := rest[len(type_name):]
        if index_suffix == "" {
            key.index = 1
            return key, true
        }
        index, index_ok := strconv.parse_uint(index_suffix, 10)
        if index_ok {
            key.index = u32(index)
            return key, true
        }
    }
    return {}, false
}

// note(isak): resolve_hitsound priority order - a .wav bank beats an .ogg of the same name
audio_extension_rank :: proc(filename: string) -> int {
    for extension, rank in supported_audio_extensions {
        if strings.has_suffix(filename, extension) do return rank
    }
    return len(supported_audio_extensions)
}

Hitsound :: Sample


skin_load :: proc(skin_path: string) -> (result: ^Skin) {
    context.allocator = memory.allocators[.SKIN]
    
    load_start := time_s_since_beginning_of_program()
    result = new(Skin)
    result.path, _ = strings.clone(skin_path)
    
    window.skin_frame_textures = make([dynamic]Texture, 0, 16)

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

    max_combo := 0

    if colours, has_colours := sections["Colours"]; has_colours {
        for key, val in colours {
            if len(key) >= 5 && strings.equal_fold(key[:5], "Combo") {
                suffix := key[5:]
                if suffix == "" do continue
                idx, ok := strconv.parse_int(suffix, 10)
                if !ok do continue
                if idx < 1 || idx > len(skin.ini_options.combo_colors) do continue

                if c, parsed := parse_osu_color(val); parsed {
                    skin.ini_options.combo_colors[idx - 1] = c
                    if idx > max_combo {
                        max_combo = idx
                    }
                }
            }
        }
        skin.ini_options.num_combo_colors = max_combo
    }
    if max_combo == 0 {
        for i in 0..<len(DEFAULT_SKIN_COMBO_COLORS) {
            skin.ini_options.combo_colors[i] = DEFAULT_SKIN_COMBO_COLORS[i]
        }
        skin.ini_options.num_combo_colors = 4
    }
}

skin_try_load_texture :: proc(stem: string, tex_store: ^Texture) -> (is_high_res: bool, ok: bool) {
    for extension in supported_image_extensions {
        tex, err := texture_from_file(strings.concatenate({stem, "@2x", extension}, context.temp_allocator))
        if err == os.General_Error.None {
            tex_store^ = tex
            return true, true
        }
        tex, err = texture_from_file(strings.concatenate({stem, extension}, context.temp_allocator))
        if err == os.General_Error.None {
            tex_store^ = tex
            return false, true
        }
    }
    return false, false
}

// note(isak): loads -1, -2, ... into the shared frame block until one is missing. frame 0 already lives
// in window.skin_elements, so frame_count is the total including it.
skin_load_animation_frames :: proc(skin: ^Skin, element: Skin_Element_Type) {
    stem := skin.element_paths[element]
    frame_slot_base := u32(len(window.skin_frame_textures))

    for frame := 1; ; frame += 1 {
        tex: Texture
        _, ok := skin_try_load_texture(fmt.tprintf("%s-%d", stem, frame), &tex)
        if !ok {
            _, ok = skin_try_load_texture(fmt.tprintf("%s%d", stem, frame), &tex)
            if !ok do break
        }
        append(&window.skin_frame_textures, tex)
    }

    frame_count := 1 + (int(len(window.skin_frame_textures)) - int(frame_slot_base))
    if frame_count > 1 {
        skin.elements[element].frame_slot_base = frame_slot_base
        skin.elements[element].frame_count = frame_count
    }
}

skin_load_elements :: proc(skin: ^Skin) {
    for element in Skin_Element_Type {
        tex_store := &window.skin_textures[element]
        skin.elements[element].frame_count = 1

        is_high_res, ok := skin_try_load_texture(skin.element_paths[element], tex_store)
        if !ok && skin_element_animatable[element] {
            // note(isak): handle first frame of animated elements
            is_high_res, ok = skin_try_load_texture(fmt.tprintf("%s-0", skin.element_paths[element]), tex_store)
        }
        if !ok {
            is_high_res, ok = skin_try_load_texture(fmt.tprintf("%s0", skin.element_paths[element]), tex_store)
        }

        // todo(isak): we handle as much as we handle here, but can supply a default skin like osu here
        if !ok {
            log.debugf("skin warning: no texture found for {}", fmt.enum_value_to_string(element))
        }

        skin.elements[element].texture = tex_store.tex_id
        skin.elements[element].is_high_resolution = is_high_res

        // note(isak): natural display size. @2x textures are double-resolution for the same visual size
        display_scale: f32 = is_high_res ? 0.5 : 1.0
        skin.elements[element].metrics = {f32(tex_store.w) * display_scale, f32(tex_store.h) * display_scale}

        if ok && skin_element_animatable[element] {
            skin_load_animation_frames(skin, element)
        }
    }

    if skin.elements[.SLIDER_END].texture > 0 {
        skin.has_sliderend = true
    }
    
    // note(isak): fallbacks. copies the metrics so they're read correctly by skin_render_element
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
    // todo(isak): quite destructive, but most sounds in the game should be skinnable
    game_sounds_clear()
    
    for &set in skin.hitsounds {
        for &hitsound in set {
            if hitsound.handle != 0 {
                sample_destroy(&hitsound)
            }
        }
    }

    for element in Skin_Element_Type {
        texture_cleanup(&window.skin_textures[element])
    }
    for &frame in window.skin_frame_textures {
        texture_cleanup(&frame)
    }

    window.skin_textures = {}
    virtual.arena_free_all(&memory.arenas[.SKIN])
}

skin_reload :: proc(skin: ^Skin) {
    temp_path := strings.clone(skin.path, context.temp_allocator)

    // note(isak): reload is called midframe, so we need to make all our handles nonresident to free GPU memory
    // todo(isak): @speed: should be able to free only skin textures
    cleanup_textures_for_rendering()

    skin_unload(skin)
    game.active_skin = skin_load(temp_path)
    prepare_textures_for_rendering()
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
