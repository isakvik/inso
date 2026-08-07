package inso

import "base:runtime"
import "core:fmt"
import "core:log"
import os "core:os"
import "core:strconv"
import "core:strings"


Skin :: struct {
    path: string,
    element_paths: [Skin_Element_Type]string,
    elements: [Skin_Element_Type]Skin_Element,
    hitsounds: [Skin_Sample_Set][Skin_Hitsound_Type]Hitsound,
    combobreak: Sample,

    using ini_options: struct {
        slider_border: Color,
        slider_track_override: Color,
        slider_ball: Color,
        allow_slider_ball_tint: bool,

        cursor_expand: bool,
        cursor_rotate: bool,

        font_hit_circle_prefix: string,
        font_hit_circle_overlap: f32,

        combo_colors: [8]Color,
        num_combo_colors: int,
    },

    has_sliderend: bool,
    has_sliderstart: bool,
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
    HIT100K,
    HIT300K,
    HIT300G,

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
    CURSOR_TRAIL,
    SLIDER_START_CIRCLE,
    SLIDER_START_CIRCLE_OVERLAY,
    CURSOR_MIDDLE,
}

Skin_Element :: struct {
    texture: u32,
    is_high_resolution: bool,
    metrics: vec2,

    // note(isak): frame 0 lives in this element's own slot; frames 1..frame_count-1 are contiguous in
    // window.skin_frame_textures from frame_slot_base. frame_count == 1 means static. see skin_frame_texture.
    frame_slot_base: u32,
    frame_count: int,
    frame_metrics: []vec2, // note(isak): frames 1..; frame 0 uses metrics. see skin_frame_metrics
}

skin_element_animatable := #partial [Skin_Element_Type]bool {
    .FOLLOWPOINT = true,
    .SLIDER_BALL = true,
    .HIT0    = true,
    .HIT50   = true,
    .HIT100  = true,
    .HIT300  = true,
    .HIT100K = true,
    .HIT300K = true,
    .HIT300G = true,
}

skin_element_optional := #partial [Skin_Element_Type]bool {
    .SLIDER_END                  = true,
    .SLIDER_END_OVERLAY          = true,
    .SLIDER_START_CIRCLE         = true,
    .SLIDER_START_CIRCLE_OVERLAY = true,
    .CURSOR_MIDDLE               = true,
}

skin_element_names := [Skin_Element_Type]string {
    .CURSOR           = "cursor",
    .APPROACHCIRCLE   = "approachcircle",
    .HITCIRCLE        = "hitcircle",
    .HITCIRCLE_OVERLAY = "hitcircleoverlay",
    .LIGHTING         = "lighting",

    .HIT0    = "hit0",
    .HIT50   = "hit50",
    .HIT100  = "hit100",
    .HIT300  = "hit300",
    .HIT100K = "hit100k",
    .HIT300K = "hit300k",
    .HIT300G = "hit300g",

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
    .CURSOR_TRAIL         = "cursortrail",
    .SLIDER_START_CIRCLE         = "sliderstartcircle",
    .SLIDER_START_CIRCLE_OVERLAY = "sliderstartcircleoverlay",
    .CURSOR_MIDDLE        = "cursormiddle",
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
        if r.folder_path == skin_path {
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
        slider_track_override = 0,
        slider_ball = color_white,

        cursor_expand = true,
        cursor_rotate = true,
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
    if v, ok := get(sections, "Colours", "SliderBall"); ok {
        if c, parsed := parse_osu_color(v); parsed do skin.slider_ball = c
    }
    if v, ok := get(sections, "General", "AllowSliderBallTint"); ok {
        skin.allow_slider_ball_tint = v == "1"
    }
    if v, ok := get(sections, "General", "CursorExpand"); ok {
        skin.cursor_expand = v == "1"
    }
    if v, ok := get(sections, "General", "CursorRotate"); ok {
        skin.cursor_rotate = v == "1"
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

// note(isak): frame 0 reads the element's own metrics, mirroring how its texture lives in the
// element's own slot. out-of-range frames fall back to frame 0
skin_frame_metrics :: proc(skin_el: Skin_Element_Type, frame: int) -> vec2 {
    element := &game.active_skin.elements[skin_el]
    if frame <= 0 || frame - 1 >= len(element.frame_metrics) do return element.metrics
    return element.frame_metrics[frame - 1]
}

DEFAULT_SKIN_PATH :: "skins/_default/"

skin_load_elements :: proc(skin: ^Skin) {
    any_missing := false
    for element in Skin_Element_Type {
        skin.elements[element].frame_count = 1
        if !skin_load_element_textures(skin, element, skin.element_paths[element]) && !skin_element_optional[element] {
            any_missing = true
        }
    }

    // note(isak): stable resolves missing elements per-file from the default skin, so incomplete
    // skins still render. _default has its own skin.ini (digit prefix), hence the full path setup
    if any_missing && skin.path != DEFAULT_SKIN_PATH {
        os.change_directory(app.base_dir)
        os.change_directory(DEFAULT_SKIN_PATH)

        default_skin: Skin
        skin_handle_ini(&default_skin)
        default_paths := skin_load_element_paths(&default_skin, context.temp_allocator)

        for element in Skin_Element_Type {
            if skin_element_optional[element] do continue
            if window.skin_textures[element].tex_id != 0 do continue
            if !skin_load_element_textures(skin, element, default_paths[element]) {
                el_str, _ := fmt.enum_value_to_string(element)
                log.infof("skin '{}': no texture for {} in skin or _default", skin.path, el_str)
            }
        }

        os.change_directory(app.base_dir)
        os.change_directory(skin.path)
    }

    if skin.elements[.SLIDER_END].texture > 0 {
        skin.has_sliderend = true
    }
    if skin.elements[.SLIDER_START_CIRCLE].texture > 0 {
        skin.has_sliderstart = true
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

skin_load_element_textures :: proc(skin: ^Skin, element: Skin_Element_Type, stem: string) -> bool {
    tex_store := &window.skin_textures[element]

    is_high_res, ok: bool
    if skin_element_animatable[element] {
        // note(isak): animated frames take precedence over a plain static image
        is_high_res, ok = skin_try_load_texture(fmt.tprintf("%s-0", stem), tex_store)
        if !ok {
            is_high_res, ok = skin_try_load_texture(fmt.tprintf("%s0", stem), tex_store)
        }
    }
    if !ok {
        is_high_res, ok = skin_try_load_texture(stem, tex_store)
    }
    if !ok do return false

    skin.elements[element].texture = tex_store.tex_id
    skin.elements[element].is_high_resolution = is_high_res
    skin.elements[element].metrics = texture_display_metrics(tex_store, is_high_res)

    if skin_element_animatable[element] {
        skin_load_animation_frames(skin, element, stem)
    }
    return true
}

texture_display_metrics :: proc(tex: ^Texture, is_high_res: bool) -> vec2 {
    display_scale: f32 = is_high_res ? 0.5 : 1.0
    return {f32(tex.w) * display_scale, f32(tex.h) * display_scale}
}

skin_load_animation_frames :: proc(skin: ^Skin, element: Skin_Element_Type, stem: string) {
    frame_slot_base := u32(len(window.skin_frame_textures))
    frame_metrics := make([dynamic]vec2)

    for frame := 1; ; frame += 1 {
        tex: Texture
        is_high_res, ok := skin_try_load_texture(fmt.tprintf("%s-%d", stem, frame), &tex)
        if !ok {
            is_high_res, ok = skin_try_load_texture(fmt.tprintf("%s%d", stem, frame), &tex)
            if !ok do break
        }
        append(&window.skin_frame_textures, tex)
        append(&frame_metrics, texture_display_metrics(&tex, is_high_res))
    }

    // note(isak): include frame 0, which is stored in window.skin_elements
    frame_count := 1 + (int(len(window.skin_frame_textures)) - int(frame_slot_base))
    if frame_count > 1 {
        skin.elements[element].frame_slot_base = frame_slot_base
        skin.elements[element].frame_count = frame_count
        skin.elements[element].frame_metrics = frame_metrics[:]
    }
}

skin_effective_element :: proc(skin: ^Skin, el: Skin_Element_Type) -> Skin_Element_Type {
    #partial switch el {
    case .SLIDER_END:         if !skin.has_sliderend do return .HITCIRCLE
    case .SLIDER_END_OVERLAY: if !skin.has_sliderend do return .HITCIRCLE_OVERLAY
    }
    return el
}

skin_draws_sliderend_overlay :: proc(skin: ^Skin) -> bool {
    return !skin.has_sliderend || window.skin_textures[.SLIDER_END_OVERLAY].tex_id != 0
}

skin_try_load_sample :: proc(stem: string, dest: ^Sample) -> bool {
    for extension in supported_audio_extensions {
        // note(isak): path is persisted
        path := strings.concatenate({stem, extension}, context.allocator)
        if !os.exists(path) {
            continue
        }
        path_cstr := strings.clone_to_cstring(path, context.allocator)

        sample, ok := sample_load_file(path_cstr, alloc = context.allocator)
        if ok {
            dest^ = sample
            return true
        }
    }
    return false
}

skin_try_load_hitsound :: proc(skin: ^Skin, sample_set: Skin_Sample_Set, hitsound_type: Skin_Hitsound_Type) -> bool {
    stem := strings.concatenate({
        skin_sample_set_name[sample_set], "-",
        skin_hitsound_type_name[hitsound_type],
    }, context.temp_allocator)

    return skin_try_load_sample(stem, &skin.hitsounds[sample_set][hitsound_type])
}

skin_load_hitsounds :: proc(skin: ^Skin) {
    loaded: [Skin_Sample_Set][Skin_Hitsound_Type]bool
    any_missing := false
    for sample_set in Skin_Sample_Set {
        for hitsound_type in Skin_Hitsound_Type {
            loaded[sample_set][hitsound_type] = skin_try_load_hitsound(skin, sample_set, hitsound_type)
            if !loaded[sample_set][hitsound_type] do any_missing = true
        }
    }

    loaded_combobreak := skin_try_load_sample("combobreak", &skin.combobreak)
    if !loaded_combobreak do any_missing = true

    // note(isak): missing hitsounds resolve from the default skin, same as element textures.
    // a present-but-silent (empty) file counts as supplied - that's how skins mute a sound
    if any_missing && skin.path != DEFAULT_SKIN_PATH {
        os.change_directory(app.base_dir)
        os.change_directory(DEFAULT_SKIN_PATH)

        for sample_set in Skin_Sample_Set {
            for hitsound_type in Skin_Hitsound_Type {
                if loaded[sample_set][hitsound_type] do continue
                skin_try_load_hitsound(skin, sample_set, hitsound_type)
            }
        }
        if !loaded_combobreak do skin_try_load_sample("combobreak", &skin.combobreak)

        os.change_directory(app.base_dir)
        os.change_directory(skin.path)
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
    if skin.combobreak.handle != 0 {
        sample_destroy(&skin.combobreak)
    }

    for element in Skin_Element_Type {
        texture_cleanup(&window.skin_textures[element])
    }
    for &frame in window.skin_frame_textures {
        texture_cleanup(&frame)
    }

    window.skin_textures = {}
    free_all(memory.allocators[.SKIN])
}

skin_rebind_graphics :: proc() {
    if game.beatmap.elements.len < len(Element_Type) do return

    build_default_elements(&game.beatmap.elements, &game.beatmap.animations, &game.beatmap.animation_lists)
    mods_apply_to_graphics()
}

// todo(isak): @speed: should be able to free only skin textures
skin_set_active :: proc(skin_path: string) {
    cleanup_textures_for_rendering()
    skin_unload(game.active_skin)
    game.active_skin = skin_load(skin_path)
    prepare_textures_for_rendering()
}

skin_rebind :: proc(skin_path: string) {
    skin_set_active(skin_path)
    skin_rebind_graphics()
}

skin_clear_override :: proc() {
    if game.active_skin.path == game.user_config.skin_path do return
    skin_rebind(game.user_config.skin_path)
}

// note(isak): register every skin directory found in skins_dir. also uses temp_allocator
discover_skins :: proc(skins_dir: string, alloc: runtime.Allocator = context.allocator) {
    dir_handle, err := os.open(skins_dir)
    if err != nil {
        log.errorf("couldn't open '{}': {}", skins_dir, err)
        return
    }

    // note(isak): externally-opened skins don't live under skins_dir, so carry them across the
    // rebuild instead of dropping them (QOL)
    preserved_refs  := make([dynamic]Skin_Reference, context.temp_allocator)
    preserved_names := make([dynamic]cstring, context.temp_allocator)
    for ref, i in app.skin_references {
        if !ref.external do continue
        append(&preserved_refs, ref)
        append(&preserved_names, app.skin_reference_names[i])
    }

    clear(&app.skin_references)
    clear(&app.skin_reference_names)

    dirs, _ := os.read_dir(dir_handle, 256, context.temp_allocator)

    count := 0
    for dir in dirs {
        if dir.type != .Directory do continue

        folder_path  := strings.concatenate({skins_dir, dir.name, "/"}, alloc)
        display_cstr := fmt.caprintf("%s", dir.name)

        append(&app.skin_references, Skin_Reference{ folder_path = folder_path })
        append(&app.skin_reference_names, display_cstr)
        count += 1
    }
    for ref, i in preserved_refs {
        append(&app.skin_references, ref)
        append(&app.skin_reference_names, preserved_names[i])
    }

    // note(isak): the rebuild shuffles indices, so re-point the dropdown at the active skin
    app.skin_dropdown.selected = 0
    for ref, i in app.skin_references {
        if ref.folder_path == game.user_config.skin_path {
            app.skin_dropdown.selected = i
            break
        }
    }

    notify_info("discover_skins: found %v skins in '%s'", count, skins_dir)
}

skin_reference_find :: proc(folder_path: string) -> (index: int, found: bool) {
    for ref, i in app.skin_references {
        if ref.folder_path == folder_path do return i, true
    }
    return -1, false
}

// note(isak): matches the display name the skin dropdown shows, which is the skin's folder name
skin_reference_find_by_name :: proc(name: string) -> (index: int, found: bool) {
    for display_name, i in app.skin_reference_names {
        if strings.equal_fold(name, string(display_name)) do return i, true
    }
    return -1, false
}

// note(isak): folder_path must outlive the reference list (e.g. GLOBAL arena)
skin_reference_add_external :: proc(folder_path: string) {
    display_name := strings.trim_right(folder_path, "/\\")
    if idx := strings.last_index_any(display_name, "/\\"); idx >= 0 {
        display_name = display_name[idx + 1:]
    }

    append(&app.skin_references, Skin_Reference{ folder_path = folder_path, external = true })
    append(&app.skin_reference_names, fmt.caprintf("%s", display_name))
}
