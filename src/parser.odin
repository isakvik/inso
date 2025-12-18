package notosu

import "core:strings"
import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:unicode/utf8/utf8string"
import "core:unicode/utf8"
import "core:unicode"
import "core:strconv"


Consumer :: struct {
    str: string,
    at: int
}

consume_spaces :: proc(c: ^Consumer) -> int {
    begin := c.at
    for c.at < len(c.str) && c.str[c.at] == ' ' {
        c.at += 1
    }
    return c.at - begin
}

consume_newline :: proc(c: ^Consumer) -> int {
    begin := c.at
    if c.str[c.at] != '\r' {
        c.at += 1
    }
    if c.str[c.at] != '\n' {
        c.at += 1
    }
    return c.at - begin
}

consume_line :: proc(c: ^Consumer) -> string {
    begin := c.at
    for c.at < len(c.str) && c.str[c.at] != '\n' && c.str[c.at] != '\r' {
        c.at += 1
    }
    result := c.str[begin:c.at]
    if c.at < len(c.str) {
        c.at += consume_newline(c)
    }
    return result
}

consume_until_next_section :: proc(c: ^Consumer) -> string {
    begin := c.at
    result := c.str[begin:c.at]

    c.at += consume_newline(c)
    return result
}

parse_int :: proc(c: ^Consumer) -> (int, int) {
    result: int
    len: int

    sign := 1
    if c.str[c.at] == '-' {
        sign = -1
        len += 1
    }

    cursor := c.at + len
    for '0' <= c.str[cursor] && c.str[cursor] <= '9' {
        cursor += 1
    }
    len += cursor

    radix := 1
    for cursor > 0 {
        cursor -= 1
        num := int(c.str[cursor] - '0')
        result += num * radix
        radix *= 10
    }
    return result, len
}


consume_section :: proc(c: ^Consumer, alloc: runtime.Allocator = context.temp_allocator) -> [dynamic]string {
    arr := make([dynamic]string, alloc)
    for {
        str := consume_line(c)
        if len(str) == 0 || str == "\n" || str == "\r\n" {
            break
        }
        append(&arr, str)
    }
    return arr
}

get_key_value :: proc(str: string, separator: u8 = ':') -> (string, string) {
    sep_at := -1
    for i in 0..<len(str) {
        if str[i] == separator {
            sep_at = i
            break
        }
    }
    if sep_at < 0 {
        return str, ""
    }

    trim_start, trim_end: int
    if sep_at > 0 && str[sep_at - 1] == ' ' {
        trim_start = 1
    }
    if sep_at < len(str) - 1 && str[sep_at + 1] == ' ' {
        trim_end = 1
    }
    return str[:sep_at - trim_start], str[sep_at + 1 + trim_end:]
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

_mapset_parse_osu :: proc(osu_file: string) -> Osu_Map {
    result: Osu_Map
    
    c: Consumer = {
        str = osu_file
    }
    
    scratch := virtual.arena_temp_begin(&memory.frame_arena)
    defer virtual.arena_temp_end(scratch)

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
                    switch key {
                        case "AudioFilename": result.audio_filename = strings.clone(value, memory.mapset_allocator)
                        case "AudioLeadIn": result.audio_lead_in, _ = strconv.parse_f64(value)
                    }
                }
        }
    }
    
    

    return result
}
