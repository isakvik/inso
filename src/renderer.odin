package notosu

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import os "core:os/os2"
import "core:slice"
import "core:strings"
import "core:container/queue"

import gl "vendor:OpenGL"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"


batch_max_vertices :: 64*1024
max_texture_handles :: 1024
//max_slider_draw_commands :: 1024



Quad_Vertex :: struct {
    pos:   vec2,
    uv:    vec2,
    color: vec4,
    tex_index: u32,
    __padding: [3]u32
}

Slider_Vertex :: struct {
    pos: vec3,
    __padding: u32,
}


Transform :: mat4

Geometry_Buffer :: struct(T: typeid) {
    vertices: Buffer(T),
    indices: Buffer(u32),
}

Dynamic_Geometry_Store :: struct(T: typeid) {
    vertex_buffer: GL_Triple_Buffer(T),
    index_buffer: GL_Triple_Buffer(u32),
}

Static_Geometry_Store :: struct(T: typeid) {
    vertex_buffer: GL_Buffer(T),
    index_buffer: GL_Buffer(u32),
}

Renderer :: struct {
    quad_geometry: Geometry_Buffer(Quad_Vertex),
    slider_instances: Buffer(vec2),
    
    text_geometry: Buffer(Glyph_Quad),
    
    circle_geometry: Buffer(Slider_Vertex),

    transform_queue: queue.Queue(Transform),
    default_transform: Transform,

    command_queue: queue.Queue(u8),

    current_draw: ^Command_Draw,
    null_draw: Command_Draw,

    trace_frame: bool
}


Texture_Handle :: u64

Texture :: struct {
    path: string,
    w, h: i32,
    format, internal_format: u32,
    tex_id: u32, // note(isak): gl assigned texture id
    tex_handle: Texture_Handle, // note(isak): bindless handle
}

Layout_Anchor :: enum {
    TOP_LEFT,
    TOP_MIDDLE,
    TOP_RIGHT,
    MIDDLE_LEFT,
    CENTER,
    MIDDLE_RIGHT,
    BOTTOM_LEFT,
    BOTTOM_MIDDLE,
    BOTTOM_RIGHT,
}

Rect :: struct {
    x, y, w, h: f32,
}


rect_to_array :: proc(r: Rect) -> [4]f32 {
    return {r.x, r.y, r.w, r.h}
}

max_active_texture_resource_size :: 128 * 1024 * 1024

unit_circle_vertex_count :: 30

//////////////////////////////////////////////////////
// note(isak): resource api

renderer_init :: proc() {
    renderer := &window.renderer
    renderer.current_draw = &renderer.null_draw
    renderer.default_transform = transform_from_bounds({0, 0, 1, 1}, window.aspect_ratio)

    sg.setup({
        environment = {
            defaults = {
                sample_count = 4,
                color_format = sg.Pixel_Format.RGBA8,
                depth_format = sg.Pixel_Format.DEPTH_STENCIL,
            },
        },
        logger = {func = slog.func},
    })

    err: Shader_Error
    window.shaders[.QUAD], err = init_shader(quad_vs_path, quad_fs_path, quad_uniform_desc())
    assert(err == .NONE)
    window.pipelines[.QUAD] = sg.make_pipeline(quad_pipeline())

    window.shaders[.SLIDER], err = init_shader(slider_vs_path, slider_fs_path, slider_uniform_desc())
    assert(err == .NONE)
    window.pipelines[.SLIDER] = sg.make_pipeline(slider_pipeline())
    
    window.shaders[.TEXT], err = init_shader(text_vs_path, text_fs_path, text_uniform_desc())
    assert(err == .NONE)
    window.pipelines[.TEXT] = sg.make_pipeline(text_pipeline())

    window.framebuffers[.SLIDERS] = fbo_init(1, 1, i32(window.rect.w), i32(window.rect.h), gl.RGBA8)
    

    window.quad_store.vertex_buffer = tbo_init(Quad_Vertex, batch_max_vertices)
    window.quad_store.index_buffer = tbo_init(u32, batch_max_vertices * 2)

    window.slider_instance_store = tbo_init(vec2, batch_max_vertices)

    window.text_store = tbo_init(Glyph_Quad, batch_max_vertices)
    
    window.fullscreen_store.vertex_buffer = sbo_init(Quad_Vertex, 4)
    window.fullscreen_store.index_buffer = sbo_init(u32, 6)

    window.texture_buffer = sbo_init(u64, max_texture_handles)
    
    window.transform_buffer = ubo_init(Transform, 1)


    window.pass_action = { 
        colors = {
            0 = { load_action = .CLEAR, clear_value = { 0.15, 0.10, 0.23, 1 } }, 
        }
    }

    window.swapchain = sg.Swapchain{
        width =  i32(window.rect.w),
        height = i32(window.rect.h),
        sample_count = 4,
        color_format = .RGBA8,
        //depth_format = .DEPTH_STENCIL,
        gl = {0} // default framebuffer
    }

    // generated textures

    white_pixel: []u32 = {0xFFFFFFFF}
    window.white_texture = texture_from_data(1, 1, raw_data(white_pixel))

    profiler_pixels := new([profiler_w * profiler_h]u32)
    window.profiler_texture = texture_from_data(profiler_w, profiler_h, raw_data(profiler_pixels))

    //

    circle_buffer_vertex_count := unit_circle_vertex_count + 2
    window.circle_geo_buffer = sbo_init(Slider_Vertex, circle_buffer_vertex_count)
    renderer.circle_geometry = 
        buffer_init(i32(circle_buffer_vertex_count), window.circle_geo_buffer.data)

    populate_slider_circle_vertices(&renderer.circle_geometry)
    
    renderer.slider_instances.size = batch_max_vertices

    //

    fullscreen_geometry := Geometry_Buffer(Quad_Vertex) {
        vertices = buffer_init(batch_max_vertices, window.fullscreen_store.vertex_buffer.data),
        indices = buffer_init(batch_max_vertices * 2, window.fullscreen_store.index_buffer.data)
    }
    push_rect(&fullscreen_geometry, 
        {0,0,1,1}, {1,1,1,0.5}, reserved_texture(.SLIDER_FRAMEBUFFER))
    
    //
    
    renderer.text_geometry.size = batch_max_vertices
    
    window.current_transform = renderer.default_transform
    commit_transform(renderer.default_transform)

    alloc_err: runtime.Allocator_Error
    alloc_err = queue.init(&renderer.command_queue, megabytes(1), memory.command_buffer_allocator)
    assert(alloc_err == .None)
    if alloc_err != .None {
        fmt.println("command queue init error:", alloc_err)
    }
}

renderer_cleanup :: proc() {
    tbo_cleanup(&window.quad_store.vertex_buffer)
    tbo_cleanup(&window.quad_store.index_buffer)
    tbo_cleanup(&window.slider_instance_store)
    tbo_cleanup(&window.text_store)
    
    sbo_cleanup(&window.fullscreen_store.vertex_buffer)
    sbo_cleanup(&window.fullscreen_store.index_buffer)
    sbo_cleanup(&window.circle_geo_buffer)
    sbo_cleanup(&window.texture_buffer)
    ubo_cleanup(&window.transform_buffer)
}


//////////////////////////////////////////////////////
// note(isak): shader api (program api)

Shader_Error :: enum {
    NONE,
    READ_ERROR,
    PATH_ERROR,
    COMPILE_ERROR,
}

Shader :: struct {
    shader: sg.Shader,
    vs_path, fs_path: string,
    uniform_desc: [8]sg.Shader_Uniform_Block
}

init_shader :: proc(vs_path, fs_path: string, uniform_desc: [8]sg.Shader_Uniform_Block) -> (Shader, Shader_Error) {
    vs_filedata, vs_err := read_entire_file(vs_path)
    if vs_err != os.ERROR_NONE {
        fmt.printfln("loading vert shader file '{}' failed: {}", vs_path, vs_err)
        return {}, .READ_ERROR
    }
    fs_filedata, fs_err := read_entire_file(fs_path)
    if fs_err != os.ERROR_NONE {
        fmt.printfln("loading frag shader file '{}' failed: {}", fs_path, fs_err)
        return {}, .READ_ERROR
    }

    if (vs_err != os.ERROR_NONE) || (fs_err != os.ERROR_NONE) {
        return {}, .PATH_ERROR
    }

    temp_shader := sg.make_shader(
        sg.Shader_Desc {
            vertex_func = {source = strings.unsafe_string_to_cstring(string(vs_filedata))},
            fragment_func = {source = strings.unsafe_string_to_cstring(string(fs_filedata))},
            uniform_blocks = uniform_desc
        },
    )

    if sg.query_shader_state(temp_shader) == sg.Resource_State.VALID {
        return {
            shader = temp_shader,
            vs_path = vs_path,
            fs_path = fs_path,
            uniform_desc = uniform_desc
        }, .NONE
    }
    sg.destroy_shader(temp_shader)
    return {}, .COMPILE_ERROR
}

reinit_shader :: proc(shader: ^Shader) -> Shader_Error {
    new_shader, err := init_shader(shader.vs_path, shader.fs_path, shader.uniform_desc)
    if err != .NONE {
        assert(err == .COMPILE_ERROR)
        fmt.println("Shader compile errors found. Paths:", shader.vs_path, shader.fs_path)
        return err
    }
    sg.destroy_shader(shader.shader)
    shader^ = new_shader
    return err
}

reinit_pipeline :: proc(pipeline: ^sg.Pipeline, pipeline_desc: sg.Pipeline_Desc) {
    sg.destroy_pipeline(pipeline^)
    pipeline^ = sg.make_pipeline(pipeline_desc)
}

//////////////////////////////////////////////////////
// note(isak): command queue api

Command_Type :: enum(u8) {
    PUSH_TRANSFORM,
    POP_TRANSFORM,
    SET_MODE,
    CLEAR,
    DRAW,
    DRAW_SLIDER,
    BIND_PIPELINE,
    BIND_FRAMEBUFFER,
    BIND_SSBO,
}

Command_Mode_Type :: enum(u8) {
    QUAD_UV,
    TEXT,
}

Command_Header :: struct {
    command_type: Command_Type
}

Command_Push_Transform :: struct {
    transform: Transform
}

Command_Set_Mode :: struct {
    mode: Command_Mode_Type
}

Command_Draw :: struct {
    index_offset: u32,
    index_count: i32,
    base_instance: u32,
    instance_count: i32
}

Command_Draw_Slider :: struct {
    base_instance: u32,
    instance_count: i32
}

Command_Bind_Pipeline :: struct {
    pipeline: Pipeline_ID
}

Command_Bind_Framebuffer :: struct {
    read, write: Framebuffer_ID
}

Command_Bind_SSBO :: struct {
    id, slot: u32,
    size, offset: int
}

command_push_clear             :: proc() -> bool { return _command_push_header(.CLEAR) }
command_push_push_transform    :: proc(cmd: Command_Push_Transform) -> bool { return _command_push(cmd, .PUSH_TRANSFORM) }
command_push_pop_transform     :: proc() -> bool { return _command_push_header(.POP_TRANSFORM) }
command_push_set_mode          :: proc(cmd: Command_Set_Mode) -> bool { return _command_push(cmd, .SET_MODE) }
command_push_draw              :: proc(cmd: Command_Draw) -> bool { return _command_push(cmd, .DRAW) }
command_push_draw_slider       :: proc(cmd: Command_Draw_Slider) -> bool { return _command_push(cmd, .DRAW_SLIDER) }
command_push_bind_pipeline     :: proc(cmd: Command_Bind_Pipeline) -> bool { return _command_push(cmd, .BIND_PIPELINE) }
command_push_bind_framebuffer  :: proc(cmd: Command_Bind_Framebuffer) -> bool { return _command_push(cmd, .BIND_FRAMEBUFFER) }


command_push_bind_sbo :: proc(sbo: ^GL_Buffer($T), bind_index: u32) -> bool {
    cmd := Command_Bind_SSBO{
        id = sbo.id,
        slot = bind_index,
        size = sbo.size
    }
    return _command_push(cmd, .BIND_SSBO) 
}

command_push_bind_tbo :: proc(tbo: ^GL_Triple_Buffer($T), bind_index: u32) -> bool {
    cmd := Command_Bind_SSBO{
        id = tbo.id,
        slot = bind_index,
        size = tbo.size,
        offset = tbo.size * tbo.current_index
    }
    return _command_push(cmd, .BIND_SSBO) 
}


_command_push_header :: proc(type: Command_Type) -> bool {
    ok, err := queue.push_back(&window.renderer.command_queue, u8(type))
    assert(err == .None)
    return ok
}

_command_push :: proc(cmd: $T, type: Command_Type) -> bool {
    cmd := cmd
    ok := _command_push_header(type)
    if ok {
        err: runtime.Allocator_Error
        cmd_data: []u8 = slice.from_ptr((^u8)(&cmd), size_of(T))
        ok, err = queue.push_back_elems(&window.renderer.command_queue, ..cmd_data)
        assert(err == .None)
    }
    assert(ok)
    return ok
}


command_pop_clear             :: proc() {

}

command_pop_push_transform    :: proc() {

}

command_pop_pop_transform     :: proc() {

}

command_pop_set_mode          :: proc() {

}

command_pop_draw              :: proc() {

}

command_pop_draw_slider       :: proc() {

}

command_pop_bind_pipeline     :: proc() {

}

command_pop_bind_framebuffer  :: proc() {

}


///////////////////////////////////////////////////////////////////////////
// note(isak): draw api - PS: we use our nice global window.renderer here to make the api easier

/*
    note(isak): 2D transforms are tricky - we use them to define the coordinate system that spans the
    window without distortion. we do these calculations on the GPU using the bounds rect and the 
    aspect ratio of the window, which are uploaded using commit_transform.

    a rect of [0,0,1,1] means the points (0,0) and (1,1) would touch opposite corners of a square area
    placed in the middle of the window (note: only when the aspect ratio <= 1). a rect of 
    [0, 0, window_width, window_height ] is used with an aspect_ratio of 1 to create a pixel-perfect
    screen transform, such that w=1, h=1 corresponds to one pixel.
*/
commit_transform :: proc(transform: Transform) {
    transform := transform
    gl.NamedBufferSubData(window.transform_buffer.id, 0, window.transform_buffer.size, &transform)
}

reset_transform :: proc() {
    push_transform(window.renderer.default_transform)
}

push_transform :: proc(transform: Transform) -> bool {
    return command_push_push_transform({
        transform = transform
    })
}

pop_transform :: proc() -> bool {
    return command_push_pop_transform()
}

/*
    note(isak): this takes care of draw command stats for the previously set current draw;
                we don't need an end_draw() as far as i can tell (except to avoid branching)
*/
begin_draw_with_transform :: proc(transform: Transform) -> bool {
    renderer := &window.renderer

    command_push_push_transform({
        transform = transform
    }) or_return
    window.current_transform = transform

    current_index_count := renderer.current_draw != nil ? renderer.current_draw.index_count : 0
    current_index_offset := renderer.current_draw != nil ? renderer.current_draw.index_offset : 0

    command_push_draw({ 
        index_offset = current_index_offset + u32(current_index_count),
        instance_count = 1
    }) or_return

    cmds := &renderer.command_queue
    renderer.current_draw = transmute(^Command_Draw)&cmds.data[cmds.len - size_of(Command_Draw)]
    return true
}



batch_begin :: proc(renderer: ^Renderer) {
    renderer.quad_geometry.vertices.data = tbo_advance_and_get(&window.quad_store.vertex_buffer)
    renderer.quad_geometry.vertices.count = 0
    renderer.quad_geometry.indices.data = tbo_advance_and_get(&window.quad_store.index_buffer)
    renderer.quad_geometry.indices.count = 0

    renderer.slider_instances.data = tbo_advance_and_get(&window.slider_instance_store)
    renderer.slider_instances.count = 0
    
    renderer.text_geometry.data = tbo_advance_and_get(&window.text_store)
    renderer.text_geometry.count = 0

    renderer.current_draw.index_count = 0
    renderer.current_draw.index_offset = 0
}

batch_end :: proc(renderer: ^Renderer) {
    tbo_lock(&window.quad_store.vertex_buffer)
    tbo_lock(&window.quad_store.index_buffer)
    tbo_lock(&window.slider_instance_store)
    tbo_lock(&window.text_store)
    
    tbo_bind(&window.quad_store.vertex_buffer, 0)
    tbo_bind(&window.quad_store.index_buffer, 1)
    sbo_bind(&window.texture_buffer, 2)
    sbo_bind(&window.circle_geo_buffer, 3)
    tbo_bind(&window.slider_instance_store, 4)
    ubo_bind(&window.transform_buffer, 5)

    //sg.apply_pipeline(window.quad_pipeline)
    
    //sg.draw(0, renderer.quad_geometry.indices.count, 1)

    /*
    sbo_bind(&window.fullscreen_store.vertex_buffer, 0)
    sbo_bind(&window.fullscreen_store.index_buffer, 1)
    
    // todo(isak): gl.MultiDrawArraysIndirect() gave me an error and a headache from trying to debug it
    // might have to figure it out someday but for now we're just drawing in a loop

    for i in 0..<renderer.slider_draw_commands.count {
        sg.apply_pipeline(window.slider_pipeline)
        
        fbo_bind_write(window.slider_framebuffer)
        gl.ClearColor(0,0,0,0)
        gl.ClearDepth(1.0)
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

        cmd := renderer.slider_draw_commands.data[i]
        gl.DrawArraysInstancedBaseInstance(gl.TRIANGLE_FAN, 0, renderer.circle_geometry.count,
                                           cmd.instance_count, cmd.base_instance)
        fbo_bind_read(window.slider_framebuffer)

        sg.apply_pipeline(window.quad_pipeline)
        sg.draw(0, 6, 1)
    }

    fbo_unbind(window.slider_framebuffer)
    */
}


write_quad_indices :: proc(indices: []u32, index_at, vert: i32) {
    indices[index_at + 0] = u32(vert) + 0
    indices[index_at + 1] = u32(vert) + 2
    indices[index_at + 2] = u32(vert) + 1
    indices[index_at + 3] = u32(vert) + 1
    indices[index_at + 4] = u32(vert) + 2
    indices[index_at + 5] = u32(vert) + 3
}

push_quad_with_uvs :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), pos1, uv1, pos2, uv2, pos3, uv3, pos4, uv4: vec2, 
                           color: vec4, tex_index: u32) {
    assert(window.renderer.current_draw != nil)

    if geometry.vertices.count + 4 > batch_max_vertices {
        batch_end(&window.renderer)
        batch_begin(&window.renderer)
    }

    #no_bounds_check {
        vert_i := geometry.vertices.count
        verts := geometry.vertices.data
        verts[vert_i + 0] = {
            pos = {pos1.x, pos1.y},
            uv = uv1,
            color = color,
            tex_index = tex_index
        }
        verts[vert_i + 1] = {
            pos = {pos2.x, pos2.y},
            uv = uv2,
            color = color,
            tex_index = tex_index
        }
        verts[vert_i + 2] = {
            pos = {pos3.x, pos3.y},
            uv = uv3,
            color = color,
            tex_index = tex_index
        }
        verts[vert_i + 3] = {
            pos = {pos4.x, pos4.y},
            uv = uv4,
            color = color,
            tex_index = tex_index
        }
        
        write_quad_indices(geometry.indices.data, geometry.indices.count, vert_i)
        geometry.vertices.count += 4
        geometry.indices.count += 6

        window.renderer.current_draw.index_count += 6
    }
}

push_quad :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), pos1, pos2, pos3, pos4: vec2, color: vec4, tex_index: u32) {
    push_quad_with_uvs(geometry, 
                       pos1, {0, 0}, 
                       pos2, {0, 1}, 
                       pos3, {1, 0}, 
                       pos4, {1, 1}, color, tex_index)
}

push_xywh :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), x, y, w, h: f32, color: vec4, tex_index: u32) {
    push_quad_with_uvs(geometry, 
                       {x,     y    }, {0, 0}, 
                       {x,     y + h}, {0, 1}, 
                       {x + w, y    }, {1, 0}, 
                       {x + w, y + h}, {1, 1}, color, tex_index)
}

push_rect :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: Rect, color: vec4, tex_index: u32 = 0) {
    push_quad_with_uvs(geometry, {rect.x,          rect.y         }, {0, 0},
                                 {rect.x,          rect.y + rect.h}, {0, 1},
                                 {rect.x + rect.w, rect.y         }, {1, 0},
                                 {rect.x + rect.w, rect.y + rect.h}, {1, 1}, color, tex_index)
}

push_layout_rect :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: Rect, anchor: Layout_Anchor, color: vec4 = color_white, tex_index: u32 = 0) {
    push_rect(geometry, rect_translate_by_anchor(rect, anchor), color, tex_index) 
}


push_rect_outline :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: Rect, color: vec4, thickness_px: f32) {
    xform := window.current_transform

    offset: f32 = math.mod(thickness_px, 2)
    thickness_y: f32 = thickness_px
    thickness_x: f32 = thickness_px
    
    // top
    push_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2,
                              rect.y - (thickness_y + offset)/2, 
                              rect.w + thickness_y, 
                              thickness_y }, color)
    // bottom
    push_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2, 
                              rect.y + rect.h - (thickness_y + offset)/2, 
                              rect.w + thickness_y, 
                              thickness_y }, color)
    // left
    push_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2, 
                              rect.y - (offset)/2, 
                              thickness_x, 
                              rect.h - thickness_y/2 }, color)
    // right
    push_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2 + rect.w, 
                              rect.y - (offset)/2, 
                              thickness_x, 
                              rect.h - thickness_y/2 }, color)
}

push_rect_outline_fill :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: Rect, color_outline, color_fill: vec4, thickness_px: f32) {
    push_rect(geometry, rect, color_fill)
    push_rect_outline(geometry, rect, color_outline, thickness_px)
}


//////////////////////////////////////////////////////
// note(isak): layout api

rect_translate_by_anchor :: proc(rect: Rect, anchor: Layout_Anchor) -> Rect {
    result := Rect {
        w = rect.w,
        h = rect.h,
    }
    if anchor == .TOP_MIDDLE || anchor == .CENTER || anchor == .BOTTOM_MIDDLE {
        result.x = rect.x - (rect.w / 2)
    } else if anchor == .TOP_RIGHT || anchor == .MIDDLE_RIGHT || anchor == .BOTTOM_RIGHT {
        result.x = rect.x - rect.w
    } else {
        result.x = rect.x
    }

    if anchor == .MIDDLE_LEFT || anchor == .CENTER || anchor == .MIDDLE_RIGHT {
        result.y = rect.y - (rect.h / 2)
    } else if anchor == .BOTTOM_LEFT || anchor == .BOTTOM_MIDDLE || anchor == .BOTTOM_RIGHT {
        result.y = rect.y - rect.h
    } else {
        result.y = rect.y
    }
    return result
}

rect_translate_to_inner :: proc(inner, outer: Rect) -> Rect {
    if outer.w <= 0 || outer.h <= 0 {
        return {
            x = outer.x,
            y = outer.y
        }
    }

    return {
        x = outer.x + (inner.x * outer.w),
        y = outer.y + (inner.y * outer.h),
        w = inner.w * outer.w,
        h = inner.h * outer.h
    }
}

