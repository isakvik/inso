package swap_buffer

import "base:builtin"

DEFAULT_CAPACITY :: 16

Swap_Buffer :: struct($T: typeid) {
    current, next: ^[dynamic]T,
    buffers: [2][dynamic]T,
    
    _current_to_resize_first: bool
}

init :: proc(m: ^$M/Swap_Buffer($T), capacity: int = DEFAULT_CAPACITY, allocator := context.allocator) {
    m.buffers[0] = make_dynamic_array_len_cap([dynamic]T, 0, capacity, allocator)
    m.buffers[1] = make_dynamic_array_len_cap([dynamic]T, 0, capacity, allocator)
    
    m.current = &m.buffers[0]
    m.next = &m.buffers[1]
}

destroy :: proc(m: ^$M/Swap_Buffer($T)) {
    delete(m.buffers[0])
    delete(m.buffers[1])
}

swap :: proc(m: ^$M/Swap_Buffer($T)) {
    m.current, m.next = m.next, m.current
    clear(m.next)
}

append :: proc(m: ^$M/Swap_Buffer($T), el: T) {
    if len(m.current) >= cap(m.current) {
        new_len := cap(m.current) * 2
        if m._current_to_resize_first {
            resize(&m.buffers[0], new_len)
            resize(&m.buffers[1], new_len)
        } else {
            resize(&m.buffers[1], new_len)
            resize(&m.buffers[0], new_len)
        }
        m._current_to_resize_first = !m._current_to_resize_first
    } 
    builtin.append(m.current, el)
}

/*
import "core:fmt"

test :: proc() {
    Data :: struct {
        i: int
    }
    
    swap_buf: Swap_Buffer(Data)
    init(&swap_buf, 16)
    for i in 0..<4 {
        builtin.append(swap_buf.current, Data{i})
    }
    
    fmt.println(swap_buf.current^)
    
    process :: proc(swap_buf: ^Swap_Buffer(Data)) {
        for data, i in swap_buf.current {
            if i != 0 { 
                builtin.append(swap_buf.next, data)
            }
        }
        swap(swap_buf)
    }
    
    for i in 0..<4 {
        process(&swap_buf)
        fmt.println(swap_buf.current^)
    }
}
*/
