package notosu

import "core:slice"

import gl "vendor:OpenGL"

// persistent triple buffer object

_pbo_multiple_count :: 3

Persistent_Buffer :: struct(T: typeid) {
    id: u32,
    count: int,
    size: int,

    current_index: u8,
    buffers: [_pbo_multiple_count]Synced_Buffer(T),
}

Synced_Buffer :: struct(T: typeid) {
    data: []T,
    offset: int,
    sync: gl.sync_t
}


pbo_init :: proc($T: typeid, count: int) -> Persistent_Buffer(T) {
    result: Persistent_Buffer(T)
    gl.CreateBuffers(1, &result.id)

    result.size = count * size_of(T)
    flags := u32(gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
    gl.NamedBufferStorage(result.id, result.size * _pbo_multiple_count, nil, flags)
    mapped_ptr := gl.MapNamedBufferRange(result.id, 0, result.size * _pbo_multiple_count, flags)

    result.count = count
    mapped_slices := slice.from_ptr(cast(^T) mapped_ptr, count * _pbo_multiple_count)
    for i in 0..<_pbo_multiple_count {
        result.buffers[i] = { 
            data = mapped_slices[count * i:], // might have some alignment issues on some types
            offset = result.size * i,
            sync = nil
        }
    }
    return result
}

pbo_lock :: proc(buf: ^Persistent_Buffer($T)) {
    sync := buf.buffers[buf.current_index].sync
    if sync > nil {
        for true {
            waitReturn := gl.ClientWaitSync(sync, gl.SYNC_FLUSH_COMMANDS_BIT, 0);
            if (waitReturn == gl.ALREADY_SIGNALED ||
                waitReturn == gl.CONDITION_SATISFIED ||
                waitReturn == gl.WAIT_FAILED) {
                break;
            }
        }
    }
}

pbo_unlock :: proc(buf: ^Persistent_Buffer($T)) {
    sync := buf.buffers[buf.current_index].sync
    if sync > nil {
        gl.DeleteSync(sync)
    }
    sync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
}

pbo_get_current :: proc(buf: ^Persistent_Buffer($T)) -> []T {
    return buf.buffers[buf.current_index].data
}

pbo_bind :: proc(buf: ^Persistent_Buffer($T), bindIndex: u32) {
    gl.BindBufferRange(
        gl.SHADER_STORAGE_BUFFER,
        bindIndex,
        buf.id,
        buf.buffers[buf.current_index].offset,
        buf.size)
}

pbo_increment_index :: proc(buf: ^Persistent_Buffer($T)) {
    buf.current_index = (buf.current_index + 1) % _pbo_multiple_count
}

pbo_cleanup :: proc(buf: ^Persistent_Buffer($T)) {
    gl.UnmapNamedBuffer(buf.id)
    gl.DeleteBuffers(1, &buf.id);
}
