package notosu

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"


//////////////////////////////////////////////////////
// note(isak): io api

read_entire_file :: proc(path: string, allocator := context.allocator) -> ([]u8, os.Error) {
    result: []u8
    err: os.Error
    for len(result) == 0 && err == 0 {
        result, err = os.read_entire_file_or_err(path, allocator)
    }
    return result, err
}

read_entire_file_to_string :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
    data, err := read_entire_file(path, allocator)
    return string(data), err
}


//////////////////////////////////////////////////////
// note(isak): memory api

arena_default_alignment :: 16

arena_push :: proc(arena: ^virtual.Arena, $T: typeid) -> (^T, virtual.Allocator_Error) {
    data, err := virtual.arena_alloc(arena, size_of(T), arena_default_alignment)
    assert(err == .None, "memory allocation error")
    return (^T)(raw_data(data)), err
}
