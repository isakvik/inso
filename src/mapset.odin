package notosu

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sys/windows"


Mapset :: struct {
    path: string,

    watch: Win32_Directory_Watch
}

mapset_open :: proc(path: string) -> (Mapset, bool) {
    result := Mapset{ path = path }
    if (!os.exists(path)) {
        return result, false
    }

    result.watch = win32_init_directory_watch(path)
    
    return result, true
}

Notosu_Map_System :: enum {
    OSU_FILE,
    NOTOSU_FILE,
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
                switch(extension) {
                    case ".osu": updated_systems[.OSU_FILE] = true
                    case ".notosu": updated_systems[.NOTOSU_FILE] = true
                    case ".glsl": updated_systems[.SHADERS] = true
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
    }

    return updated_systems
}
