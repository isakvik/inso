package notosu

import "base:runtime"
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
