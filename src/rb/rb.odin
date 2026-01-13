package rb

import "base:runtime"
import "core:math"
_ :: runtime


Ring_Buffer :: struct(T: typeid) {
    data: [dynamic]T,
    cursor: int,
    length: int,
}


DEFAULT_CAPACITY :: 16

init :: proc(using rb: ^$R/Ring_Buffer($T), capacity := DEFAULT_CAPACITY, allocator := context.allocator, loc := #caller_location) -> runtime.Allocator_Error {
    cap := math.next_power_of_two(capacity)
    clear(rb)
    err: runtime.Allocator_Error
    rb.data, err = make([dynamic]T, cap, allocator)
    return err
}

clear :: proc(using rb: ^$R/Ring_Buffer($T)) {
    rb.cursor += rb.length
    rb.length = 0
}


mask :: proc "contextless" (using rb: ^$R/Ring_Buffer($T)) -> int {
    return cap(rb.data) - 1
}

ptr_front :: proc(using rb: ^$R/Ring_Buffer($T)) -> ^T #no_bounds_check {
    return &data[cursor & mask(rb)]
}

ptr_back :: proc(using rb: ^$R/Ring_Buffer($T)) -> ^T #no_bounds_check {
    return &data[cursor + length & mask(rb)]
}

push_back :: proc(using rb: ^$R/Ring_Buffer($T), v: T) -> bool #no_bounds_check {
    data[(cursor + length) & mask(rb)] = v
    if length < cap(rb.data) {
        length += 1
        return true
    } else {
        cursor += 1
        return false
    }
}

push_front :: proc(using rb: ^$R/Ring_Buffer($T), v: T) -> bool #no_bounds_check {
    data[(cursor - 1) & mask(rb)] = v
    cursor -= 1
    if length < cap(rb.data) {
        length += 1
        return true
    } else {
        return false
    }
}

pop_back :: proc(using rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false

    v := data[(cursor + length - 1) & mask(rb)]
    length -= 1
    return v, true
}

pop_front :: proc(using rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false

    v := data[cursor & mask(rb)]
    length -= 1
    cursor += 1
    return v, true
}

peek_front :: proc(using rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false
    return data[cursor & mask(rb)], true
}

peek_back :: proc(using rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false
    return data[(cursor + length - 1) & mask(rb)], true
}

peek :: proc(using rb: ^$R/Ring_Buffer($T), i: int) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false
    return data[(cursor + i) & mask(rb)], true
}

slice_first :: proc(using rb: ^$R/Ring_Buffer($T)) -> []T #no_bounds_check {
    cap := cap(rb.data)
    return data[cursor&cap:min((cursor & cap) + length, cap)]
}

slice_second :: proc(using rb: ^$R/Ring_Buffer($T)) -> []T #no_bounds_check {
    cap := cap(rb.data)
    return data[:clamp((cursor & cap) + length - cap, 0, cursor&cap)]
}

linearize :: proc(using rb: ^$R/Ring_Buffer($T)) #no_bounds_check {
    cap := cap(rb.data)
    for i in 0..<length - (cursor & cap) - 1 {
        data[i], data[(cursor + i) & cap] = data[(cursor + i) & cap], data[i]
    }
    cursor = 0
}
