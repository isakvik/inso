package notosu

import "core:mem"
import "core:mem/virtual"
import "core:fmt"
import os "core:os/os2"
import "core:path/filepath"
import "core:sys/windows"
import "core:strings"
import "core:strconv"
import "base:runtime"

/*
mapset definition:
- .osu (core, lets you interface with existing editors)
- .notosu (additional interface, lua scripting capabilities)
- .lua files (for import utilities)
- .glsl (shaders, either merged glsl or .vs.glsl/.fs.glsl)

todo(isak): missing functionality:
    - mapset index; should enable quick lookup for song select stuff
    - osu parsing
        slider parsing
        combocolors?

    - notosu definition and script running

*/
Mapset :: struct {
    open: bool,
    folder_path: string,
    osu_map: Osu_Map,

    watch: Win32_Directory_Watch
}

Notosu_Map_System :: enum {
    OSU_FILE,
    NOTOSU_FILES, // note(isak): this also includes scripts
    SHADERS,
    Count
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


mapset_clear_and_reload :: proc(mapset: ^Mapset) -> ^Mapset {
    win32_close_directory_watch(&mapset.watch)
    mapset_path := strings.clone(mapset.folder_path, context.temp_allocator)
    
    virtual.arena_free_all(&memory.element_arena)
    virtual.arena_free_all(&memory.mapset_arena)
    reloaded_mapset, ok := mapset_open_for_editing(mapset_path)
    assert(ok)
    write_instances_from_path(&window.renderer.slider_instances, &test_slider, memory.mapset_allocator)
    return reloaded_mapset
}

mapset_open_for_editing :: proc(path: string) -> (^Mapset, bool) {
    mapset_path := strings.clone(path, memory.mapset_allocator)
    mapset, alloc_err := new(Mapset, memory.mapset_allocator)
    assert(alloc_err == .None)

    if !os.exists(path) {
        return mapset, false
    }

    mapset.folder_path = mapset_path
    
    files: []os.File_Info
    dir_handle, io_err := os.open(path)

    // note(isak): file contents cannot exit this function, don't leave strings
    files, io_err = os.read_dir(dir_handle, 1024, context.temp_allocator)
    defer mem.free_all(context.temp_allocator)
    
    for file in files {
        extension := filepath.ext(file.name)
        switch extension {
            case ".notosu": {
                filedata, file_err := read_entire_file_to_string(file.fullpath, context.temp_allocator)
                mapset_parse_notosu(mapset, filedata)
            }
            case ".osu": {
                filedata, file_err := read_entire_file_to_string(file.fullpath, context.temp_allocator)
                mapset.osu_map = mapset_parse_osu(filedata, memory.mapset_allocator)
            }
        }
    }

    mapset.watch = win32_init_directory_watch(path)
    return mapset, true
}

mapset_check_system_file_watch :: proc(watch: ^Win32_Directory_Watch) -> [Notosu_Map_System]bool {
    updated_systems: [Notosu_Map_System]bool

    win32_get_directory_changes(watch)
    if watch.notify_bytes_written > 0 {
        
        wfilename_buf: [windows.MAX_PATH]u16
        for true {
            notify, wfilename_len := win32_watch_get_next_notify(watch, &wfilename_buf)
            if wfilename_len > 0 {
                filename_buf: [windows.MAX_PATH]u8
                for i in 0..<wfilename_len {
                    filename_buf[i] = u8(wfilename_buf[i])
                }
                
                extension := filepath.ext(string(filename_buf[:wfilename_len]))
                switch extension {
                    case ".osu": updated_systems[.OSU_FILE] = true
                    case ".glsl": updated_systems[.SHADERS] = true
                    case ".lua": fallthrough
                    case ".notosu": updated_systems[.NOTOSU_FILES] = true
                    // todo(isak) asset files... eventually
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


mapset_parse_notosu :: proc(mapset: ^Mapset, data: string) {
    fmt.println(data)
}


mapset_parse_osu :: proc(osu_file: string, alloc: mem.Allocator) -> Osu_Map {
    result: Osu_Map
    
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
                        case "AudioFilename": result.audio_filename = strings.clone(value, alloc)
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
                        case "Title": result.title = strings.clone(value, alloc)
                        case "TitleUnicode": result.title_unicode = strings.clone(value, alloc)
                        case "Artist": result.artist = strings.clone(value, alloc)
                        case "ArtistUnicode": result.artist_unicode = strings.clone(value, alloc)
                        case "Creator": result.creator = strings.clone(value, alloc)
                        case "Version": result.difficulty_name = strings.clone(value, alloc)
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
            case .HITOBJECTS:
                result.hit_objects = make_slice([]Hit_Object, len(lines) - 1, alloc)
                
                for i in 1..<len(lines) {
                    hobj := &result.hit_objects[i - 1]

                    from_i, s_len: int
                    arg_i: int

                    for from_i < len(lines[i]) && 0 <= s_len {
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
                                if hobj.type == .SLIDER {
                                    //result.hit_objects = make(Slider_Path, alloc)
                                    
                                    //assert(false)
                                }
                                // else handle hitsound flags
                        }

                        from_i += s_len + 1
                        arg_i += 1
                    }

                    if hobj.type == .CIRCLE {
                        hobj.end_time_ms = hobj.start_time_ms
                    }
                    
                    if hobj.type == .SLIDER {
                        slider := &map_sliders[slider_offset]
                        write_instances_from_path(&window.renderer.slider_instances, slider, alloc)
                        slider_offset = 0
                        
                        // todo(isak)
                        hobj.end_time_ms = hobj.start_time_ms
                    }
                }
        }
    }
    
    result.preempt_ms = convert_approach_rate_to_preempt_ms(result.diff_approach_rate)
    result.circle_radius_osupx = convert_circle_size_to_radius_osupx(result.diff_circle_size)

    return result
}


convert_approach_rate_to_preempt_ms :: proc(ar: f64) -> f64 {
    return 1800 - min(ar, 5) * 120 - (max(ar, 5) - 5) * 150
}

convert_circle_size_to_radius_osupx :: proc(cs: f64) -> f32 {
    return f32((54.4 - 4.48 * cs) * 1.00041)
}
