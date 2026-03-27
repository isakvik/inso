package notosu

import "base:intrinsics"
import "base:runtime"

import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:sort"
import "core:strings"
import "core:strconv"

import "vendor:cgltf"
import sg "vendor:sokol/gfx"

/*
mapset definition:
- .osu (core, lets you interface with existing editors)
- .notosu (additional interface, lua scripting capabilities)
- .lua files (for import utilities)
- .glsl (shaders, either merged glsl or .vs.glsl/.fs.glsl)

todo(isak): missing functionality:
    - mapset index; should enable quick lookup for song select stuff

    - notosu definition and script running

*/
Mapset_Buffer :: distinct GL_Buffer(u8)

Mapset :: struct {
    open: bool,
    folder_path:  string,
    osu_filename: string, // note(isak): which .osu file was loaded
    osu_map: Osu_Map,
    notosu_map: Notosu_Map,

    num_shaders: int,
    shader_blend_modes: [dynamic]Blend_Mode,
    textures: queue.Queue(Texture),
    texture_slot_by_name:  map[string]u32,
    pipeline_slot_by_name: map[string]u32,
    buffer_slot_by_name:   map[string]u32,
    hitobject_index_by_ms: map[int]int,

    buffers: queue.Queue(Mapset_Buffer),
    samples: queue.Queue(Sample),
    sample_slot_by_name: map[string]u32,

    watch: Win32_Directory_Watch
}


mapset_sample :: proc(name: string) -> (result: ^Sample, found: bool) {
    assert(game.active_mapset != nil)
    index: u32
    index, found = game.active_mapset.sample_slot_by_name[name]
    if found do result = queue.get_ptr(&game.active_mapset.samples, index)
    return result, found
}

mapset_texture :: proc(name: string) -> (result: ^Texture, found: bool) {
    assert(game.active_mapset != nil)
    index: u32
    index, found = game.active_mapset.texture_slot_by_name[name]
    if found do result = queue.get_ptr(&game.active_mapset.textures, index)
    else do result = &game.active_mapset.textures.data[0]
    return result, found
}

mapset_texture_slot :: proc(name: string) -> (result: u32, found: bool) {
    assert(game.active_mapset != nil)
    index: u32
    index, found = game.active_mapset.texture_slot_by_name[name]
    if found do result = user_texture(index)
    return result, found
}
mapset_texture_slot_or_else :: proc(name: string, default: u32) -> u32 {
    return mapset_texture_slot(name) or_else default
}

mapset_pipeline_slot :: proc(name: string) -> (result: u32, found: bool) {
    assert(game.active_mapset != nil)
    index: u32
    index, found = game.active_mapset.pipeline_slot_by_name[name]
    if found do result = user_pipeline_slot(index)
    return result, found
}
mapset_pipeline_slot_or_else :: proc(name: string, default: u32) -> u32 {
    return mapset_pipeline_slot(name) or_else default
}

mapset_buffer :: proc(name: string) -> (result: ^Mapset_Buffer, found: bool) {
    assert(game.active_mapset != nil)
    index: u32
    index, found = game.active_mapset.buffer_slot_by_name[name]
    if found do result = queue.get_ptr(&game.active_mapset.buffers, index)
    return result, found
}


Notosu_Map_System :: enum {
    OSU_FILE,
    NOTOSU_FILE,
    SCRIPTS,
    SHADERS,
    ASSETS,
}

Notosu_Section_Header_Types :: enum {
    HEADER,
    GENERAL,
    SHADERS,
    BUFFERS,
}

notosu_section_headers := []string{
    "",
    "[General]",
    "[Shaders]",
    "[Buffers]",
}

Osu_Section_Header_Types :: enum {
    HEADER,
    GENERAL,
    EDITOR,
    METADATA,
    DIFFICULTY,
    EVENTS,
    TIMINGPOINTS,
    COLOURS,
    HITOBJECTS
}

osu_section_headers := []string{
    "",
    "[General]",
    "[Editor]",
    "[Metadata]",
    "[Difficulty]",
    "[Events]",
    "[TimingPoints]",
    "[Colours]",
    "[HitObjects]",
}

Osu_Map_Sample_Set :: enum {
    NORMAL,
    SOFT,
    DRUM
}


mapset_free :: proc(mapset: ^Mapset) -> string {
    win32_close_directory_watch(&mapset.watch)

    for &texture in mapset.textures.data {
        texture_cleanup(&texture)
    }
    for i in len(Builtin_Pipeline_Slot)..<window.pipelines.len {
        sg.destroy_pipeline(window.pipelines.data[i])
        shader_delete(&window.shaders.data[i])
    }
    window.pipelines.len = len(Builtin_Pipeline_Slot)
    window.shaders.len = len(Builtin_Pipeline_Slot)
    buffer_clear(&window.renderer.slider_instances)

    for &buf in mapset.buffers.data {
        sbo_cleanup(cast(^GL_Buffer(u8))&buf)
    }
    for &sample in mapset.samples.data {
        sample_destroy(&sample)
    }

    mapset_path := strings.clone(mapset.folder_path, context.temp_allocator)

    virtual.arena_free_all(&memory.arenas[.DRAWABLES])
    virtual.arena_free_all(&memory.arenas[.MAPSET])

    return mapset_path
}

mapset_free_and_reload :: proc(mapset: ^Mapset) -> ^Mapset {
    mapset_path := mapset_free(mapset)
    reloaded_mapset, ok := mapset_open_for_editing(mapset_path)
    assert(ok)
    return reloaded_mapset
}

mapset_open_for_editing :: proc(path: string, osu_filename: string = "") -> (^Mapset, bool) {
    context.allocator = memory.allocators[.MAPSET]

    mapset_path := strings.clone(path, context.allocator)
    mapset, alloc_err := new(Mapset)
    assert(alloc_err == .None)

    if !os.exists(path) {
        return mapset, false
    }

    mapset.folder_path  = mapset_path
    mapset.osu_filename = strings.clone(osu_filename, context.allocator)
    

    // note(isak): file contents cannot exit this function, don't leave strings allocated here
    defer mem.free_all(context.temp_allocator)
    defer os.change_directory(app.base_dir)
    
    queue.init(&mapset.textures)
    queue.init(&mapset.buffers)
    queue.init(&mapset.samples)
    mapset.texture_slot_by_name  = make(map[string]u32, 16)
    mapset.pipeline_slot_by_name = make(map[string]u32, 16)
    mapset.buffer_slot_by_name   = make(map[string]u32, 16)
    mapset.sample_slot_by_name   = make(map[string]u32, 16)
    mapset.hitobject_index_by_ms = make(map[int]int, 128)
    mapset.shader_blend_modes    = make([dynamic]Blend_Mode, 0, 8)
    
    mapset_walk_directory(mapset, path)

    mapset.watch = win32_init_directory_watch(path)
    log.info("initialized directory watch for path:", path)
    
    return mapset, true
}

// note(isak): register every .osu file found in mapset subdirectories
// allocates with given alloc + context.temp_allocator
discover_maps :: proc(songs_dir: string, alloc: runtime.Allocator = context.allocator) {
    dir_handle, err := os.open(songs_dir)
    if err != nil {
        log.errorf("discover_maps: couldn't open '{}': {}", songs_dir, err)
        return
    }
    
    clear(&app.map_references)
    clear(&app.map_reference_names)
    
    dirs, _ := os.read_dir(dir_handle, 1024, context.temp_allocator)

    count := 0
    for dir in dirs {
        if dir.type != .Directory do continue

        folder_path := strings.concatenate({songs_dir, dir.name, "/"}, alloc)

        sub_handle, sub_err := os.open(folder_path)
        if sub_err != nil do continue
        sub_files, _ := os.read_dir(sub_handle, 256, context.temp_allocator)

        for sub_file in sub_files {
            if filepath.ext(sub_file.name) != ".osu" do continue

            osu_filename  := strings.clone(sub_file.name, alloc)
            stem          := filepath.stem(sub_file.name)
            display_cstr  := fmt.caprintf("%s / %s", dir.name, stem)

            append(&app.map_references, Map_Reference{
                folder_path  = folder_path,
                osu_filename = osu_filename,
            })
            append(&app.map_reference_names, display_cstr)
            count += 1
        }
    }
    log.infof("discover_maps: found {} maps in '{}'", count, songs_dir)
}

mapset_walk_directory :: proc(mapset: ^Mapset, path: string) {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    defer os.change_directory(cwd)
    
    files: []os.File_Info
    dir_handle, io_err := os.open(path)
    files, io_err = os.read_dir(dir_handle, 1024, context.temp_allocator)
    
    os.change_directory(path)

    for file in files {
        if file.type == .Directory {
            mapset_walk_directory(mapset, file.name)
        } else {
            mapset_handle_file(mapset, file)
        }
    }
}

mapset_handle_file :: proc(mapset: ^Mapset, file: os.File_Info) {
    extension := filepath.ext(file.name)
    switch extension {
        case ".notosu": {
            filedata, file_err := read_entire_file_to_string(file.name, context.temp_allocator)
            mapset.notosu_map = mapset_parse_notosu(mapset, filedata)
        }
        case ".osu": {
            if mapset.osu_filename != "" && file.name != mapset.osu_filename do break
            filedata, file_err := read_entire_file_to_string(file.name, context.temp_allocator)
            mapset.osu_map = mapset_parse_osu(mapset, filedata)
        }
        case ".png", ".jpg": {
            tex_key := strings.clone(file.name, memory.allocators[.MAPSET])
            tex, file_err := texture_from_file(file.name)
            mapset.texture_slot_by_name[tex_key] = u32(mapset.textures.len)
            queue.push_back(&mapset.textures, tex)
        }
        case ".wav", ".ogg": {
            sample, ok := sample_load_file(file.name)
            if ok {
                sample_key := strings.clone(file.name, memory.allocators[.MAPSET])
                mapset.sample_slot_by_name[sample_key] = u32(mapset.samples.len)
                sample.filepath = sample_key
                queue.push_back(&mapset.samples, sample)
            }
        }
    }
}

mapset_parse_notosu :: proc(mapset: ^Mapset, notosu_file: string) -> Notosu_Map {
    result: Notosu_Map
    context.allocator = memory.allocators[.MAPSET]

    c: Consumer = { str = notosu_file }
    
    section_index := 0
    section_loop: for {
        if c.at >= len(c.str) {
            break
        }
        
        lines := consume_section(&c)
        defer section_index += 1
        
        if len(lines) == 0 {
            fmt.println(notosu_section_headers[section_index], ":: section was blank")
            continue
        }
        
        if section_index == 0 {
            fmt.println("::", lines[0])
            continue
        }
        
        expected_happy_case := section_index
        for lines[0] != notosu_section_headers[section_index] {
            section_index = (section_index + 1) % int(max(Notosu_Section_Header_Types))
            if section_index == expected_happy_case {
                fmt.println(notosu_section_headers[expected_happy_case], ":: unhandled section")
                continue section_loop
            }
        }
        
        #partial switch Notosu_Section_Header_Types(section_index) {
        case .GENERAL:
            for i in 1..<len(lines) {
                key, value := get_key_value(lines[i])
                switch key {
                    case "LuaEntryPoint":
                        result.lua_entry_point = strings.concatenate({mapset.folder_path, value}, context.allocator)
                    case "BackgroundPipeline":
                        result.bg_pipeline_name = strings.clone(value, context.allocator)
                }
            }
        case .SHADERS:
            resolve_vs :: proc(value: string) -> string {
                switch value {
                case "builtin.quad":   return strings.concatenate({app.base_dir, "/", quad_vs_path})
                case "builtin.slider": return strings.concatenate({app.base_dir, "/", slider_vs_path})
                case "builtin.text":   return strings.concatenate({app.base_dir, "/", text_vs_path})
                case: return value
                }
            }
            resolve_fs :: proc(value: string) -> string {
                switch value {
                case "builtin.quad":   return strings.concatenate({app.base_dir, "/", quad_fs_path})
                case "builtin.slider": return strings.concatenate({app.base_dir, "/", slider_fs_path})
                case "builtin.text":   return strings.concatenate({app.base_dir, "/", text_fs_path})
                case: return value
                }
            }
            
            shader_params: struct {
                name: string,
                vs_path, fs_path: string,
                blend_mode: Blend_Mode,
            }

            for i in 1..<len(lines) {
                line := lines[i]
                if line[0:2] == "[[" && line[len(line)-2:] == "]]" {
                    mapset_load_shader_entry(mapset, shader_params.name, shader_params.vs_path, shader_params.fs_path, shader_params.blend_mode)
                    shader_params.name = line[2:len(line)-2]
                } else {
                    key, value := get_key_value(line)
                    switch key {
                    case "VertexShader":   shader_params.vs_path = resolve_vs(value)
                    case "FragmentShader": shader_params.fs_path = resolve_fs(value)
                    case "BlendMode":
                        switch value {
                        case "Alpha":    shader_params.blend_mode = .ALPHA
                        case "Additive": shader_params.blend_mode = .ADDITIVE
                        case "None":     shader_params.blend_mode = .NONE
                        case: log.errorf("mapset shader '{}': unknown BlendMode '{}', defaulting to alpha", shader_params.name, value)
                        }
                    case: log.errorf("unknown/unhandled option: {}", key)
                    }
                }
            }
            mapset_load_shader_entry(mapset, shader_params.name, shader_params.vs_path, shader_params.fs_path, shader_params.blend_mode)

        case .BUFFERS:
            buf_params: struct {
                name:     string,
                source:   string,
                size:     int,
            }

            for i in 1..<len(lines) {
                line := lines[i]
                if line[0:2] == "[[" && line[len(line)-2:] == "]]" {
                    mapset_load_buffer_entry(mapset, buf_params.name, buf_params.source, buf_params.size)
                    buf_params = {}
                    buf_params.name = line[2:len(line)-2]
                } else {
                    key, value := get_key_value(line)
                    switch key {
                    case "Source":
                        buf_params.source = value
                    case "Size":
                        parsed, ok := strconv.parse_int(value)
                        if ok do buf_params.size = parsed
                        else do log.errorf("mapset buffer '{}': invalid Size value '{}'", buf_params.name, value)
                    case: log.errorf("mapset buffer '{}': unknown option '{}'", buf_params.name, key)
                    }
                }
            }
            mapset_load_buffer_entry(mapset, buf_params.name, buf_params.source, buf_params.size)

        case:
            unreachable()
        }
    }

    return result
}

mapset_reinit_custom_shaders :: proc(mapset: ^Mapset) {
    os.change_directory(mapset.folder_path)
    defer os.change_directory(app.base_dir)
    
    base := len(Builtin_Pipeline_Slot)
    for i in base..<base + mapset.num_shaders {
        err := shader_reinit(&window.shaders.data[i])
        if err != .NONE do continue
        
        blend_mode := mapset.shader_blend_modes[i - base]
        desc := quad_pipeline_desc()
        desc.shader = window.shaders.data[i].shader
        desc.colors[0].blend = blend_state_for_mode(blend_mode)
        pipeline_reinit(&window.pipelines.data[i], desc)
    }
    log.info("reloaded mapset custom shaders")
}


mapset_parse_osu :: proc(mapset: ^Mapset, osu_file: string) -> Osu_Map {
    result: Osu_Map
    context.allocator = memory.allocators[.MAPSET]
    
    c: Consumer = { str = osu_file }
    
    section_index := 0
    section_loop: for {
        if c.at >= len(c.str) {
            break
        }

        lines := consume_section(&c)
        defer section_index += 1

        if len(lines) == 0 {
            fmt.println(osu_section_headers[section_index], ":: section was blank")
            continue
        }
        
        if section_index == 0 {
            fmt.println("::", lines[0])
            continue
        }

        expected_happy_case := section_index
        for lines[0] != osu_section_headers[section_index] {
            section_index = (section_index + 1) % (int(max(Osu_Section_Header_Types)) + 1)
            if section_index == expected_happy_case {
                fmt.println(osu_section_headers[expected_happy_case], ":: unhandled section")
                continue section_loop
            }
        }

        #partial switch Osu_Section_Header_Types(section_index) {
            case .GENERAL:
                for i in 1..<len(lines) {
                    key, value := get_key_value(lines[i])
                    ok: bool
                    switch key {
                        case "AudioFilename": 
                            result.audio_filename = strings.clone(value)
                            result.audio_filepath = strings.concatenate({mapset.folder_path, value})
                        case "AudioLeadIn": result.audio_lead_in, ok = strconv.parse_f64(value); assert(ok)
                        case "PreviewTime": result.preview_time_ms, ok = strconv.parse_f64(value); assert(ok)
                        case "SampleSet": 
                            switch value {
                                case "Normal": result.sample_set = .NORMAL
                                case "Soft":   result.sample_set = .SOFT
                                case "Drum":   result.sample_set = .DRUM
                                case "None":   result.sample_set = .NORMAL
                                case: assert(false, "unknown/unhandled sampleset")
                            }
                    }
                }
            case .METADATA:
                for i in 1..<len(lines) {
                    key, value := get_key_value(lines[i])
                    switch key {
                        case "Title":         result.title           = strings.clone(value)
                        case "TitleUnicode":  result.title_unicode   = strings.clone(value)
                        case "Artist":        result.artist          = strings.clone(value)
                        case "ArtistUnicode": result.artist_unicode  = strings.clone(value)
                        case "Creator":       result.creator         = strings.clone(value)
                        case "Version":       result.difficulty_name = strings.clone(value)
                    }
                }
            case .DIFFICULTY: 
                for i in 1..<len(lines) {
                    key, value := get_key_value(lines[i])
                    ok: bool
                    switch key {
                        case "HPDrainRate": result.diff_hp_drain, ok = strconv.parse_f64(value); assert(ok)
                        case "CircleSize": result.diff_circle_size, ok = strconv.parse_f64(value); assert(ok)
                        case "OverallDifficulty": result.diff_overall_difficulty, ok = strconv.parse_f64(value); assert(ok)
                        case "ApproachRate": result.diff_approach_rate, ok = strconv.parse_f64(value); assert(ok)
                        case "SliderMultiplier": result.diff_slider_velocity, ok = strconv.parse_f64(value); assert(ok)
                        case "SliderTickRate": result.diff_slider_tickrate, ok = strconv.parse_f64(value); assert(ok)
                    }
                }
            case .TIMINGPOINTS:
                result.timing_points = make_slice([]Timing_Point, len(lines) - 1)
                
                for i in 1..<len(lines) {
                    timing_point := &result.timing_points[i - 1]     
                    
                    from_i, s_len: int
                    arg_i: int
                    for from_i < len(lines[i]) && 0 <= s_len {
                        defer arg_i += 1
                        defer from_i += s_len + 1
                        s_len = strings.index_byte(lines[i][from_i:], ',')
                        value := s_len >= 0 ? lines[i][from_i:from_i + s_len] : lines[i][from_i:]
                                       
                        ok: bool
                        switch arg_i {
                            case 0: timing_point.time, ok = strconv.parse_f64(value); assert(ok)
                            case 1: timing_point.beat_length, ok = strconv.parse_f64(value); assert(ok)
                            case 2: meter, ok := strconv.parse_u64(value); assert(ok); 
                                timing_point.meter = u8(meter)
                            case 3: sample_set, ok := strconv.parse_u64(value); assert(ok)
                                switch sample_set {
                                    case 0: result.sample_set = .NORMAL
                                    case 1: result.sample_set = .SOFT
                                    case 2: result.sample_set = .DRUM
                                    case 3: result.sample_set = .NORMAL
                                }
                            case 4: // sample index
                            case 5: timing_point.volume, ok = strconv.parse_f64(value); assert(ok)
                            case 6: timing_point.type = value == "1" ? .UNINHERITED : .INHERITED
                            case 7: effects, ok := strconv.parse_int(value); assert(ok)
                                timing_point.kiai = effects & 1 == 1
                        }
                    }
                }
            
            case .EVENTS:
                for i in 1..<len(lines) {
                    if lines[i] == "//Background and Video events" {
                        path_from := strings.index_byte(lines[i+1], '"')
                        path_to := strings.last_index_byte(lines[i+1], '"')

                        if path_from == -1 || path_to == -1 {
                            continue
                        }
                        result.bg_filename = strings.clone(lines[i+1][path_from+1:path_to])
                    }
                }
            case .COLOURS:
                for i in 1..<len(lines) {
                    key, value := get_key_value(lines[i])
                    if !strings.has_prefix(key, "Combo") { continue }
                    combo_index, ok := strconv.parse_int(key[5:])
                    if !ok || combo_index < 1 || combo_index > 8 { continue }

                    c: Color = {0, 0, 0, 0xFF}
                    channel := 0
                    from_i, s_len: int
                    for from_i < len(value) && channel < 3 {
                        s_len = strings.index_byte(value[from_i:], ',')
                        part := s_len >= 0 ? value[from_i:from_i + s_len] : value[from_i:]
                        v, _ := strconv.parse_uint(strings.trim_space(part))
                        c[channel] = u8(v)
                        channel += 1
                        if s_len < 0 { break }
                        from_i += s_len + 1
                    }

                    result.combo_colors[combo_index - 1] = c
                    result.num_combo_colors = max(result.num_combo_colors, combo_index)
                }
            case .HITOBJECTS:
                result.hitobjects = make_slice([]Hitobject, len(lines) - 1)

                slider_temp_queue: queue.Queue(Slider_Path)
                queue.init(&slider_temp_queue, 1024, context.temp_allocator)
                
                for i in 1..<len(lines) {
                    hobj := &result.hitobjects[i - 1]
                    hobj_extra_params: string

                    // note(isak): parse base params - every hobj type has a differing set of params after these
                    from_i, s_len: int
                    arg_i: int
                    for from_i < len(lines[i]) && 0 <= s_len {
                        defer arg_i += 1
                        defer from_i += s_len + 1
                        s_len = strings.index_byte(lines[i][from_i:], ',')
                        value := s_len >= 0 ? lines[i][from_i:from_i + s_len] : lines[i][from_i:]

                        switch arg_i {
                            case 0: hobj.pos.x, _ = strconv.parse_f32(value)
                            case 1: hobj.pos.y, _ = strconv.parse_f32(value)
                            case 2: hobj.start_time_ms, _ = strconv.parse_f64(value)
                            case 3: 
                                type_flags, _ := strconv.parse_int(value)

                                is_circle    := type_flags & (1 << 0)
                                is_slider    := type_flags & (1 << 1)
                                is_nc        := type_flags & (1 << 2)
                                is_spinner   := type_flags & (1 << 3)

                                if is_circle > 0 {
                                    hobj.type = .CIRCLE
                                }
                                else if is_slider > 0 {
                                    hobj.type = .SLIDER
                                }
                                else if is_spinner > 0 {
                                    hobj.type = .SPINNER
                                }

                                if is_nc > 0 { hobj.flags |= {.NEW_COMBO} }
                                hobj.combo_color_skip_offset = u8((type_flags >> 4) & 0b111)
                            case 4:
                                hitsound, _ := strconv.parse_int(value)
                                hobj.hitsound_flags = byte(hitsound)
                                if hitsound & 2 != 0 { hobj.flags |= {.WHISTLE} }
                                if hitsound & 4 != 0 { hobj.flags |= {.FINISH}  }
                                if hitsound & 8 != 0 { hobj.flags |= {.CLAP}    }
                            case 5:
                                hobj_extra_params = lines[i][from_i:]
                                break
                        }
                    }

                    #partial switch hobj.type {
                    case .SPINNER:
                        ok: bool
                        hitsound_params_at := strings.index_byte(hobj_extra_params, ',')
                        hobj.end_time_ms, ok = strconv.parse_f64(hobj_extra_params[:hitsound_params_at]); assert(ok)
                    case .SLIDER:
                        slider: Slider_Path = {
                            bounds_min = {math.F32_MAX, math.F32_MAX},
                            bounds_max = {math.F32_MIN, math.F32_MIN},
                        }
                        mapset_parse_osu_slider_params(hobj, &slider, hobj_extra_params)
                        slider.instance_count, slider.first_instance_at = 
                            write_instances_from_path(&window.renderer.slider_instances, &slider)
                                                      
                        hobj.slider_path_index = int(slider_temp_queue.len)
                        queue.append(&slider_temp_queue, slider)
                    case:
                        hobj.end_time_ms = hobj.start_time_ms
                    }
                }

                // note(isak): copies growing temp slider queue to static sized mapset arena
                temp_slider_size := int(slider_temp_queue.len) * size_of(Slider_Path)
                slider_array_ptr, err := mem.alloc(temp_slider_size); assert(err == .None)
                mem.copy(slider_array_ptr, raw_data(slider_temp_queue.data), temp_slider_size)
                result.slider_paths = slice.from_ptr(cast(^Slider_Path)slider_array_ptr, int(slider_temp_queue.len))
        }
    }
    
    map_postprocess(mapset, &result)
    
    return result
}

mapset_load_shader_entry :: proc(mapset: ^Mapset, name, vs, fs: string, blend_mode: Blend_Mode) {
    if name == "" do return
    if vs == "" || fs == "" {
        log.errorf("mapset shader '{}': missing VertexShader or FragmentShader, skipping", name)
        return
    }
    
    vs := strings.clone(vs)
    fs := strings.clone(fs)
    shader, err := shader_init(vs, fs, context.temp_allocator)
    if err != .NONE {
        log.errorf("mapset shader '{}': compile error, skipping", name)
        return
    }
    queue.push(&window.shaders, shader)
    
    name_key := strings.clone(name)
    mapset.pipeline_slot_by_name[name_key] = u32(mapset.num_shaders)
    append(&mapset.shader_blend_modes, blend_mode)
    
    desc := quad_pipeline_desc()
    desc.shader = shader.shader
    desc.colors[0].blend = blend_state_for_mode(blend_mode)
    queue.push(&window.pipelines, sg.make_pipeline(desc))
    
    log.infof("mapset shader '{}' loaded (blend: {})", name, blend_mode)
    mapset.num_shaders += 1
}


mapset_load_buffer_entry :: proc(mapset: ^Mapset, name, source: string, size: int) {
    if name == "" do return

    buf: Mapset_Buffer

    if source != "" {
        // note(isak): file-backed buffer
        model := load_model(source)
        if model == nil {
            log.errorf("mapset buffer '{}': failed to load source '{}'", name, source)
            return
        }
        buf.id   = model.id
        buf.size = model.size
    } else if size > 0 {
        // note(isak): writable buffer. persistently mapped so Lua can write directly
        buf = Mapset_Buffer(sbo_init(u8, size))
    } else {
        log.errorf("mapset buffer '{}': must specify either Source or Size, skipping", name)
        return
    }

    name_key := strings.clone(name)
    mapset.buffer_slot_by_name[name_key] = u32(mapset.buffers.len)
    queue.push_back(&mapset.buffers, buf)
    log.infof("mapset buffer '{}' loaded (size: {} bytes, writable: {})", name, buf.size, buf.data != nil)
}

map_postprocess :: proc(mapset: ^Mapset, osu_map: ^Osu_Map) {
    
    sort.quick_sort_proc(osu_map.hitobjects, proc(a, b: Hitobject) -> int {
        return int(a.start_time_ms) - int(b.start_time_ms)
    })
    
    sort.quick_sort_proc(osu_map.timing_points, proc(a, b: Timing_Point) -> int {
        if int(a.time) == int(b.time) {
            return int(a.type) - int(b.type)
        }    
        return int(a.time) - int(b.time)
    })
    
    assert(osu_map.timing_points[0].type == .UNINHERITED, "map error :: first timing point is inherited")
    osu_map.timing_points[0].starts_at_beat = 1
    
    current_timing_point_index_uninherited: int
    current_timing_point_index_inherited: int
    
    combo_index := 0
    combo_number := 1
    
    last_non_spinner_hobj_i := 0
    
    for &hobj, i in osu_map.hitobjects {
        hobj.index = i
        
        // note(isak): millisecond lookup has to point to the first hitobject in case of 
        // simultaneous objects so that range lookups work
        hobj_key := int(hobj.start_time_ms)
        if !(hobj_key in mapset.hitobject_index_by_ms) {
            mapset.hitobject_index_by_ms[hobj_key] = hobj.index
        }
        
        // note(isak): seek last counting timing point
        for &timing_point in osu_map.timing_points[current_timing_point_index_inherited:] {
            if hobj.start_time_ms < timing_point.time {
                break
            }
            if timing_point.type == .UNINHERITED {
                if current_timing_point_index_uninherited != current_timing_point_index_inherited {
                    old_timing_point := &osu_map.timing_points[current_timing_point_index_uninherited]
                    timing_point.starts_at_beat = old_timing_point.starts_at_beat + 
                        int((timing_point.time - old_timing_point.time) / old_timing_point.beat_length)
                }
                
                current_timing_point_index_uninherited = current_timing_point_index_inherited
            }
            current_timing_point_index_inherited += 1
        }
        current_timing_point_index_inherited = max(current_timing_point_index_inherited - 1, 0)
        
        hobj.timing_point_index_uninherited = current_timing_point_index_uninherited
        hobj.timing_point_index_inherited = current_timing_point_index_inherited
        
        // note(isak): slider timing state
        if hobj.type == .SLIDER {
            slider := &hobj.slider_state
            
            slider.distance = osu_map.slider_paths[hobj.slider_path_index].distance_osupx
            slider.velocity = 1.0
            
            uninherited_tp := osu_map.timing_points[current_timing_point_index_uninherited]
            uninherited_beat_length := uninherited_tp.beat_length
            
            if current_timing_point_index_uninherited != current_timing_point_index_inherited {
                inherited_tp := osu_map.timing_points[current_timing_point_index_inherited]
                inherited_beat_length := inherited_tp.beat_length
                
                slider.velocity = -1 / (inherited_beat_length / 100)
            }
            
            slider.duration_ms = slider.distance / (slider.velocity * 100 * osu_map.diff_slider_velocity) * uninherited_beat_length
            hobj.end_time_ms = hobj.start_time_ms + (slider.duration_ms * f64(slider.path_travel_count))
            
            slider.tick_interval_ms = uninherited_tp.beat_length / osu_map.diff_slider_tickrate
            slider.tick_count = int((slider.duration_ms - SLIDER_TICK_AT_SLIDEREND_CHECK_LENIENCY_MS) / slider.tick_interval_ms)
        }
        
        // note(isak): combo colors and number.
        // color mirrors osu logic - we do a preincrement and start at the second combo color...
        if .NEW_COMBO in hobj.flags || i == 0 {
            combo_index = (combo_index + 1 + int(hobj.combo_color_skip_offset))
            combo_number = 1
            
            if i > 0 {
                prev_hobj := &osu_map.hitobjects[last_non_spinner_hobj_i]
                prev_hobj.flags |= {.LAST_IN_COMBO}
            }
        }
        
        hobj.combo_index = combo_index
        hobj.combo_number = u16(combo_number)
        combo_number += 1
        
        if hobj.type != .SPINNER {
            last_non_spinner_hobj_i = i
        }
    }
    
    osu_map.hitobjects[last_non_spinner_hobj_i].flags |= {.LAST_IN_COMBO}
}

mapset_parse_osu_slider_params :: proc(hobj: ^Hitobject, slider: ^Slider_Path, params: string, alloc: mem.Allocator = context.allocator) {
    from_i, s_len: int
    arg_i: int
    for from_i < len(params) && 0 <= s_len {
        defer arg_i += 1
        defer from_i += s_len + 1
        s_len = strings.index_byte(params[from_i:], ',')
        value := s_len >= 0 ? params[from_i:from_i + s_len] : params[from_i:]
        ok: bool
        switch arg_i {
            case 0:
                slider_type, slider_nodes_str := get_key_value(value, '|')
                switch slider_type {
                    case "B": slider.type = .BEZIER
                    case "P": slider.type = .ARC
                    case "L": slider.type = .LINEAR
                    case "C": slider.type = .CATMULL
                }
                if len(slider_nodes_str) > 0 {
                    slider.nodes = mapset_parse_osu_slider_nodes(slider_nodes_str, hobj.pos)
                } else {
                    slider.nodes = make_slice([]Slider_Node, 1)
                    slider.nodes[0] = hobj.pos
                }
            case 1:
                hobj.slider_state.path_travel_count, ok = strconv.parse_int(value); assert(ok)
            case 2:
                slider.distance_osupx, ok = strconv.parse_f64(value); assert(ok)
            case 3:
                // edgesounds
            case 4:
                // edgesets
        }
    }
    assert(slider.type != .NONE, "slider parse error :: unknown slidertype")
}

@(require_results)
mapset_parse_osu_slider_nodes :: proc(value: string, start_pos: vec2, alloc: mem.Allocator = context.allocator) -> []Slider_Node {
    temp := virtual.arena_temp_begin(&memory.arenas[.FRAME])
    defer virtual.arena_temp_end(temp)

    sections := strings.split(value, "|", virtual.arena_allocator(temp.arena))
    result := make_slice([]Slider_Node, len(sections) + 1, alloc)

    result[0] = start_pos

    ok: bool
    for section, i in sections {
        node := &result[i + 1]

        sep_at := strings.index_byte(section, ':')
        assert(sep_at > 0, "slider parse error :: unsized node")
        node.x, ok = strconv.parse_f32(section[:sep_at]); assert(ok, "slider parse error :: node.x is not a number")
        node.y, ok = strconv.parse_f32(section[sep_at + 1:]); assert(ok, "slider parse error :: node.y is not a number")
    }

    return result
}


load_model :: proc(path: string) -> ^GL_Buffer(Mesh_Vertex) {
    cgltf_alloc :: proc "c" (user: rawptr, size: uint) -> rawptr {
        alloc := memory.allocators[.FRAME]
        context = runtime.default_context()
        buf, err := alloc.procedure(alloc.data, .Alloc, int(size), align_of(f32), nil, 0)
        return raw_data(buf)
    }
    cgltf_free :: proc "c" (user, ptr: rawptr) {}

    options := cgltf.options{
        memory = {
            alloc_func = cgltf_alloc,
            free_func = cgltf_free,
        }
    }

    path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
    data, result := cgltf.parse_file(options, path_cstr)
    if result != .success {
        log.errorf("load_model '{}': parse failed ({})", path, result)
        return nil
    }
    result = cgltf.load_buffers(options, data, path_cstr)
    if result != .success {
        log.errorf("load_model '{}': load_buffers failed ({})", path, result)
        return nil
    }
    if len(data.meshes) == 0 || len(data.meshes[0].primitives) == 0 {
        log.errorf("load_model '{}': no meshes found", path)
        return nil
    }

    vertex_count: int
    for attrib in data.meshes[0].primitives[0].attributes {
        if attrib.type == .position {
            vertex_count = int(attrib.data.count)
            break
        }
    }
    if vertex_count == 0 {
        log.errorf("load_model '{}': no position attribute found", path)
        return nil
    }

    store := r_create_static_store(Mesh_Vertex, vertex_count, memory.allocators[.MAPSET])

    for primitive in data.meshes[0].primitives[:] {
        for attrib in primitive.attributes {
            attr_bufview := attrib.data.buffer_view
            #partial switch attrib.type {
            case .position:
                for pos, i in slice.from_ptr(cast(^vec3)attr_bufview.buffer.data, int(attrib.data.count)) {
                    store.data[i].pos = pos
                }
            case .normal:
                for norm, i in slice.from_ptr(cast(^vec3)attr_bufview.buffer.data, int(attrib.data.count)) {
                    store.data[i].norm = norm
                }
            case .texcoord:
                for uv, i in slice.from_ptr(cast(^vec2)attr_bufview.buffer.data, int(attrib.data.count)) {
                    store.data[i].uv = uv
                }
            }
        }
    }

    log.infof("load_model '{}': {} vertices loaded", path, vertex_count)
    return store
}


convert_approach_rate_to_preempt_ms :: proc(ar: f64) -> f64 {
    return 1800 - min(ar, 5) * 120 - (max(ar, 5) - 5) * 150
}

convert_circle_size_to_radius_osupx :: proc(cs: f64) -> f32 {
    return f32((54.4 - 4.48 * cs) * 1.00041)
}

convert_overall_difficulty_to_timing_window :: proc(od: f64) -> Timing_Window {
    return {
        marvelous = 80 - 6 * od,
        good = 140 - 8 * od,
        ok = 200 - 10 * od,
        miss = 400,
    }
}


mapset_check_system_file_watch :: proc(watch: ^Win32_Directory_Watch) -> [Notosu_Map_System]bool {
    updated_systems: [Notosu_Map_System]bool

    win32_get_directory_changes(watch)
    if watch.notify_bytes_written > 0 {
        
        wfilename_buf: [MAX_PATH]u16
        for true {
            notify, wfilename_len := win32_watch_get_next_notify(watch, &wfilename_buf)
            if wfilename_len > 0 {
                filename_buf: [MAX_PATH]u8
                for i in 0..<wfilename_len {
                    filename_buf[i] = u8(wfilename_buf[i])
                }
                
                extension := filepath.ext(string(filename_buf[:wfilename_len]))
                switch extension {
                    case ".osu": updated_systems[.OSU_FILE] = true
                    case ".glsl": updated_systems[.SHADERS] = true
                    case ".lua": updated_systems[.SCRIPTS] = true
                    case ".notosu": updated_systems[.NOTOSU_FILE] = true
                }
                for img_ext in supported_image_extensions {
                    if extension == img_ext {
                        updated_systems[.ASSETS] = true
                        break
                    }
                }

                if notify.next_entry_offset == 0 {
                    break
                }
            } 
            else {
                break
            }
        }
        watch.notify_bytes_written = 0
    }
    return updated_systems
}

// note(isak): returns the index of the first hitobject with start_time_ms >= from_ms.
// hitobjects are sorted by start time, so this is a binary search.
hitobject_lower_bound_ms :: proc(from_ms: f64) -> int {
    hitobjects := game.beatmap.hitobjects
    lo, hi := 0, len(hitobjects)
    for lo < hi {
        mid := (lo + hi) / 2
        if hitobjects[mid].start_time_ms < from_ms {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}
