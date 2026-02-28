package notosu

import "base:intrinsics"
import "base:runtime"

import q "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:slice"
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
Mapset :: struct {
    open: bool,
    folder_path: string,
    osu_map: Osu_Map,
    notosu_map: Notosu_Map,
    
    num_shaders: int,
    textures: q.Queue(Texture),
    texture_slot_by_name: map[string]u32,
    pipeline_slot_by_name: map[string]u32,
    hitobject_index_by_ms: map[int]int,
    
    model_store: ^GL_Buffer(Mesh_Vertex),

    watch: Win32_Directory_Watch
}


mapset_texture :: proc(name: string) -> (result: ^Texture, found: bool) {
    assert(game.active_mapset != nil)
    index: u32
    index, found = game.active_mapset.texture_slot_by_name[name]
    if found do result = q.get_ptr(&game.active_mapset.textures, index)
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
}

notosu_section_headers := []string{
    "",
    "[General]",
    "[Shaders]",
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

Osu_Sample_Set :: enum {
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

// note(isak): clones given path into mapset allocator
mapset_open_for_editing :: proc(path: string) -> (^Mapset, bool) {
    context.allocator = memory.allocators[.MAPSET]
    
    mapset_path := strings.clone(path)
    mapset, alloc_err := new(Mapset)
    assert(alloc_err == .None)

    if !os.exists(path) {
        return mapset, false
    }

    mapset.folder_path = mapset_path
    

    // note(isak): file contents cannot exit this function, don't leave strings allocated here
    defer mem.free_all(context.temp_allocator)
    defer os.change_directory(app.base_dir)
    
    q.init(&mapset.textures)
    mapset.texture_slot_by_name = make(map[string]u32, 16)
    mapset.pipeline_slot_by_name = make(map[string]u32, 16)
    mapset.hitobject_index_by_ms = make(map[int]int, 128)
    
    walk_directory(mapset, path)

    cur_path, err := os.get_working_directory(context.temp_allocator)
    mapset.watch = win32_init_directory_watch(cur_path)
    log.info("initialized directory watch for path:", cur_path)
    
    return mapset, true
}

walk_directory :: proc(mapset: ^Mapset, path: string) {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    defer os.change_directory(cwd)
    
    files: []os.File_Info
    dir_handle, io_err := os.open(path)
    files, io_err = os.read_dir(dir_handle, 1024, context.temp_allocator)
    
    os.change_directory(path)

    for file in files {
        if file.type == .Directory {
            walk_directory(mapset, file.name)
        } else {
            handle_file(mapset, file)
        }
    }
}

handle_file :: proc(mapset: ^Mapset, file: os.File_Info) {
    extension := filepath.ext(file.name)
    switch extension {
        case ".notosu": {
            filedata, file_err := read_entire_file_to_string(file.name, context.temp_allocator)
            mapset.notosu_map = mapset_parse_notosu(mapset, filedata)
        }
        case ".osu": {
            filedata, file_err := read_entire_file_to_string(file.name, context.temp_allocator)
            mapset.osu_map = mapset_parse_osu(mapset, filedata)
        }
        case ".png", ".jpg": {
            tex_key := strings.clone(file.name, memory.allocators[.MAPSET])
            tex, file_err := texture_from_file(file.name)
            mapset.texture_slot_by_name[tex_key] = u32(mapset.textures.len)
            q.push_back(&mapset.textures, tex)
        } 
        case ".gltf": {
            model_store := load_model(file.name)
        }
    }
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
            free_func = cgltf_free
        }
    }
    
    path_cstr := strings.clone_to_cstring(path)
    data, result := cgltf.parse_file(options, path_cstr)
    assert(result == .success)
    result = cgltf.load_buffers(options, data, path_cstr)
    assert(result == .success)
    
    store := r_create_static_store(Mesh_Vertex, 36, memory.allocators[.MAPSET])
    
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
    
    return store
}


mapset_parse_notosu :: proc(mapset: ^Mapset, notosu_file: string) -> Notosu_Map {
    result: Notosu_Map
    context.allocator = memory.allocators[.MAPSET]
    
    // todo(isak): test code that should be replaced with notosu shader section reads
    {
        builtin_quad_vs_path := strings.concatenate({app.base_dir, "/", quad_vs_path}, context.allocator)
        shader, err := shader_init(builtin_quad_vs_path, "quad_wave.fs.glsl")
        assert(err == .NONE)
        
        mapset.pipeline_slot_by_name["wave"] = u32(mapset.num_shaders)
        q.push(&window.shaders, shader)
        
        custom_desc := quad_pipeline_desc()
        custom_desc.shader = shader.shader
        q.push(&window.pipelines, sg.make_pipeline(custom_desc))
    }
    
    mesh_desc := sg.Pipeline_Desc{
        label = "builtin.quad",
        shader = window.shaders.data[builtin_pipeline_slot(.QUAD)].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = {
                enabled = true,
                op_alpha = .SUBTRACT,
                src_factor_rgb = .SRC_ALPHA,
                src_factor_alpha = .SRC_ALPHA,
                dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            }}
        },
        depth = {compare = .LESS_EQUAL, write_enabled = true},
    }
    
    c: Consumer = {
        str = notosu_file
    }
    
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
                        result.lua_entry_point = strings.concatenate({mapset.folder_path, value}, memory.allocators[.GLOBAL])
                }
            }
        case .SHADERS:
        
        case: 
            unreachable()
        }
    }
    
    return result
}


mapset_parse_osu :: proc(mapset: ^Mapset, osu_file: string) -> Osu_Map {
    result: Osu_Map
    context.allocator = memory.allocators[.MAPSET]
    
    c: Consumer = {
        str = osu_file
    }
    
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
            section_index = (section_index + 1) % int(max(Osu_Section_Header_Types))
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
                        case "SampleSet": 
                            switch value {
                                case "Normal": result.sample_set = .NORMAL
                                case "Soft":   result.sample_set = .SOFT
                                case "Drum":   result.sample_set = .DRUM
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
                        case "SliderTickRate": result.diff_slider_tickrate, ok = strconv.parse_int(value); assert(ok)
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
            case .HITOBJECTS:
                result.hit_objects = make_slice([]Hit_Object, len(lines) - 1)

                slider_temp_queue: q.Queue(Slider_Path)
                q.init(&slider_temp_queue, 1024, context.temp_allocator)
                
                for i in 1..<len(lines) {
                    hobj := &result.hit_objects[i - 1]
                    hobj_extra_params: string
                    hobj.index = i - 1

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
                                hobj.type_flags = type_flags

                                is_circle    := type_flags & (1 << 0)
                                is_slider    := type_flags & (1 << 1)
                                is_nc        := type_flags & (1 << 2)
                                is_spinner   := type_flags & (1 << 3)
                                colorhax_inc := type_flags & (0b111 << 4)

                                if is_circle > 0 { 
                                    hobj.type = .CIRCLE 
                                }
                                else if is_slider > 0 { 
                                    hobj.type = .SLIDER 
                                }
                                else if is_spinner > 0 { 
                                    hobj.type = .SPINNER 
                                }
                            case 4:
                                // hitsound flag
                            case 5:
                                hobj_extra_params = lines[i][from_i:]
                                break
                        }
                    }

                    if hobj.type != .SLIDER {
                        hobj.end_time_ms = hobj.start_time_ms
                    }
                    
                    if hobj.type == .SLIDER {
                        slider: Slider_Path
                        mapset_parse_osu_slider_params(hobj, &slider, hobj_extra_params)
                        slider.instance_count, slider.first_instance_at = 
                            write_instances_from_path(&window.renderer.slider_instances, &slider)
                                                      
                        hobj.slider_path_index = int(slider_temp_queue.len)
                        q.append(&slider_temp_queue, slider)
                        

                        // todo(isak) slider time calculation... requires redline & greenline handling. formula:
                        // length / (SliderMultiplier * 100 * SV) * beatLength

                        hobj.end_time_ms = hobj.start_time_ms + slider.distance_osupx * 2
                    }
                    
                    // note(isak): millisecond lookup has to point to the first hitobject in case of 
                    // simultaneous objects so that range lookups work
                    hobj_key := int(hobj.start_time_ms)
                    if !(hobj_key in mapset.hitobject_index_by_ms) {
                        mapset.hitobject_index_by_ms[int(hobj.start_time_ms)] = hobj.index
                    }
                }

                // note(isak): looks like a memory optimization, but i don't think it makes that much sense
                temp_slider_size := int(slider_temp_queue.len) * size_of(Slider_Path)
                slider_array_ptr, err := mem.alloc(temp_slider_size); assert(err == .None)
                mem.copy(slider_array_ptr, raw_data(slider_temp_queue.data), temp_slider_size)
                result.slider_paths = slice.from_ptr(cast(^Slider_Path)slider_array_ptr, int(slider_temp_queue.len))
        }
    }

    return result
}

mapset_parse_osu_slider_params :: proc(hobj: ^Hit_Object, slider: ^Slider_Path, params: string, alloc: mem.Allocator = context.allocator) {
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
                slider.nodes = mapset_parse_osu_slider_nodes(slider_nodes_str)
            case 1:
                hobj.slider_repeats, ok = strconv.parse_int(value); assert(ok)
            case 2:
                slider.distance_osupx, ok = strconv.parse_f64(value); assert(ok)
            case 3:
                // edgesounds
            case 4:
                // edgesets
        }
    }
    assert(slider.type != .NONE, fmt.tprintln("slider parse error :: unknown slidertype:", params))
}

@(require_results)
mapset_parse_osu_slider_nodes :: proc(value: string, alloc: mem.Allocator = context.allocator) -> []Slider_Node {
    temp := virtual.arena_temp_begin(&memory.arenas[.FRAME])
    defer virtual.arena_temp_end(temp)

    sections := strings.split(value, "|", virtual.arena_allocator(temp.arena))
    result := make_slice([]Slider_Node, len(sections), alloc)

    sec_i: int
    ok: bool
    for section in sections {
        defer sec_i += 1
        node := &result[sec_i]

        sep_at := strings.index_byte(section, ':')
        assert(sep_at > 0, fmt.tprintfln("slider parse error :: unsized node:", value))
        node.x, ok = strconv.parse_f32(section[:sep_at]); assert(ok, fmt.tprintfln("slider parse error :: node.x is not a number:", value))
        node.y, ok = strconv.parse_f32(section[sep_at + 1:]); assert(ok, fmt.tprintfln("slider parse error :: node.y is not a number:", value))
    }

    return result
}


convert_approach_rate_to_preempt_ms :: proc(ar: f64) -> f64 {
    return 1800 - min(ar, 5) * 120 - (max(ar, 5) - 5) * 150
}

convert_circle_size_to_radius_osupx :: proc(cs: f64) -> f32 {
    return f32((54.4 - 4.48 * cs) * 1.00041)
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
