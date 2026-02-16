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


MAX_BATCH_VERTICES :: 64*1024
MAX_SLIDER_INSTANCES :: 64*1024
MAX_TEXTURE_HANDLES :: 1024

MAX_DRAW_CALLS_PER_LAYER :: 4096

UNIT_CIRCLE_VERTEX_COUNT :: 30


Quad :: struct {
    pos_min:   vec2,
    pos_max:   vec2,
    uv_min:    vec2,
    uv_max:    vec2,
    color:     u32,
    tex_index: u32,
    angle:     f32,
    __padding:   [1]u32
}

Slider_Vertex :: struct {
    pos: vec3,
    __padding: u32,
}

Mesh_Vertex :: struct {
    pos: vec3,
    norm: vec3,
    uv: vec2,
}


Geometry_Buffer :: struct(T: typeid) {
    vertices: Buffer(T),
    indices: Buffer(u32),
}

Draw_Call :: struct {
    index_offset: u32,
    index_count: i32,
    base_instance: u32,
    instance_count: i32,
}

Shader_Globals :: struct {
    transform: Transform,
    circle_size_osupx: f32,
    time: f32,
}

Renderer :: struct {
    quad_geometry: Buffer(Quad),
    slider_instances: Buffer(vec2),
    
    text_geometry: Buffer(Glyph_Quad),
    
    circle_geometry: Buffer(Slider_Vertex),

    transform_queue: queue.Queue(Transform),

    layer_command_queues: [Layer]queue.Queue(u8),

    current_draw: ^Command_Draw,
    null_draw: Command_Draw,
    
    text_draw: Command_Draw,
    
    new_draw_on_next_push: bool,
    current_layer: Layer,
    current_global_data: Shader_Globals,
    current_scissor: Command_Scissor_Mode,
    current_framebuffer: Command_Bind_Framebuffer,
    current_pipeline: Command_Bind_Pipeline,

    current_pipeline_for_layer: [Layer]Command_Bind_Pipeline,
    current_ssbo_binds: [Shader_SSBO_Bind_Slot]Command_Bind_SSBO,

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

//////////////////////////////////////////////////////
// note(isak): core

renderer_init :: proc() {
    renderer := &window.renderer
    renderer.current_draw = &renderer.null_draw

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
    
    queue.init(&window.shaders, 128)
    queue.init(&window.pipelines, 128)

    {
        quad_shader, err := shader_init(quad_vs_path, quad_fs_path, context.temp_allocator)
        assert(err == .NONE)
        queue.push(&window.shaders, quad_shader)
        queue.push(&window.pipelines, sg.make_pipeline(quad_pipeline_desc()))
    }
    {
        slider_shader, err := shader_init(slider_vs_path, slider_fs_path, context.temp_allocator)
        assert(err == .NONE)
        queue.push(&window.shaders, slider_shader)
        queue.push(&window.pipelines, sg.make_pipeline(slider_pipeline_desc()))
    }
    {
        text_shader, err := shader_init(text_vs_path, text_fs_path, context.temp_allocator)
        assert(err == .NONE)
        queue.push(&window.shaders, text_shader)
        queue.push(&window.pipelines, sg.make_pipeline(text_pipeline_desc()))
    }
    
    window.framebuffers[.SLIDERS] = fbo_init(1, 1, i32(window.rect.w), i32(window.rect.h), gl.RGBA8)
    

    window.quad_store = tbo_init(Quad, MAX_BATCH_VERTICES)
    window.text_store = tbo_init(Glyph_Quad, MAX_BATCH_VERTICES)

    window.slider_instance_store = sbo_init(vec2, MAX_BATCH_VERTICES)
    window.fullscreen_store = sbo_init(Quad, 4)
    window.texture_buffer = sbo_init(u64, MAX_TEXTURE_HANDLES)
    
    window.shader_global_buffer = ubo_init(Shader_Globals, 1)


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

    circle_buffer_vertex_count := UNIT_CIRCLE_VERTEX_COUNT + 2
    window.circle_geo_buffer = sbo_init(Slider_Vertex, circle_buffer_vertex_count)
    renderer.circle_geometry = 
        buffer_init(i32(circle_buffer_vertex_count), window.circle_geo_buffer.data)

    populate_slider_circle_vertices(&renderer.circle_geometry)
    
    renderer.slider_instances.size = MAX_BATCH_VERTICES

    //

    fullscreen_geometry := buffer_init(MAX_BATCH_VERTICES, window.fullscreen_store.data)
    r_draw_rect(&fullscreen_geometry, {0,0,1,1}, with_alpha(color_white, 0.5), reserved_texture(.SLIDER_FRAMEBUFFER))
    
    //
    
    renderer.text_geometry.size = MAX_BATCH_VERTICES
    
    renderer.current_global_data = {identity_transform, 0, 0}
    gl.NamedBufferSubData(window.shader_global_buffer.id, 0, size_of(Shader_Globals), &renderer.current_global_data)

    renderer.slider_instances = buffer_init(MAX_SLIDER_INSTANCES, window.slider_instance_store.data)

    for layer in Layer {
        alloc_err: runtime.Allocator_Error
        alloc_err = queue.init(&renderer.layer_command_queues[layer], kilobytes(1), memory.command_buffer_allocators[layer])
        assert(alloc_err == .None, "command queue alloc error")
    }
}

renderer_cleanup :: proc() {
    tbo_cleanup(&window.quad_store)
    tbo_cleanup(&window.text_store)
    
    sbo_cleanup(&window.fullscreen_store)
    sbo_cleanup(&window.circle_geo_buffer)
    sbo_cleanup(&window.texture_buffer)
    sbo_cleanup(&window.slider_instance_store)

    ubo_cleanup(&window.shader_global_buffer)
}


r_create_static_store :: proc($T: typeid, count: int, alloc: runtime.Allocator) -> ^GL_Buffer(T) {
    result := new(GL_Buffer(T))
    sbo_init_ptr(result, count)
    return result
}

r_create_dynamic_store :: proc($T: typeid, count: int, alloc: runtime.Allocator) -> ^GL_Triple_Buffer(T) {
    result := new(GL_Triple_Buffer(T))
    tbo_init_ptr(&result, count)
    return result
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
    vs_path, fs_path: string
}

shader_init :: proc(vs_path, fs_path: string, alloc: runtime.Allocator = context.temp_allocator) -> (Shader, Shader_Error) {
    vs_filedata, vs_err := read_entire_file(vs_path, alloc)
    if vs_err != os.ERROR_NONE {
        fmt.printfln("loading vert shader file '{}' failed: {}", vs_path, vs_err)
        return {}, .READ_ERROR
    }
    fs_filedata, fs_err := read_entire_file(fs_path, alloc)
    if fs_err != os.ERROR_NONE {
        fmt.printfln("loading frag shader file '{}' failed: {}", fs_path, fs_err)
        return {}, .READ_ERROR
    }

    if (vs_err != os.ERROR_NONE) || (fs_err != os.ERROR_NONE) {
        return {}, .PATH_ERROR
    }

    temp_shader := sg.make_shader(
        sg.Shader_Desc {
            vertex_func = {source = strings.clone_to_cstring(string(vs_filedata))},
            fragment_func = {source = strings.clone_to_cstring(string(fs_filedata))}
        },
    )

    if sg.query_shader_state(temp_shader) == sg.Resource_State.VALID {
        return {
            shader = temp_shader,
            vs_path = vs_path,
            fs_path = fs_path
        }, .NONE
    }
    sg.destroy_shader(temp_shader)
    return {}, .COMPILE_ERROR
}

shader_reinit :: proc(shader: ^Shader, alloc: runtime.Allocator = context.temp_allocator) -> Shader_Error {
    new_shader, err := shader_init(shader.vs_path, shader.fs_path, alloc)
    if err != .NONE {
        assert(err == .COMPILE_ERROR)
        fmt.println("Shader compile errors found. Paths:", shader.vs_path, shader.fs_path)
        return err
    }
    sg.destroy_shader(shader.shader)
    shader^ = new_shader
    return err
}

shader_delete :: proc(shader: ^Shader) {
    sg.destroy_shader(shader.shader)
    shader.shader = sg.Shader{}
}

pipeline_reinit :: proc(pipeline: ^sg.Pipeline, pipeline_desc: sg.Pipeline_Desc) {
    sg.destroy_pipeline(pipeline^)
    pipeline^ = sg.make_pipeline(pipeline_desc)
}

//////////////////////////////////////////////////////
// note(isak): command queue api

Command_Type :: enum(u8) {
    PUSH_TRANSFORM,
    POP_TRANSFORM,
    CLEAR,
    DRAW,
    DRAW_SLIDER,
    BIND_PIPELINE,
    BIND_FRAMEBUFFER,
    BIND_SSBO,
    SCISSOR_MODE,
}

Command_Header :: struct {
    command_type: Command_Type
}

Command_Push_Transform :: struct {
    transform: Transform
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
    id: u32,
    slot: Shader_SSBO_Bind_Slot,
    size, offset: int
}

Command_Scissor_Mode :: struct {
    x, y, width, height: i32
}

command_push_clear             :: proc() -> bool { return _command_push_header(.CLEAR) }
command_push_push_transform    :: proc(cmd: Command_Push_Transform) -> bool { return _command_push(cmd, .PUSH_TRANSFORM) }
command_push_pop_transform     :: proc() -> bool { return _command_push_header(.POP_TRANSFORM) }
command_push_draw              :: proc(cmd: Command_Draw) -> bool { return _command_push(cmd, .DRAW) }
command_push_draw_slider       :: proc(cmd: Command_Draw_Slider) -> bool { return _command_push(cmd, .DRAW_SLIDER) }
command_push_bind_pipeline     :: proc(cmd: Command_Bind_Pipeline) -> bool { return _command_push(cmd, .BIND_PIPELINE) }
command_push_bind_framebuffer  :: proc(cmd: Command_Bind_Framebuffer) -> bool { return _command_push(cmd, .BIND_FRAMEBUFFER) }
command_push_bind_ssbo         :: proc(cmd: Command_Bind_SSBO) -> bool { return _command_push(cmd, .BIND_SSBO) }
command_push_scissor_mode      :: proc(cmd: Command_Scissor_Mode) -> bool { return _command_push(cmd, .SCISSOR_MODE) }


_command_push_header :: proc(type: Command_Type) -> bool {
    using window.renderer
    ok, err := queue.push_back(&layer_command_queues[current_layer], u8(type))
    assert(err == .None)
    return ok
}

_command_push :: proc(cmd: $T, type: Command_Type) -> bool {
    using window.renderer
    cmd := cmd
    ok := _command_push_header(type)
    if ok {
        err: runtime.Allocator_Error
        cmd_data: []u8 = slice.from_ptr((^u8)(&cmd), size_of(T))
        ok, err = queue.push_back_elems(&layer_command_queues[current_layer], ..cmd_data)
        assert(err == .None)
    }
    assert(ok)
    return ok
}

_command_consume :: proc(cmd_queue: ^queue.Queue(u8), $T: typeid) -> ^T {
    cmd_ptr := (^T)(queue.front_ptr(cmd_queue))
    queue.consume_front(cmd_queue, size_of(T))
    return cmd_ptr
}

//////////////////////////////////////////////////////
// note(isak): core renderer api

r_clear :: proc() {
    window.renderer.new_draw_on_next_push = true
    command_push_clear()
}

r_push_draw :: proc(index_offset: u32, index_count: i32, instance_count: i32 = 1, base_instance: u32 = 0) {
    command_push_draw({
        index_offset = index_offset,
        index_count = index_count,
        base_instance = base_instance,
        instance_count = instance_count
    })
    cmds := &window.renderer.layer_command_queues[window.renderer.current_layer]
    window.renderer.current_draw = transmute(^Command_Draw)&cmds.data[cmds.len - size_of(Command_Draw)]
    
    window.renderer.new_draw_on_next_push = false
}

r_bind_framebuffer :: proc(cmd: Command_Bind_Framebuffer) {
    window.renderer.new_draw_on_next_push = true
    window.renderer.current_framebuffer = cmd
    command_push_bind_framebuffer(cmd)
}

r_check_and_bind_pipeline :: proc(cmd: Command_Bind_Pipeline) {
    if cmd.pipeline != window.renderer.current_pipeline_for_layer[window.renderer.current_layer].pipeline {
        r_bind_pipeline(cmd)
    }
}

r_bind_pipeline :: proc(cmd: Command_Bind_Pipeline) {
    window.renderer.new_draw_on_next_push = true
    window.renderer.current_pipeline = cmd
    window.renderer.current_pipeline_for_layer[window.renderer.current_layer] = cmd
    command_push_bind_pipeline(cmd)
}


_r_get_ssbo_cmd_from_sbo :: proc(sbo: ^GL_Buffer($T), bind_slot: Shader_SSBO_Bind_Slot) -> Command_Bind_SSBO {
    return Command_Bind_SSBO{ sbo.id, bind_slot, sbo.size, 0 }
}
_r_get_ssbo_cmd_from_tbo :: proc(tbo: ^GL_Triple_Buffer($T), bind_slot: Shader_SSBO_Bind_Slot) -> Command_Bind_SSBO {
    return Command_Bind_SSBO{ tbo.id, bind_slot, tbo.size, tbo.buffers[tbo.current_index].offset }
}

_r_push_ssbo :: proc(cmd: Command_Bind_SSBO) {
    if cmd.slot != .NONE {
        window.renderer.new_draw_on_next_push = true
        window.renderer.current_ssbo_binds[cmd.slot] = cmd
        command_push_bind_ssbo(cmd)
    }
}

r_bind_sbo :: proc(sbo: ^GL_Buffer($T), bind_index: Shader_SSBO_Bind_Slot) {
    _r_push_ssbo(_r_get_ssbo_cmd_from_sbo(sbo, bind_index))
}
r_bind_tbo :: proc(tbo: ^GL_Triple_Buffer($T), bind_index: Shader_SSBO_Bind_Slot) {
    _r_push_ssbo(_r_get_ssbo_cmd_from_tbo(tbo, bind_index))
}
r_bind_ssbo :: proc {
    r_bind_sbo,
    r_bind_tbo
}

/*
    note(isak): 2D transforms are tricky - we use them to define the coordinate system that spans the
    window without distortion. we do these calculations on the GPU using the bounds rect and the 
    aspect ratio of the window, which are uploaded using commit_transform.

    a rect of [0,0,1,1] means the points (0,0) and (1,1) would touch opposite corners of a square area
    placed in the middle of the window (note: only when the aspect ratio <= 1). a rect of 
    [0, 0, window_width, window_height ] is used with an aspect_ratio of 1 to create a pixel-perfect
    screen transform, such that w=1, h=1 corresponds to one pixel.
*/
r_push_transform :: proc(transform: Transform) {
    window.renderer.new_draw_on_next_push = true
    window.renderer.current_global_data.transform = transform
    command_push_push_transform({transform})
}

r_pop_transform :: proc() {
    // todo(isak) implement
}

r_begin_scissor_mode :: proc(x, y, width, height: i32) {
    cmd := Command_Scissor_Mode{x, y, width, height}
    window.renderer.new_draw_on_next_push = true
    window.renderer.current_scissor = cmd
    command_push_scissor_mode(cmd)
}

r_end_scissor_mode :: proc() {
    r_begin_scissor_mode(0, 0, i32(window.rect.w), i32(window.rect.h))
}

/*
    note(isak): layers are processed sequentially via the command buffer system (for transparency blending purposes). 
    this means that if render procedures/scripts are run without matching this order, we might have state issues
    since the bound state at the end of a layer might not match what one would expect from reading the code.
    
    (maybe just keeping state per layer is better? this may require some discipline though.)
*/
r_bind_layer :: proc(layer: Layer) {
    window.renderer.current_layer = layer
}

r_check_and_bind_layer :: proc(layer: Layer) {
    if layer != window.renderer.current_layer {
        r_bind_layer(layer)
    }
}

r_bind_layer_and_push_current_state :: proc(layer: Layer,    
    framebuffer: Command_Bind_Framebuffer = window.renderer.current_framebuffer,
    pipeline: Command_Bind_Pipeline = window.renderer.current_pipeline,
    transform: Transform = window.renderer.current_global_data.transform,
    scissor_region: Command_Scissor_Mode = window.renderer.current_scissor
) {
    r_bind_layer(layer)
    r_push_current_state(framebuffer, pipeline, transform, scissor_region)
}

r_push_current_state :: proc(
    cmd_framebuffer: Command_Bind_Framebuffer = window.renderer.current_framebuffer,
    cmd_pipeline: Command_Bind_Pipeline = window.renderer.current_pipeline,
    transform: Transform = window.renderer.current_global_data.transform,
    scissor_region: Command_Scissor_Mode = window.renderer.current_scissor
) {
    r_bind_framebuffer(cmd_framebuffer)
    r_bind_pipeline(cmd_pipeline)
    r_push_transform(transform)
    r_begin_scissor_mode(scissor_region.x, scissor_region.y, scissor_region.width, scissor_region.height)

    for ssbo_slot in Shader_SSBO_Bind_Slot {
        _r_push_ssbo(window.renderer.current_ssbo_binds[ssbo_slot])
    }
}

///////////////////////////////////////////////////////////////////////////
// note(isak): renderer control api

r_set_shader_globals :: proc(val: Shader_Globals) {
    val := val
    gl.NamedBufferSubData(window.shader_global_buffer.id, 
                          0, size_of(Shader_Globals), &val)
}

r_set_time :: proc(time: f32) {
    val := time
    gl.NamedBufferSubData(window.shader_global_buffer.id, 
                          int(offset_of_by_string(Shader_Globals, "time")), size_of(f32), &val)
}

r_set_circle_size_osupx :: proc(circle_size_osupx: f32) {
    val := circle_size_osupx
    gl.NamedBufferSubData(window.shader_global_buffer.id, 
                          int(offset_of_by_string(Shader_Globals, "circle_size_osupx")), size_of(f32), &val)
}

commit_transform :: proc(transform: Transform) {
    transform := transform
    gl.NamedBufferSubData(window.shader_global_buffer.id, 0, size_of(transform), &transform)
}

batch_begin :: proc(renderer: ^Renderer) {
    renderer.quad_geometry.data = tbo_advance_and_get(&window.quad_store)
    renderer.quad_geometry.count = 0

    renderer.text_geometry.data = tbo_advance_and_get(&window.text_store)
    renderer.text_geometry.count = 0

    renderer.current_draw.index_count = 0
    renderer.current_draw.index_offset = 0
}

batch_end :: proc(renderer: ^Renderer) {
    tbo_lock(&window.quad_store)
    tbo_lock(&window.text_store)
    
    sbo_bind(&window.texture_buffer, u32(Shader_SSBO_Bind_Slot.TEXTURES))
    ubo_bind(&window.shader_global_buffer, u32(Shader_SSBO_Bind_Slot.TRANSFORM))
    sbo_bind(&window.slider_instance_store, u32(Shader_SSBO_Bind_Slot.INSTANCE_BUFFER))

    batch_process_command_buffer(renderer)
}

batch_flush :: proc(renderer: ^Renderer) {
    batch_end(renderer)
    batch_begin(renderer)
}

batch_process_command_buffer :: proc(renderer: ^Renderer) {
    trace := renderer.trace_frame
    
    for layer in Layer {
        command_queue := renderer.layer_command_queues[layer]

        if command_queue.len > 0 {
            if (trace) { fmt.println(layer) }
        }

        for command_queue.len > 0 {
            cmd_type := queue.pop_front(&command_queue)

            switch Command_Type(cmd_type) {
                case .CLEAR: {
                    gl.ClearColor(0,0,0,0)
                    gl.ClearDepth(1.0)
                    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

                    if (trace) { fmt.println("  clear") }
                }
                case .PUSH_TRANSFORM: {
                    cmd := _command_consume(&command_queue, Command_Push_Transform)
                    commit_transform(cmd.transform)
                    
                    if (trace) { 
                        fmt.println("  push xform", cmd.transform) 
                    }
                }
                case .POP_TRANSFORM: {
                    assert(false)

                    // todo(isak) implement
                    
                    if (trace) { 
                        fmt.println("  pop xform") 
                    }
                }
                case .DRAW: {
                    cmd := _command_consume(&command_queue, Command_Draw)
                    assert(cmd.base_instance == 0, "base_instance is unhandled")
                    
                    sg.draw(cmd.index_offset, cmd.index_count, cmd.instance_count)

                    if (trace) { fmt.println("  draw", cmd.index_offset, cmd.index_count, cmd.instance_count, cmd.base_instance ) }
                }
                case .DRAW_SLIDER: {
                    cmd := _command_consume(&command_queue, Command_Draw_Slider)
                                    
                    gl.DrawArraysInstancedBaseInstance(
                        gl.TRIANGLE_FAN, 
                        0, 
                        renderer.circle_geometry.count,
                        cmd.instance_count, cmd.base_instance)

                    if (trace) { fmt.println("  drawslider", cmd.instance_count, cmd.base_instance) }
                }
                case .BIND_PIPELINE: {
                    cmd := _command_consume(&command_queue, Command_Bind_Pipeline)

                    sg.apply_pipeline(window.pipelines.data[cmd.pipeline])
                    
                    if (trace) { fmt.println("  pipeline", cmd.pipeline) }
                }
                case .BIND_FRAMEBUFFER: {
                    cmd := _command_consume(&command_queue, Command_Bind_Framebuffer)

                    fbo_bind(window.framebuffers[cmd.read].id, window.framebuffers[cmd.write].id)
                    
                    if (trace) { fmt.println("  framebuffer", cmd.read, cmd.write) }
                }
                case .BIND_SSBO: {
                    cmd := _command_consume(&command_queue, Command_Bind_SSBO)
                    
                    gl.BindBufferRange(
                        gl.SHADER_STORAGE_BUFFER,
                        u32(cmd.slot),
                        cmd.id,
                        cmd.offset,
                        cmd.size)
                    
                    if (trace) { fmt.println("  ssbo", cmd.id, cmd.slot, cmd.size, cmd.offset) }
                }
                case .SCISSOR_MODE: {
                    cmd := _command_consume(&command_queue, Command_Scissor_Mode)
                    
                    gl.Scissor(cmd.x, cmd.y, max(cmd.width, 0), max(cmd.height, 0))
                    
                    if (trace) { fmt.println("  scissor", cmd.x, cmd.y, cmd.width, cmd.height) }
                }
            }
        }
    }
    renderer.trace_frame = false

    sg.end_pass()
    sg.commit()
}


///////////////////////////////////////////////////////////////////////////
// note(isak): draw api - PS: we use our nice global window.renderer here to make the api easier

r_draw_quad_with_uv :: proc(geometry: ^Buffer(Quad), pos_min, pos_max, uv_min, uv_max: vec2, 
                          color: Color, tex_index: u32, angle: f32 = 0) {
    assert(window.renderer.current_draw != nil)

    if geometry.count + 1 > MAX_BATCH_VERTICES {
        batch_flush(&window.renderer)
    }
    if window.renderer.new_draw_on_next_push {
        r_push_draw(
            index_offset = u32(geometry.count) * 6, 
            index_count = 0
        )
    }

    #no_bounds_check {
        vert_i := geometry.count
        verts := geometry.data

        verts[vert_i] = {
            pos_min = pos_min,
            pos_max = pos_max,
            uv_min = uv_min,
            uv_max = uv_max,
            color = transmute(u32)color,
            tex_index = tex_index,
            angle = angle
        }

        geometry.count += 1
        window.renderer.current_draw.index_count += 6
    }
}

r_draw_quad :: proc(geometry: ^Buffer(Quad), pos_min, pos_max, uv_min, uv_max: vec2, 
                    color: Color, tex_index: u32 = 0, angle: f32 = 0) {
    r_draw_quad_with_uv(geometry, 
                      pos_min, pos_max, 
                      uv_min, uv_max, 
                      color, tex_index, angle)
}

r_draw_rect :: proc(geometry: ^Buffer(Quad), r: Rect,
                    color: Color, tex_index: u32 = 0, angle: f32 = 0) {
    r_draw_quad_with_uv(geometry, {r.x, r.y}, {r.x + r.w, r.y + r.h}, 
                                {0, 0}, {1, 1}, color, tex_index, angle)
}

r_draw_rect_with_uv :: proc(geometry: ^Buffer(Quad), r, uv: Rect, 
                            color: Color, tex_index: u32 = 0, angle: f32 = 0) {
    r_draw_quad_with_uv(geometry, {r.x, r.y}, {r.x + r.w, r.y + r.h}, 
                                {uv.x, uv.y}, {uv.x + uv.w, uv.y + uv.h}, color, tex_index, angle)
}

r_draw_layout_rect :: proc(geometry: ^Buffer(Quad), rect: Rect, anchor: Layout_Anchor, 
                           color: Color = color_white, tex_index: u32 = 0, angle: f32 = 0) {
    r_draw_rect(geometry, rect_translate_by_anchor(rect, anchor), color, tex_index, angle) 
}


// todo(isak): thickness doesn't really work anymore... should prolly fetch scale from current transform
// todo(isak): add angle, but that requires placing the rects on the middle of each side with respect to it
r_draw_rect_outline :: proc(geometry: ^Buffer(Quad), rect: Rect, color: Color, thickness_px: f32) {
    xform := window.renderer.current_global_data

    offset: f32 = math.mod(thickness_px, 2)
    thickness_y: f32 = thickness_px
    thickness_x: f32 = thickness_px
    
    // top
    r_draw_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2,
                              rect.y - (thickness_y + offset)/2, 
                              rect.w + thickness_y, 
                              thickness_y }, color)
    // bottom
    r_draw_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2, 
                              rect.y + rect.h - (thickness_y + offset)/2, 
                              rect.w + thickness_y, 
                              thickness_y }, color)
    // left
    r_draw_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2, 
                              rect.y - (offset)/2, 
                              thickness_x, 
                              rect.h - thickness_y/2 }, color)
    // right
    r_draw_rect(geometry, Rect{ rect.x - (thickness_y + offset)/2 + rect.w, 
                              rect.y - (offset)/2, 
                              thickness_x, 
                              rect.h - thickness_y/2 }, color)
}

r_draw_rect_outline_fill :: proc(geometry: ^Buffer(Quad), rect: Rect, color_outline, color_fill: Color, thickness_px: f32) {
    r_draw_rect(geometry, rect, color_fill)
    r_draw_rect_outline(geometry, rect, color_outline, thickness_px)
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
