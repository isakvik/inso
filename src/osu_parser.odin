package notosu

import "base:runtime"
import "core:strconv"
import "core:strings"


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

consume_to_newline :: proc(c: ^Consumer) -> int {
    begin := c.at
    if c.at < len(c.str) && c.str[c.at] != '\n' {
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
        consume_to_newline(c)
        c.at += 1
    }
    return result
}

consume_until_next_section :: proc(c: ^Consumer) -> string {
    begin := c.at
    result := c.str[begin:c.at]

    consume_to_newline(c)
    c.at += 1
    return result
}

// note(isak): returns true when the consumer is positioned at a [Section] header line.
// [[Subgroup]] lines are NOT section headers and return false.
_is_section_header_at :: proc(c: ^Consumer) -> bool {
    if c.at >= len(c.str) do return false
    if c.str[c.at] != '[' do return false
    return c.at + 1 < len(c.str) && c.str[c.at + 1] != '['
}

// note(isak): collects lines from the current position until the next [Section] header (exclusive)
// or EOF. blank lines are skipped. [[Subgroup]] lines are included as content.
// the first line consumed is always included even if it looks like a header, so callers
// get lines[0] = "[Section]" as the section identifier.
consume_section :: proc(c: ^Consumer, alloc: runtime.Allocator = context.temp_allocator) -> [dynamic]string {
    arr := make([dynamic]string, alloc)
    first := true
    for c.at < len(c.str) {
        if !first && _is_section_header_at(c) {
            break
        }
        str := consume_line(c)
        first = false
        if len(str) == 0 {
            continue
        }
        append(&arr, str)
    }
    return arr
}

get_key_value :: proc "contextless" (str: string, separator: u8 = ':') -> (string, string) {
    sep_at := strings.index_byte(str, separator)
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

strip_line_comment :: proc "contextless" (line: string) -> string {
    if at := strings.index(line, "//"); at >= 0 {
        return line[:at]
    }
    return line
}

// note(isak): parses an .osu-style ini (sections in [Brackets], "Key: value" pairs, // comments)
// into section -> (key -> value). tolerant of files hand-edited by players: missing/duplicate sections, 
// keys in any order, stray blank lines, and trailing comments all parse cleanly. 
// returned strings are slices into src, so keep src alive as long as the returned maps.
parse_osu_ini :: proc(src: string, alloc := context.allocator) -> (sections: map[string]map[string]string) {
    sections = make(map[string]map[string]string, alloc)

    flush_section :: proc(sections: ^map[string]map[string]string, name: string, current: map[string]string) {
        if len(name) == 0 do return
        target, found := sections[name]
        if !found {
            sections[name] = current
            return
        }
        for key, value in current {
            target[key] = value
        }
        sections[name] = target
    }

    current_name: string
    current: map[string]string

    c: Consumer = { str = src }
    for c.at < len(c.str) {
        line := strings.trim_space(strip_line_comment(consume_line(&c)))
        if len(line) == 0 do continue

        if line[0] == '[' && line[len(line) - 1] == ']' {
            flush_section(&sections, current_name, current)
            current_name = strings.trim_space(line[1:len(line) - 1])
            current = make(map[string]string, alloc)
            continue
        }

        if len(current_name) == 0 do continue // stray content before the first section

        key, value := get_key_value(line)
        key = strings.trim_space(key)
        if len(key) == 0 do continue
        current[key] = strings.trim_space(value)
    }
    flush_section(&sections, current_name, current)

    return
}

// note(isak): parses an osu colour string "r,g,b" (or "r,g,b,a") into a Color. alpha defaults to
// opaque when absent. ok is false when fewer than three channels were present.
parse_osu_color :: proc(value: string) -> (result: Color, ok: bool) {
    result = {0, 0, 0, 0xFF}
    channel := 0
    from := 0
    for from < len(value) && channel < 4 {
        comma := strings.index_byte(value[from:], ',')
        part := comma >= 0 ? value[from:from + comma] : value[from:]
        v, parsed := strconv.parse_uint(strings.trim_space(part))
        if !parsed do return result, false
        result[channel] = u8(v)
        channel += 1
        if comma < 0 do break
        from += comma + 1
    }
    return result, channel >= 3
}
