package rb

import "base:runtime"
_ :: runtime


Ring_Buffer :: struct(T: typeid) {
    data: [dynamic]T,
    cursor: int,
    length: int,
}


DEFAULT_CAPACITY :: 16

init :: proc(using rb: ^$R/Ring_Buffer($T), capacity := DEFAULT_CAPACITY, allocator := context.allocator, loc := #caller_location) -> runtime.Allocator_Error {
    clear(rb)
    err: runtime.Allocator_Error
    rb.data, err = make([dynamic]T, capacity, allocator)
    return err
}

clear :: proc(using rb: ^$R/Ring_Buffer($T)) {
    rb.cursor += rb.length
    rb.length = 0
}


ptr_front :: proc(using rb: ^$R/Ring_Buffer($T)) -> ^T #no_bounds_check {
    return &data[cursor %% cap(rb.data)]
}

ptr_back :: proc(using rb: ^$R/Ring_Buffer($T)) -> ^T #no_bounds_check {
    return &data[cursor + length %% cap(rb.data)]
}

push_back :: proc(using rb: ^$R/Ring_Buffer($T), v: T) -> bool #no_bounds_check {
    data[(cursor + length) %% cap(rb.data)] = v
    if length < cap(rb.data) {
        length += 1
        return true
    } else {
        cursor += 1
        return false
    }
}

push_front :: proc(using rb: ^$R/Ring_Buffer($T), v: T) -> bool #no_bounds_check {
    data[(cursor - 1) %% cap(rb.data)] = v
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

    v := data[(cursor + length - 1) %% cap(rb.data)]
    length -= 1
    return v, true
}

pop_front :: proc(using rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false

    v := data[cursor %% cap(rb.data)]
    length -= 1
    cursor += 1
    return v, true
}

peek_front :: proc(using rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false
    return data[cursor %% cap(rb.data)], true
}

peek_back :: proc(using rb: ^$R/Ring_Buffer($T)) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false
    return data[(cursor + length - 1) %% cap(rb.data)], true
}

peek :: proc(using rb: ^$R/Ring_Buffer($T), i: int) -> (T, bool) #no_bounds_check {
    if length == 0 do return T{}, false
    return data[(cursor + i) %% cap(rb.data)], true
}

slice_first :: proc(using rb: ^$R/Ring_Buffer($T)) -> []T #no_bounds_check {
    cap := cap(rb.data)
    return data[cursor%%cap:min((cursor %% cap) + length, cap)]
}

slice_second :: proc(using rb: ^$R/Ring_Buffer($T)) -> []T #no_bounds_check {
    cap := cap(rb.data)
    return data[:clamp((cursor %% cap) + length - cap, 0, cursor%%cap)]
}

linearize :: proc(using rb: ^$R/Ring_Buffer($T)) #no_bounds_check {
    cap := cap(rb.data)
    for i in 0..<length - (cursor %% cap) - 1 {
        data[i], data[(cursor + i) %% cap] = data[(cursor + i) %% cap], data[i]
    }
    cursor = 0
}
