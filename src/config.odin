package notosu

import "core:encoding/ini"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"


// note(isak): user config is saved to a .ini file, just like osu
User_Configuration :: struct {
    universal_offset_ms: int,
}

config_load :: proc(path: string) -> (result: User_Configuration) {
    result = config_supply_default()

    m, _, ok := ini.load_map_from_path(path, context.temp_allocator)
    if !ok do return

    get :: proc(pairs: map[string]string, key: string) -> (string, bool) {
        v, ok := pairs[key]
        return strings.trim_space(v), ok && len(v) > 0
    }

    // note(isak): top level is sectionless (we don't need a section here)
    if gen, ok := m[""]; ok {
        if v, ok := get(gen, "universal_offset_ms"); ok {
            result.universal_offset_ms, ok = strconv.parse_int(v)
        }
    }
    return
}

config_save :: proc(path: string) {
    sb := strings.builder_make(context.temp_allocator)
    w  := strings.to_writer(&sb)

    ini.write_pair(w, "universal_offset_ms", game.user_config.universal_offset_ms)

    err := os.write_entire_file(path, transmute([]byte)strings.to_string(sb))
    if err != os.General_Error.None {
        log.error("error while writing to settings file!", err)
        bkp_path := strings.concatenate({path, ".tmp"})
        bkp_err := os.write_entire_file(bkp_path, transmute([]byte)strings.to_string(sb))
        if bkp_err != os.General_Error.None {
            log.error("couldn't write backup path file either!", bkp_err)
        }
    }
    
    assert(err == os.General_Error.None, "config_save :: error while writing to settings file!")
}

config_supply_default :: proc() -> (result: User_Configuration) {
    return {
        universal_offset_ms = -28,
    }
}
