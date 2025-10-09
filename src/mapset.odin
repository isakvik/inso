package notosu

import "core:mem/virtual"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sys/windows"

/*
mapset definition:
- .osu (core, lets you interface with existing editors)
- .notosu (additional interface, lua scripting capabilities)
- .lua files (for import utilities)
- .glsl (shaders, either merged glsl or .vs.glsl/.fs.glsl)

todo(isak): missing functionality:
    - global mapset index; should enable quick lookup for song select stuff
    - initial file discovery and load
    - 

*/
Mapset :: struct {
    open: bool,
    folder_path: string,

    num_layers: u32,

    watch: Win32_Directory_Watch
}

mapset_open_for_editing :: proc(path: string) -> (^Mapset, bool) {
    virtual.arena_free_all(&memory.mapset_arena)

    mapset, alloc_err := arena_push(&memory.mapset_arena, Mapset)
    if alloc_err != .None || !os.exists(path) {
        return mapset, false
    }

    mapset.folder_path = path
    
    files: []os.File_Info
    dir_handle, io_err := os.open(path)
    files, io_err = os.read_dir(dir_handle, 128, context.temp_allocator)
    

    
    for file in files {
        extension := filepath.ext(file.name)
        switch extension {
            case ".notosu": {
                filedata, file_err := read_entire_file_to_string(file.fullpath, context.temp_allocator)
                _mapset_parse_notosu(mapset, filedata)
            }
        }
    }

    mapset.watch = win32_init_directory_watch(path)
    return mapset, true
}

Notosu_Map_System :: enum {
    OSU_FILE,
    NOTOSU_FILES, // note(isak): this also includes scripts
    SHADERS,
    Count
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


_mapset_parse_notosu :: proc(mapset: ^Mapset, data: string) {
    fmt.println(data)
}
