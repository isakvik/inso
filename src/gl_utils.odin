package inso

import "core:slice"
import "core:strings"
import "core:fmt"
import "core:time"

import gl "vendor:OpenGL"


//////////////////////////////////////////////////////
// note(isak): gl capability queries

gl_has_extension :: proc(name: cstring) -> bool {
    num_extensions: i32
    gl.GetIntegerv(gl.NUM_EXTENSIONS, &num_extensions)
    for i in 0..<num_extensions {
        if gl.GetStringi(gl.EXTENSIONS, u32(i)) == name {
            return true
        }
    }
    return false
}

gl_vendor_is_intel :: proc() -> bool {
    vendor := gl.GetString(gl.VENDOR)
    renderer := gl.GetString(gl.RENDERER)
    return strings.contains(string(vendor), "Intel") ||
           strings.contains(string(renderer), "Intel")
}

//////////////////////////////////////////////////////
// note(isak): buffer object, useful for proxies to GPU buffers

Buffer :: struct(T: typeid) {
    count: i32,
    data: []T,
    size: i32
}

buffer_init :: proc(N: i32, data: []$T) -> Buffer(T) {
    result: Buffer(T) = {
        count = 0,
        data = data,
        size = N
    }
    return result
}

buffer_push :: proc(buf: ^Buffer($T), t: T) {
    assert(buf.count + 1 <= buf.size)
    buf.data[buf.count] = t
    buf.count += 1
}

buffer_push_slice :: proc(buf: ^Buffer($T), t_slice: []T) {
    assert(buf.count + len(t_slice) <= buf.size)
    for i in 0..<len(t_slice) {
        buf.data[buf.count + i] = t[i]
    }
    buf.count += len(t_slice)
}

buffer_clear :: proc(buf: ^Buffer($T)) {
    buf.count = 0
}

//////////////////////////////////////////////////////
// note(isak): uniform buffer object

GL_Uniform_Buffer :: struct(T: typeid) {
    id: u32,
    count: int,
    size: int
}

ubo_init :: proc($T: typeid, count: int) -> GL_Uniform_Buffer(T) {
    result: GL_Uniform_Buffer(T)
    gl.CreateBuffers(1, &result.id)
    
    result.count = count
    result.size = count * size_of(T)
    
    gl.NamedBufferStorage(result.id, result.size, nil, gl.DYNAMIC_STORAGE_BIT)
    return result
}
    
ubo_bind :: proc(buf: ^GL_Uniform_Buffer($T), bindIndex: u32) {
    gl.BindBufferBase(
        gl.UNIFORM_BUFFER,
        bindIndex,
        buf.id)
}

ubo_cleanup :: proc(buf: ^GL_Uniform_Buffer($T)) {
    gl.DeleteBuffers(1, &buf.id)
    buf.id = 0
}

//////////////////////////////////////////////////////
// note(isak): persistently mapped single buffer object

GL_Buffer :: struct(T: typeid) {
    id: u32,
    count: int,
    size: int,
    data: []T,
    sync: gl.sync_t,

    wait_count: u64 // note(isak): just unused debug info
}

sbo_init_ptr :: proc(buf: ^GL_Buffer($T), count: int) {
    gl.CreateBuffers(1, &buf.id)
    
    buf.count = count
    buf.size = count * size_of(T)
    
    flags := u32(gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
    create_flags := flags | gl.DYNAMIC_STORAGE_BIT

    gl.NamedBufferStorage(buf.id, buf.size, nil, create_flags)
    mapped_ptr := gl.MapNamedBufferRange(buf.id, 0, buf.size, flags)
    buf.data = slice.from_ptr(cast(^T) mapped_ptr, count)
}

sbo_init :: proc($T: typeid, count: int) -> GL_Buffer(T) {
    result: GL_Buffer(T)
    sbo_init_ptr(&result, count)
    return result
}

sbo_bind :: proc(buf: ^GL_Buffer($T), bindIndex: u32) {
    gl.BindBufferRange(
        gl.SHADER_STORAGE_BUFFER,
        bindIndex,
        buf.id,
        0,
        buf.size)
}

sbo_wait :: proc(buf: ^GL_Buffer($T)) {
    sync := buf.sync
    if sync != nil {
        for true {
            waitReturn := gl.ClientWaitSync(sync, gl.SYNC_FLUSH_COMMANDS_BIT, 0)
            if (waitReturn == gl.ALREADY_SIGNALED ||
                waitReturn == gl.CONDITION_SATISFIED ||
                waitReturn == gl.WAIT_FAILED) {
                break
            }
        }
    }
}

sbo_lock :: proc(buf: ^GL_Buffer($T)) {
    if buf.sync > nil {
        gl.DeleteSync(buf.sync)
    }
    buf.sync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
}


sbo_cleanup :: proc(buf: ^GL_Buffer($T)) {
    gl.DeleteBuffers(1, &buf.id)
    buf.id = 0
}

//////////////////////////////////////////////////////
// note(isak): persistently mapped triple buffer object

_pbo_multiple_count :: 3

GL_Triple_Buffer :: struct(T: typeid) {
    id: u32,
    count: int,
    size: int,

    current_index: u8,
    buffers: [_pbo_multiple_count]Synced_Buffer(T),
}

Synced_Buffer :: struct(T: typeid) {
    data: []T,
    offset: int,
    sync: gl.sync_t,

    wait_count: u64 // note(isak): just unused debug info
}


tbo_init_ptr :: proc(buf: ^GL_Triple_Buffer($T), count: int) {
    gl.CreateBuffers(1, &buf.id)
    
    buf.count = 0
    buf.size = count * size_of(T)
    flags := u32(gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
    gl.NamedBufferStorage(buf.id, buf.size * _pbo_multiple_count, nil, flags)
    mapped_ptr := gl.MapNamedBufferRange(buf.id, 0, buf.size * _pbo_multiple_count, flags)

    mapped_slices := slice.from_ptr(cast(^T) mapped_ptr, count * _pbo_multiple_count)
    for i in 0..<_pbo_multiple_count {
        buf.buffers[i] = { 
            data = mapped_slices[count * i:], // might have some alignment issues on some types?
            offset = buf.size * i,
            sync = nil
        }
    }
}

tbo_init :: proc($T: typeid, count: int) -> GL_Triple_Buffer(T) {
    result: GL_Triple_Buffer(T)
    tbo_init_ptr(&result, count)
    return result
}

tbo_wait :: proc(buf: ^GL_Triple_Buffer($T)) -> (waited_ns: u64) {
    synced := &buf.buffers[buf.current_index]
    if synced.sync == nil do return 0

    // note(isak): fast path - with 3 buffers in flight the fence is usually long signaled
    result := gl.ClientWaitSync(synced.sync, gl.SYNC_FLUSH_COMMANDS_BIT, 0)
    if result != gl.TIMEOUT_EXPIRED do return 0

    // note(isak): the GPU still owns this buffer; block in 1ms slices instead of spinning
    start := time.tick_now()
    for result == gl.TIMEOUT_EXPIRED {
        result = gl.ClientWaitSync(synced.sync, 0, 1_000_000)
    }
    synced.wait_count += 1
    return u64(time.tick_since(start))
}

tbo_lock :: proc(buf: ^GL_Triple_Buffer($T)) {
    if buf.buffers[buf.current_index].sync > nil {
        gl.DeleteSync(buf.buffers[buf.current_index].sync)
    }
    buf.buffers[buf.current_index].sync = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
}

tbo_get_current_data :: proc(buf: ^GL_Triple_Buffer($T)) -> []T {
    return buf.buffers[buf.current_index].data
}

tbo_bind :: proc(buf: ^GL_Triple_Buffer($T), bindIndex: u32) {
    gl.BindBufferRange(
        gl.SHADER_STORAGE_BUFFER,
        bindIndex,
        buf.id,
        buf.buffers[buf.current_index].offset,
        buf.size)
}

tbo_advance :: proc(buf: ^GL_Triple_Buffer($T)) {
    buf.current_index = (buf.current_index + 1) % _pbo_multiple_count
    buf.count = 0
}

tbo_advance_and_get :: proc(buf: ^GL_Triple_Buffer($T)) -> (data: []T, waited_ns: u64) {
    tbo_advance(buf)
    waited_ns = tbo_wait(buf)
    return tbo_get_current_data(buf), waited_ns
}

tbo_cleanup :: proc(buf: ^GL_Triple_Buffer($T)) {
    gl.UnmapNamedBuffer(buf.id)
    gl.DeleteBuffers(1, &buf.id)
    buf.id = 0
}

//////////////////////////////////////////////////////
// note(isak): framebuffer object

GL_Framebuffer :: struct {
    id: u32,
    color_format: u32,
    color_filter: Texture_Filter,
    color_textures: [4]u32,
    color_texture_handles: [4]Texture_Handle,
    color_texture_count: u32,

    depth_texture: u32,
    depth_texture_handle: Texture_Handle,
    depth_texture_count: u32,

    w, h: i32,
}

fbo_init :: proc(color_texture_count, depth_texture_count: u32, w, h: i32, color_format: u32,
                 color_filter: Texture_Filter = .LINEAR) -> GL_Framebuffer {
    result := GL_Framebuffer{
        color_texture_count = color_texture_count,
        depth_texture_count = depth_texture_count,
        w = w,
        h = h,
        color_format = color_format,
        color_filter = color_filter
    }
    gl.CreateFramebuffers(1, &result.id)

    assert(color_texture_count <= 4)
    for i in 0..<color_texture_count {
        t := texture_create(.REPEAT, color_filter)
        result.color_textures[i] = t
        gl.TextureStorage3D(t, 1, color_format, w, h, 1)
        gl.NamedFramebufferTextureLayer(result.id, gl.COLOR_ATTACHMENT0 + i, t, 0, 0)
        if window.bindless_supported {
            result.color_texture_handles[i] = gl.GetTextureHandleARB(t)
        }
    }

    assert(depth_texture_count <= 1)
    if depth_texture_count > 0 {
        t := texture_create(.REPEAT)
        result.depth_texture = t
        gl.TextureStorage3D(t, 1, gl.DEPTH32F_STENCIL8, w, h, 1)
        gl.NamedFramebufferTextureLayer(result.id, gl.DEPTH_ATTACHMENT, t, 0, 0)
        if window.bindless_supported {
            result.depth_texture_handle = gl.GetTextureHandleARB(t)
        }
    }

    draw_buffers := [4]u32 { gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1, gl.COLOR_ATTACHMENT2, gl.COLOR_ATTACHMENT3 }
    gl.NamedFramebufferDrawBuffers(result.id, i32(color_texture_count), raw_data(draw_buffers[:]))

    success := gl.CheckNamedFramebufferStatus(result.id, gl.FRAMEBUFFER)
    assert(success == gl.FRAMEBUFFER_COMPLETE)
    assert(result.id != 0)

    fbo_clear(&result)
    return result
}

fbo_clear :: proc(fb: ^GL_Framebuffer) {
    for i in 0..<fb.color_texture_count {
        gl.ClearTexImage(fb.color_textures[i], 0, gl.RGBA, gl.FLOAT, nil)
    }
    if fb.depth_texture_count > 0 {
        depth_stencil := struct #packed { depth: f32, stencil: u32 }{ 1.0, 0 }
        gl.ClearTexImage(fb.depth_texture, 0, gl.DEPTH_STENCIL, gl.FLOAT_32_UNSIGNED_INT_24_8_REV, &depth_stencil)
    }
}

fbo_reinit :: proc(fb: ^GL_Framebuffer, new_w, new_h: i32) {
    if fb.id > 0 {
        fbo_cleanup(fb)
    }
    fb^ = fbo_init(fb.color_texture_count, fb.depth_texture_count, new_w, new_h, fb.color_format, fb.color_filter)
}

fbo_cleanup :: proc(fb: ^GL_Framebuffer) {
    assert(!window.textures_resident, "fbo_cleanup: free a framebuffer inside a cleanup/prepare_textures_for_rendering bracket")
    gl.DeleteFramebuffers(1, &fb.id)
    gl.DeleteTextures(i32(fb.color_texture_count), raw_data(fb.color_textures[:]))
    gl.DeleteTextures(i32(fb.depth_texture_count), &fb.depth_texture)
    fb.id = 0
}

fbo_bind :: proc(read, write: u32) {
    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, read)
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, write)
}

fbo_bind_read :: proc(fb: ^GL_Framebuffer) {
    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, fb.id)
}

fbo_bind_write :: proc(fb: ^GL_Framebuffer) {
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, fb.id)
}

fbo_bind_default :: proc() {
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}
