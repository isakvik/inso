package slotmap

import "base:builtin"

DEFAULT_CAPACITY :: 16

Slotmap :: struct($T: typeid) {
    handles:        [dynamic]Handle,
    values:         [dynamic]T,
    sparse_indices: [dynamic]Sparse_Index,
    next:           u32,
}

Handle :: struct {
    generation: u32,
    index:      u32,
}

Sparse_Index :: struct {
    generation:    u32,
    index_or_next: u32,
}

init :: proc(m: ^$M/Slotmap($T), capacity: int = DEFAULT_CAPACITY, allocator := context.allocator) {
    m.handles        = make_dynamic_array_len_cap([dynamic]Handle, 0, capacity, allocator)
    m.values         = make_dynamic_array_len_cap([dynamic]T, 0, capacity, allocator)
    m.sparse_indices = make_dynamic_array_len_cap([dynamic]Sparse_Index, 0, capacity, allocator)
    m.next = 0
}

destroy :: proc(m: ^$M/Slotmap($T)) {
    clear(m)
    delete(m.handles)
    delete(m.values)
    delete(m.sparse_indices)
}

clear :: proc(m: ^$M/Slotmap($T)) {
    builtin.clear(&m.handles)
    builtin.clear(&m.values)
    builtin.clear(&m.sparse_indices)
    m.next = 0
}

@(require_results)
has_handle :: proc(m: $M/Slotmap($T), h: Handle) -> bool {
    if h.index < u32(len(m.sparse_indices)) {
        return m.sparse_indices[h.index].generation == h.generation
    }
    return false
}

@(require_results)
get :: proc(m: ^$M/Slotmap($T), h: Handle) -> (^T, bool) {
    if h.index < u32(len(m.sparse_indices)) {
        entry := m.sparse_indices[h.index]
        if entry.generation == h.generation {
            return &m.values[entry.index_or_next], true
        }
    }
    return nil, false
}

@(require_results)
insert :: proc(m: ^$M/Slotmap($T), value: T) -> (handle: Handle) {
    if m.next < u32(len(m.sparse_indices)) {
        entry := &m.sparse_indices[m.next]
        assert(entry.generation < max(u32), "Generation sparse indices overflow")

        entry.generation += 1
        handle = Handle{
            generation = entry.generation,
            index = m.next,
        }
        m.next = entry.index_or_next
        entry.index_or_next = u32(len(m.handles))
        append(&m.handles, handle)
        append(&m.values,  value)
    } else {
        assert(m.next < max(u32), "Index sparse indices overflow")

        handle = Handle{
            index = u32(len(m.sparse_indices)),
        }
        append(&m.sparse_indices, Sparse_Index{
            index_or_next = u32(len(m.handles)),
        })
        append(&m.handles, handle)
        append(&m.values,  value)
        m.next += 1
    }
    return
}

remove :: proc(m: ^$M/Slotmap($T), h: Handle) -> (value: Maybe(T)) {
    if h.index < u32(len(m.sparse_indices)) {
        entry := &m.sparse_indices[h.index]
        if entry.generation != h.generation {
            return
        }
        index := entry.index_or_next
        entry.generation += 1
        entry.index_or_next = m.next
        m.next = h.index
        value = m.values[index]
        unordered_remove(&m.handles, int(index))
        unordered_remove(&m.values,  int(index))
        if index < u32(len(m.handles)) {
            m.sparse_indices[m.handles[index].index].index_or_next = index
        }
    }
    return
}
