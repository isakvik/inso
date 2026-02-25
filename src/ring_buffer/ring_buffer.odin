package ring_buffer

import "base:runtime"
import "core:math"
_ :: runtime

Ring_Buffer :: struct(T: typeid) {
    data: [dynamic]T,
    cursor: int,
    len: int,
}


DEFAULT_CAPACITY :: 16

init :: proc(rb: ^$R/Ring_Buffer($T), capacity := DEFAULT_CAPACITY, allocator := context.allocator, loc := #caller_location) -> runtime.Allocator_Error {
    cap := math.next_power_of_two(capacity)
    clear(rb)
    err: runtime.Allocator_Error
    rb.data, err = make([dynamic]T, cap, allocator)
    return err
}

destroy :: proc(rb: ^$R/Ring_Buffer($T)) {
    clear(rb)
    delete(rb.data)
}

clear :: proc(rb: ^$R/Ring_Buffer($T)) {
    rb.cursor += rb.len
    rb.len = 0
}


// note(isak): beware the high precedence of the & operator
mask :: proc "contextless" (rb: ^$R/Ring_Buffer($T), #any_int n: int) -> int {
    return n & (cap(rb.data) - 1)
}

at :: proc "contextless" (rb: ^$R/Ring_Buffer($T), #any_int n: int) -> ^T {
    return &rb.data[mask(rb, n)]
}

ptr_front :: proc(rb: ^$R/Ring_Buffer($T)) -> ^T #no_bounds_check {
    return at(rb, rb.cursor)
}

ptr_back :: proc(rb: ^$R/Ring_Buffer($T)) -> ^T #no_bounds_check {
    return at(rb, rb.cursor + rb.len)
}

push_back :: proc(rb: ^$R/Ring_Buffer($T), v: T) -> bool #no_bounds_check {
    at(rb, rb.cursor + rb.len)^ = v
    if rb.len < cap(rb.data) {
        rb.len += 1
        return true
    } else {
        rb.cursor += 1
        return false
    }
}

push_front :: proc(rb: ^$R/Ring_Buffer($T), v: T) -> bool #no_bounds_check {
    at(rb, rb.cursor - 1)^ = v
    rb.cursor -= 1
    if len < cap(rb.data) {
        len += 1
        return true
    } else {
        return false
    }
}

pop_back :: proc(rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if rb.len == 0 do return T{}, false

    v := at(rb, rb.cursor + rb.len - 1)^
    rb.len -= 1
    return v, true
}

pop_front :: proc(rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if rb.len == 0 do return T{}, false

    v := at(rb, rb.cursor)^
    rb.len -= 1
    rb.cursor += 1
    return v, true
}

peek_front :: proc(rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if rb.len == 0 do return T{}, false
    return at(rb, rb.cursor)^, true
}

peek_back :: proc(rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if rb.len == 0 do return T{}, false
    return at(rb, rb.cursor + rb.len - 1)^, true
}

peek :: proc(rb: ^$R/Ring_Buffer($T), i: int) -> (T, bool) #no_bounds_check {
    if rb.len == 0 do return T{}, false
    return at(rb, rb.cursor + i)^, true
}

slice_first :: proc(rb: ^$R/Ring_Buffer($T)) -> []T #no_bounds_check {
    cap := cap(rb.data)
    return data[rb.cursor&cap:min((rb.cursor & cap) + rb.len, cap)]
}

slice_second :: proc(rb: ^$R/Ring_Buffer($T)) -> []T #no_bounds_check {
    cap := cap(rb.data)
    return data[:clamp((rb.cursor & cap) + rb.len - cap, 0, rb.cursor&cap)]
}

linearize :: proc(rb: ^$R/Ring_Buffer($T)) #no_bounds_check {
    cap := cap(rb.data)
    for i in 0..<rb.len - (rb.cursor & cap) - 1 {
        data[i], data[(rb.cursor + i) & cap] = data[(rb.cursor + i) & cap], data[i]
    }
    cursor = 0
}
