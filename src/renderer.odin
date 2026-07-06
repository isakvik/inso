package notosu

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import "core:log"
import "core:mem"
import os "core:os"
import "core:slice"
import "core:strings"
import "core:container/queue"

import gl "vendor:OpenGL"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"


MAX_BATCH_VERTICES :: 64*1024
MAX_SLIDER_INSTANCES :: 16 * 1024 * 1024
MAX_SLIDER_DRAWS :: 4096
MAX_TEXTURE_HANDLES :: 1024
MAX_TEXTURE_UNITS :: 16

MAX_DRAW_CALLS_PER_LAYER :: 4096

MAX_POST_PASSES :: 64

UNIT_CIRCLE_VERTEX_COUNT :: 36

UNMAPPED_UNIT :: 0xFF

Texture_Unit_Map :: struct {
    global_to_local: [MAX_TEXTURE_HANDLES]u8,
    local_to_global: [MAX_TEXTURE_UNITS]u32,
    unit_count: u8,
}


Quad :: struct {
    pos_min:   vec2,
    pos_max:   vec2,
    uv_min:    vec2,
    uv_max:    vec2,
    tex_layer: f32,
    color:     u32,
    tex_index: u32,
    angle:     f32
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
    playfield_transform: Transform,
    time: f32,
    circle_size_osupx: f32,
    cursor_pos: [2]f32,
    resolution: [2]f32,
}

Layer_State_Field :: enum { FRAMEBUFFER, PIPELINE, TRANSFORM, SCISSOR }

/*
    note(isak): layers are processed sequentially via the command buffer system (for transparency blending purposes). 
    this means that if render procedures/scripts are run without matching this order, we might have state issues
    since the bound state at the end of a layer might not match what one would expect from reading the code
*/
Layer_Render_State :: struct {
    framebuffer: Command_Bind_Framebuffer,
    pipeline:    Command_Bind_Pipeline,
    transform:   Transform,
    scissor:     Command_Scissor_Mode,
    ssbo:        [Shader_SSBO_Bind_Slot]Command_Bind_SSBO,

    emitted:      bit_set[Layer_State_Field],
    ssbo_emitted: bit_set[Shader_SSBO_Bind_Slot],
}

Renderer :: struct {
    quad_geometry: Buffer(Quad),
    slider_instances: Buffer(vec2),
    slider_params: Buffer(Slider_Params_Slot),

    text_geometry: Buffer(Glyph_Quad),

    circle_geometry: Buffer(Slider_Vertex),

    transform_queue: queue.Queue(Transform),

    layer_command_queues: [Layer]queue.Queue(u8),

    current_draw: ^Command_Draw,
    text_draw: Command_Draw, // todo(isak) this makes text rendering pretty nonconfigurable... good for debug tho

    new_draw_on_next_push: bool,
    current_layer: Layer,
    current_global_data: Shader_Globals,

    // note(isak): "last value emitted anywhere", used only as inheritance defaults for
    // r_push_current_state. the per-layer layer_state drives the actual dedup decisions.
    current_scissor: Command_Scissor_Mode,
    current_framebuffer: Command_Bind_Framebuffer,
    current_pipeline: Command_Bind_Pipeline,
    current_ssbo_binds: [Shader_SSBO_Bind_Slot]Command_Bind_SSBO,

    layer_state: [Layer]Layer_Render_State,

    // note(isak): non-bindless texture unit tracking
    texture_unit_map: Texture_Unit_Map,
    current_draw_tex_units: ^Draw_Texture_Units,

    trace_frame: bool
}

@(rodata) null_draw := Command_Draw{}


Texture_Handle :: u64

Texture :: struct {
    path: string,
    w, h: i32,
    layer_count: i32, // note(isak): depth of the GL_TEXTURE_2D_ARRAY; 1 for flat textures
    format, internal_format: u32,
    tex_id: u32, // note(isak): gl assigned texture id
    tex_handle: Texture_Handle, // note(isak): bindless handle
    wrap: Texture_Wrap, // note(isak): preserved across reinit
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
    return transmute([4]f32)r
}

rect_at_pos :: proc(pos: vec2, size: vec2) -> Rect {
    return {pos.x, pos.y, size.x, size.y}
}

//////////////////////////////////////////////////////
// note(isak): core

renderer_init :: proc() {
    context.allocator = memory.allocators[.GLOBAL]
    
    renderer := &window.renderer
    renderer.current_draw = &null_draw

    sg.setup({
        environment = {
            defaults = {
                sample_count = 1,
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
        queue.push(&window.pipelines, sg.make_pipeline(quad_pipeline_desc(.PREMULTIPLIED)))
        queue.push(&window.pipelines, sg.make_pipeline(quad_pipeline_desc(.PREMULTIPLIED_OVER)))
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
        queue.push(&window.pipelines, sg.make_pipeline(text_pipeline_desc(.PREMULTIPLIED)))
    }

    window.framebuffers[.SLIDERS] = fbo_init(1, 1, i32(window.rect.w), i32(window.rect.h), gl.RGBA8)
    window.framebuffers[.BACKBUFFER] = fbo_init(1, 1, i32(window.rect.w), i32(window.rect.h), gl.RGBA8)
    

    window.quad_store = tbo_init(Quad, MAX_BATCH_VERTICES)
    window.text_store = tbo_init(Glyph_Quad, MAX_BATCH_VERTICES)

    window.slider_instance_store = sbo_init(vec2, MAX_SLIDER_INSTANCES)
    window.fullscreen_store = sbo_init(Quad, MAX_POST_PASSES)
    window.texture_buffer = sbo_init(u64, MAX_TEXTURE_HANDLES)

    window.shader_global_buffer = ubo_init(Shader_Globals, 1)
    window.slider_param_store   = tbo_init(Slider_Params_Slot, MAX_SLIDER_DRAWS)
    window.user_param_buffer    = ubo_init(User_Shader_Params, 1)
    window.post_param_buffer    = ubo_init(Post_Pass_Params, 1)


    window.pass_action = { 
        colors = {
            0 = { load_action = .CLEAR, clear_value = { 0.0, 0.0, 0.0, 1 } }, 
        }
    }

    window.swapchain = sg.Swapchain{
        width =  i32(window.rect.w),
        height = i32(window.rect.h),
        sample_count = 1,
        color_format = .RGBA8,
        //depth_format = .DEPTH_STENCIL,
        gl = {0} // default framebuffer
    }

    // generated textures

    white_pixel: []u32 = {0xFFFFFFFF}
    window.white_texture = texture_from_data(1, 1, raw_data(white_pixel))

    profiler_pixels := new([profiler_w * profiler_h]u32)
    window.profiler_texture = texture_from_data(profiler_w, profiler_h, raw_data(profiler_pixels), wrap = .REPEAT)

    //

    circle_buffer_vertex_count := UNIT_CIRCLE_VERTEX_COUNT + 2
    window.circle_geo_buffer = sbo_init(Slider_Vertex, circle_buffer_vertex_count)
    renderer.circle_geometry = 
        buffer_init(i32(circle_buffer_vertex_count), window.circle_geo_buffer.data)

    populate_slider_circle_vertices(&renderer.circle_geometry)
    

    //

    //fullscreen_geometry := buffer_init(MAX_BATCH_VERTICES, window.fullscreen_store.data)
    //r_draw_rect(&fullscreen_geometry, {0,0,1,1}, with_alpha(color_white, 0.5), builtin_texture(.SLIDER_FRAMEBUFFER))
    
    //
    
    renderer.text_geometry.size = MAX_BATCH_VERTICES
    
    renderer.current_global_data = {
        transform = identity_transform
    }
    gl.NamedBufferSubData(window.shader_global_buffer.id, 0, size_of(Shader_Globals), &renderer.current_global_data)

    renderer.slider_instances = buffer_init(MAX_SLIDER_INSTANCES, window.slider_instance_store.data)
    renderer.slider_params.size = MAX_SLIDER_DRAWS

    for layer in Layer {
        alloc_err: runtime.Allocator_Error
        alloc_err = queue.init(&renderer.layer_command_queues[layer], kilobytes(1), memory.command_buffer_allocators[layer])
        assert(alloc_err == .None, "command queue alloc error")
    }

    profiler_gpu_init()
}

renderer_cleanup :: proc() {
    tbo_cleanup(&window.quad_store)
    tbo_cleanup(&window.text_store)
    tbo_cleanup(&window.slider_param_store)
    ubo_cleanup(&window.user_param_buffer)
    ubo_cleanup(&window.post_param_buffer)

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
// note(isak): texture unit map (non-bindless fallback)

texture_unit_map_reset :: proc(m: ^Texture_Unit_Map) {
    mem.set(&m.global_to_local, UNMAPPED_UNIT, MAX_TEXTURE_HANDLES)
    m.unit_count = 0
}

// note(isak): returns the local unit for a global texture slot. assigns a new unit if unmapped.
// returns UNMAPPED_UNIT if the map is full (caller should flush and retry).
texture_unit_map_assign :: proc(m: ^Texture_Unit_Map, global_slot: u32) -> u8 {
    local_slot := m.global_to_local[global_slot]
    if local_slot != UNMAPPED_UNIT do return local_slot
    if m.unit_count >= MAX_TEXTURE_UNITS do return UNMAPPED_UNIT

    local_slot = m.unit_count
    m.global_to_local[global_slot] = local_slot
    m.local_to_global[local_slot] = global_slot
    m.unit_count += 1
    return local_slot
}

// note(isak): snapshots the current unit map into the in-flight draw's texture data
texture_unit_map_finalize :: proc(renderer: ^Renderer) {
    tex_unit_data := renderer.current_draw_tex_units
    if tex_unit_data == nil do return
    
    tex_unit_data.count = renderer.texture_unit_map.unit_count
    for i in 0..<tex_unit_data.count {
        global_slot := renderer.texture_unit_map.local_to_global[i]
        tex_unit_data.tex_ids[i] = window.tex_id_lookup[global_slot]
    }
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
    vs_filedata, vs_filelen, vs_err := read_entire_file_to_cstring(vs_path, alloc)
    if vs_err != os.ERROR_NONE || vs_filelen == 0 {
        log.errorf("loading vert shader file '{}' failed: {}", vs_path, vs_err)
        return {}, .READ_ERROR
    }
    fs_filedata, fs_filelen, fs_err := read_entire_file_to_cstring(fs_path, alloc)
    if fs_err != os.ERROR_NONE || fs_filelen == 0 {
        log.errorf("loading frag shader file '{}' failed: {}", fs_path, fs_err)
        return {}, .READ_ERROR
    }

    if (vs_err != os.ERROR_NONE) || (fs_err != os.ERROR_NONE) {
        return {}, .PATH_ERROR
    }

    // note(isak): try bindless compilation first. if the driver reports the extension but
    // can't actually compile shaders with sampler arrays in buffer blocks (intel), fall back
    // to the non-bindless path and disable bindless globally for all subsequent shaders
    tried_bindless_path: bool
    if window.bindless_supported {
        vs_source := _shader_inject_define(vs_filedata, vs_filelen, alloc)
        fs_source := _shader_inject_define(fs_filedata, fs_filelen, alloc)

        temp_shader := sg.make_shader({
            vertex_func = {source = vs_source},
            fragment_func = {source = fs_source},
        })

        if sg.query_shader_state(temp_shader) == .VALID {
            return { shader = temp_shader, vs_path = vs_path, fs_path = fs_path }, .NONE
        }

        log.warnf("bindless shader compile failed for '{}' / '{}', falling back to non-bindless", vs_path, fs_path)
        sg.destroy_shader(temp_shader)
        window.bindless_supported = false
        tried_bindless_path = true
    }

    // note(isak): non-bindless path
    temp_shader := sg.make_shader({
        vertex_func = {source = vs_filedata},
        fragment_func = {source = fs_filedata},
    })

    if sg.query_shader_state(temp_shader) == .VALID {
        _shader_setup_sampler_uniforms(temp_shader)
        return { shader = temp_shader, vs_path = vs_path, fs_path = fs_path }, .NONE
    }

    // note(isak): if the bindless backup still fails, we're failing for an unexpected reason. restore state
    window.bindless_supported = tried_bindless_path
    
    sg.destroy_shader(temp_shader)
    return {}, .COMPILE_ERROR
}

_shader_setup_sampler_uniforms :: proc(shader: sg.Shader) {
    info := sg.gl_query_shader_info(shader)
    prog := info.prog
    if prog == 0 do return

    loc := gl.GetUniformLocation(prog, "textures")
    if loc < 0 do return

    // note(isak): set textures[i] = i for each unit
    prev_prog: i32
    gl.GetIntegerv(gl.CURRENT_PROGRAM, &prev_prog)
    gl.UseProgram(prog)
    for i in 0..<i32(MAX_TEXTURE_UNITS) {
        gl.Uniform1i(loc + i, i)
    }
    gl.UseProgram(u32(prev_prog))
}


_shader_inject_define :: proc(source: cstring, source_len: int, alloc: runtime.Allocator) -> cstring {
    src := (cast([^]u8)source)[:source_len]
    // find end of the #version line
    newline_pos := 0
    for i in 0..<source_len {
        if src[i] == '\n' {
            newline_pos = i + 1
            break
        }
    }

    BINDLESS_DEFINE :: "#define BINDLESS\n"
    
    new_len := source_len + len(BINDLESS_DEFINE)
    buf := make([]u8, new_len + 1, alloc) // +1 for null terminator
    copy(buf[:newline_pos], src[:newline_pos])
    copy(buf[newline_pos:], BINDLESS_DEFINE)
    copy(buf[newline_pos + len(BINDLESS_DEFINE):], src[newline_pos:])
    buf[new_len] = 0
    return cstring(raw_data(buf))
}

shader_reinit :: proc(shader: ^Shader, alloc: runtime.Allocator = context.temp_allocator) -> Shader_Error {
    new_shader, err := shader_init(shader.vs_path, shader.fs_path, alloc)
    if err != .NONE {
        assert(err == .COMPILE_ERROR)
        log.error("Shader compile errors found. Paths:", shader.vs_path, shader.fs_path)
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
    CLEAR,
    COLOR_MASK,
    PUSH_TRANSFORM,
    POP_TRANSFORM,
    DRAW,
    DRAW_SLIDER,
    DRAW_MESH,
    BIND_PIPELINE,
    BIND_FRAMEBUFFER,
    BIND_SSBO,
    SCISSOR_MODE,
    POST_PASS,
}

Command_Header :: struct {
    command_type: Command_Type
}

Command_Clear :: struct {
    color: Color,
    depth_only: bool
}

Command_Color_Mask :: struct {
    r, g, b, a: bool
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
    instance_count: i32,
    param_index:    u32, // slot into the frame's slider_param_store ring
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

Command_Draw_Mesh :: struct {
    vertex_count:   i32,
    instance_count: i32,
}

// note(isak): a fullscreen shader pass. draws one quad from fullscreen_store sampling src
// targets, into dst. restores the batch quad buffer + default framebuffer afterward.
Command_Post_Pass :: struct {
    pipeline:   Pipeline_ID,
    dst:        Framebuffer_ID,
    quad_index: u32,
    src:        [4]u32,
    src_count:  u8,
}

Command_Scissor_Mode :: struct {
    x, y, w, h: i32
}

// note(isak): extra data appended after draw in non-bindless mode
Draw_Texture_Units :: struct {
    tex_ids: [MAX_TEXTURE_UNITS]u32,
    count: u8,
}

command_push_clear             :: proc(cmd: Command_Clear) -> bool { return _command_push(cmd, .CLEAR) }
command_push_color_mask        :: proc(cmd: Command_Color_Mask) -> bool { return _command_push(cmd, .COLOR_MASK) }
command_push_push_transform    :: proc(cmd: Command_Push_Transform) -> bool { return _command_push(cmd, .PUSH_TRANSFORM) }
command_push_pop_transform     :: proc() -> bool { return _command_push_header(.POP_TRANSFORM) }
command_push_draw              :: proc(cmd: Command_Draw) -> bool { return _command_push(cmd, .DRAW) }
command_push_draw_slider       :: proc(cmd: Command_Draw_Slider) -> bool { return _command_push(cmd, .DRAW_SLIDER) }
command_push_draw_mesh         :: proc(cmd: Command_Draw_Mesh) -> bool { return _command_push(cmd, .DRAW_MESH) }
command_push_bind_pipeline     :: proc(cmd: Command_Bind_Pipeline) -> bool { return _command_push(cmd, .BIND_PIPELINE) }
command_push_bind_framebuffer  :: proc(cmd: Command_Bind_Framebuffer) -> bool { return _command_push(cmd, .BIND_FRAMEBUFFER) }
command_push_bind_ssbo         :: proc(cmd: Command_Bind_SSBO) -> bool { return _command_push(cmd, .BIND_SSBO) }
command_push_scissor_mode      :: proc(cmd: Command_Scissor_Mode) -> bool { return _command_push(cmd, .SCISSOR_MODE) }
command_push_post_pass         :: proc(cmd: Command_Post_Pass) -> bool { return _command_push(cmd, .POST_PASS) }


_command_push_header :: proc(type: Command_Type) -> bool {
    layer := window.renderer.current_layer
    ok, err := queue.push_back(&window.renderer.layer_command_queues[layer], u8(type))
    assert(err == .None)
    return ok
}

_command_push :: proc(cmd: $T, type: Command_Type) -> bool {
    layer := window.renderer.current_layer
    cmd := cmd
    ok := _command_push_header(type)
    if ok {
        err: runtime.Allocator_Error
        cmd_data: []u8 = slice.from_ptr((^u8)(&cmd), size_of(T))
        ok, err = queue.push_back_elems(&window.renderer.layer_command_queues[layer], ..cmd_data)
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

r_clear :: proc(color: Color = color_black, depth_only: bool = false) {
    window.renderer.new_draw_on_next_push = true
    command_push_clear({ color, depth_only })
}

r_color_mask :: proc(r, g, b, a: bool) {
    window.renderer.new_draw_on_next_push = true
    command_push_color_mask({ r, g, b, a })
}

r_push_draw :: proc(index_offset: u32, index_count: i32, instance_count: i32 = 1, base_instance: u32 = 0) {
    if !window.bindless_supported {
        texture_unit_map_finalize(&window.renderer)
        texture_unit_map_reset(&window.renderer.texture_unit_map)
    }

    command_push_draw({
        index_offset = index_offset,
        index_count = index_count,
        base_instance = base_instance,
        instance_count = instance_count
    })
    cmds := &window.renderer.layer_command_queues[window.renderer.current_layer]
    window.renderer.current_draw = cast(^Command_Draw)&cmds.data[cmds.len - size_of(Command_Draw)]

    // note(isak): append texture unit data right after the draw command (no command header)
    if !window.bindless_supported {
        tex_units := Draw_Texture_Units{}
        tex_data := slice.from_ptr((^u8)(&tex_units), size_of(Draw_Texture_Units))
        queue.push_back_elems(&cmds^, ..tex_data)
        window.renderer.current_draw_tex_units = cast(^Draw_Texture_Units)&cmds.data[cmds.len - size_of(Draw_Texture_Units)]
    }

    window.renderer.new_draw_on_next_push = false
}

_r_framebuffer_resolve :: proc(id: Framebuffer_ID) -> (^GL_Framebuffer, bool) {
    builtin_count := u32(len(Builtin_Framebuffer_Slot))
    if id < builtin_count {
        return &window.framebuffers[Builtin_Framebuffer_Slot(id)], true
    }
    if id < builtin_count + u32(game.active_mapset.render_targets.len) {
        return &queue.get_ptr(&game.active_mapset.render_targets, id - builtin_count).fbo, true
    }
    return nil, false
}

r_bind_framebuffer :: proc(cmd: Command_Bind_Framebuffer) {
    layer_state := &window.renderer.layer_state[window.renderer.current_layer]
    if .FRAMEBUFFER in layer_state.emitted && cmd == layer_state.framebuffer do return
    layer_state.framebuffer = cmd
    layer_state.emitted += {.FRAMEBUFFER}
    window.renderer.current_framebuffer = cmd
    window.renderer.new_draw_on_next_push = true
    command_push_bind_framebuffer(cmd)
}

r_bind_pipeline :: proc(cmd: Command_Bind_Pipeline) {
    layer_state := &window.renderer.layer_state[window.renderer.current_layer]
    if .PIPELINE in layer_state.emitted && cmd == layer_state.pipeline do return
    layer_state.pipeline = cmd
    layer_state.emitted += {.PIPELINE}
    window.renderer.current_pipeline = cmd
    window.renderer.new_draw_on_next_push = true
    command_push_bind_pipeline(cmd)
}


_r_get_ssbo_cmd_from_sbo :: proc(sbo: ^GL_Buffer($T), bind_slot: Shader_SSBO_Bind_Slot) -> Command_Bind_SSBO {
    return Command_Bind_SSBO{ sbo.id, bind_slot, sbo.size, 0 }
}
_r_get_ssbo_cmd_from_tbo :: proc(tbo: ^GL_Triple_Buffer($T), bind_slot: Shader_SSBO_Bind_Slot) -> Command_Bind_SSBO {
    return Command_Bind_SSBO{ tbo.id, bind_slot, tbo.size, tbo.buffers[tbo.current_index].offset }
}

_r_push_ssbo :: proc(cmd: Command_Bind_SSBO) {
    if cmd.slot == .NONE do return
    
    layer_state := &window.renderer.layer_state[window.renderer.current_layer]
    if cmd.slot in layer_state.ssbo_emitted && cmd == layer_state.ssbo[cmd.slot] do return
    layer_state.ssbo[cmd.slot] = cmd
    layer_state.ssbo_emitted += {cmd.slot}
    window.renderer.current_ssbo_binds[cmd.slot] = cmd
    window.renderer.new_draw_on_next_push = true
    command_push_bind_ssbo(cmd)
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

r_bind_ssbo_raw :: proc(id: u32, size: int, bind_slot: Shader_SSBO_Bind_Slot) {
    _r_push_ssbo(Command_Bind_SSBO{ id, bind_slot, size, 0 })
}

r_push_draw_mesh :: proc(vertex_count: i32, instance_count: i32 = 1) {
    window.renderer.new_draw_on_next_push = true
    command_push_draw_mesh({ vertex_count = vertex_count, instance_count = instance_count })
}

r_push_draw_slider :: proc(params: Slider_Params, instance_count: i32) {
    renderer := &window.renderer
    idx := renderer.slider_params.count
    assert(idx < renderer.slider_params.size, "slider param ring overrun")
    renderer.slider_params.data[idx].params = params
    renderer.slider_params.count += 1
    command_push_draw_slider({ instance_count = instance_count, param_index = u32(idx) })
}

// note(isak): clipspace transform maps the fullscreen_store quad ([0,1]) across the entire target
r_post_pass :: proc(pass: Command_Post_Pass, after: Layer) {
    r_bind_layer(after)
    r_push_transform(clipspace_transform)
    command_push_post_pass(pass)
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
    layer_state := &window.renderer.layer_state[window.renderer.current_layer]
    if .TRANSFORM in layer_state.emitted && transform == layer_state.transform do return
    layer_state.transform = transform
    layer_state.emitted += {.TRANSFORM}
    window.renderer.current_global_data.transform = transform
    window.renderer.new_draw_on_next_push = true
    command_push_push_transform({transform})
}

r_pop_transform :: proc() {
    // todo(isak) implement
}

_r_push_scissor :: proc(cmd: Command_Scissor_Mode) {
    layer_state := &window.renderer.layer_state[window.renderer.current_layer]
    if .SCISSOR in layer_state.emitted && cmd == layer_state.scissor do return
    layer_state.scissor = cmd
    layer_state.emitted += {.SCISSOR}
    window.renderer.current_scissor = cmd
    window.renderer.new_draw_on_next_push = true
    command_push_scissor_mode(cmd)
}

r_begin_scissor_mode_pixels :: proc(x, y, w, h: i32) {
    _r_push_scissor(Command_Scissor_Mode{x, y, w, h})
}

r_begin_scissor_mode_rect :: proc(r: Rect) {
    _r_push_scissor(Command_Scissor_Mode{i32(r.x), i32(r.y), i32(r.w), i32(r.h)})
}

r_set_scissor_mode :: proc {
    r_begin_scissor_mode_pixels,
    r_begin_scissor_mode_rect
}

r_reset_scissor_mode :: proc() {
    r_begin_scissor_mode_pixels(0, 0, i32(window.rect.w), i32(window.rect.h))
    window.renderer.new_draw_on_next_push = true
}

r_bind_layer :: proc(layer: Layer) {
    window.renderer.current_layer = layer
    window.renderer.new_draw_on_next_push = true
}

r_check_and_bind_layer :: proc(layer: Layer) {
    if layer != window.renderer.current_layer {
        r_bind_layer(layer)
    }
}

// note(isak): a layer renders into its capture target (Beatmap.capture_layers) or the screen.
// deriving the framebuffer from the layer instead of the leaked current_framebuffer keeps an
// upstream captured layer from dragging later layers (ui, cursor) into its target.
r_layer_framebuffer :: proc(layer: Layer) -> Command_Bind_Framebuffer {
    if game.active_mapset != nil {
        fb := game.active_mapset.layer_capture[layer]
        // note(isak): an uncaptured layer targets DEFAULT; when the map opted into full-frame
        // capture, redirect that to the backbuffer so a post pass can sample the whole frame.
        // the PLATFORM layer is exempt: it always composites onto the real screen, on top of any
        // post-processing.
        if fb == builtin_framebuffer(.DEFAULT) && layer != .PLATFORM && render_to_backbuffer_active() {
            fb = builtin_framebuffer(.BACKBUFFER)
        }
        return { write = fb }
    }
    return {}
}

r_bind_layer_and_push_current_state :: proc(layer: Layer,
    pipeline: Command_Bind_Pipeline = window.renderer.current_pipeline,
    transform: Transform = window.renderer.current_global_data.transform,
    scissor_region: Command_Scissor_Mode = window.renderer.current_scissor
) {
    r_bind_layer(layer)
    r_push_current_state(r_layer_framebuffer(layer), pipeline, transform, scissor_region)
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
    _r_push_scissor(scissor_region)

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
    for &ls in renderer.layer_state {
        ls.emitted      = {}
        ls.ssbo_emitted = {}
    }

    renderer.quad_geometry.data = tbo_advance_and_get(&window.quad_store)
    renderer.quad_geometry.count = 0

    renderer.text_geometry.data = tbo_advance_and_get(&window.text_store)
    renderer.text_geometry.count = 0

    renderer.slider_params.data = tbo_advance_and_get(&window.slider_param_store)
    renderer.slider_params.count = 0

    if !window.bindless_supported {
        texture_unit_map_reset(&renderer.texture_unit_map)
        renderer.current_draw_tex_units = nil
    }

    r_push_draw(0,0)
}

batch_end :: proc(renderer: ^Renderer) {
    tbo_lock(&window.quad_store)
    tbo_lock(&window.text_store)
    tbo_lock(&window.slider_param_store)

    if window.bindless_supported {
        sbo_bind(&window.texture_buffer, u32(Shader_SSBO_Bind_Slot.TEXTURES))
    } else {
        // note(isak): finalize the last in-flight texture bind before processing commands
        texture_unit_map_finalize(renderer)
    }
    ubo_bind(&window.shader_global_buffer, u32(Shader_SSBO_Bind_Slot.TRANSFORM))
    sbo_bind(&window.slider_instance_store, u32(Shader_SSBO_Bind_Slot.INSTANCE_BUFFER))
    ubo_bind(&window.user_param_buffer, u32(Shader_SSBO_Bind_Slot.USER_PARAMS))

    batch_process_command_buffer(renderer)
}

// note(isak): called on a quad-buffer overrun mid-frame. submits everything recorded so far and
// advances to a fresh buffer, staying inside the render pass (owned by begin_frame/end_frame).
batch_flush :: proc(renderer: ^Renderer) {
    batch_end(renderer)
    batch_begin(renderer)
}

// note(isak): builtin quad/text draws into an offscreen target (a layer capture) get rerouted
// through their premultiplied-alpha variants so the captured texture ends up with correct
// premultiplied rgba. consumers compositing a capture back out point element.shader straight at
// QUAD_PREMULTIPLIED_OVER, which isn't quad/text so it passes through here unremapped.
_r_effective_pipeline :: proc(pipeline: Pipeline_ID, write_offscreen: bool) -> Pipeline_ID {
    if write_offscreen {
        if pipeline == builtin_pipeline_slot(.QUAD) do return builtin_pipeline_slot(.QUAD_PREMULTIPLIED)
        if pipeline == builtin_pipeline_slot(.TEXT) do return builtin_pipeline_slot(.TEXT_PREMULTIPLIED)
    }
    return pipeline
}

batch_process_command_buffer :: proc(renderer: ^Renderer) {
    trace := renderer.trace_frame

    // note(isak): the bound pipeline and whether we're writing offscreen both feed pipeline
    // selection, and they change via separate commands, so track them across the whole frame
    // (gl state is continuous between layers) and re-resolve the effective pipeline on either.
    bound_pipeline: Pipeline_ID = builtin_pipeline_slot(.QUAD)
    write_offscreen: bool

    for layer in Layer {
        command_queue := renderer.layer_command_queues[layer]

        if command_queue.len > 0 {
            profiler_gpu_scope_begin(layer)
            if (trace) { fmt.println(layer) }

            // note(isak): the platform layer always composites onto the real screen, on top of any
            // post-processing. its overlays sometimes inherit gl state instead of binding their own
            // target, so pin the default framebuffer (and straight-alpha pipeline) before replaying.
            if layer == .PLATFORM {
                fbo_bind(0, 0)
                write_offscreen = false
                sg.apply_pipeline(window.pipelines.data[_r_effective_pipeline(bound_pipeline, write_offscreen)])
            }
        }

        for command_queue.len > 0 {
            cmd_type := queue.pop_front(&command_queue)

            switch Command_Type(cmd_type) {
                case .CLEAR: {
                    cmd := _command_consume(&command_queue, Command_Clear)
                    color := color_to_vec(cmd.color)

                    // note(isak): glClear obeys the depth write mask, and flat pipelines now leave it
                    // off - which would silently skip the depth clear and leave stale depth for meshes
                    // to fail against. force it on for the clear, then restore the bound pipeline's mask.
                    gl.DepthMask(true)
                    if cmd.depth_only {
                        gl.ClearDepth(f64(color.a))
                        gl.Clear(gl.DEPTH_BUFFER_BIT)
                    } else {
                        gl.ClearColor(color.r, color.g, color.b, color.a)
                        gl.ClearDepth(1.0)
                        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
                    }
                    gl.DepthMask(pipeline_writes_depth(_r_effective_pipeline(bound_pipeline, write_offscreen)))

                    if (trace) { 
                        fmt.println("  clear depth" if cmd.depth_only else "  clear") 
                    }
                }
                case .COLOR_MASK: {
                    cmd := _command_consume(&command_queue, Command_Color_Mask)
                    gl.ColorMask(cmd.r, cmd.g, cmd.b, cmd.a)
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

                    if !window.bindless_supported {
                        tex_units := _command_consume(&command_queue, Draw_Texture_Units)
                        for i in 0..<tex_units.count {
                            gl.BindTextureUnit(u32(i), tex_units.tex_ids[i])
                        }
                    }

                    sg.draw(cmd.index_offset, cmd.index_count, cmd.instance_count)

                    if (trace) { fmt.println("  draw", cmd.index_offset, cmd.index_count, cmd.instance_count, cmd.base_instance ) }
                }
                case .DRAW_MESH: {
                    cmd := _command_consume(&command_queue, Command_Draw_Mesh)
                    gl.DrawArrays(gl.TRIANGLES, 0, cmd.vertex_count * cmd.instance_count)

                    if (trace) { fmt.println("  draw_mesh", cmd.vertex_count, cmd.instance_count) }
                }
                case .DRAW_SLIDER: {
                    cmd := _command_consume(&command_queue, Command_Draw_Slider)

                    store := &window.slider_param_store
                    slot_offset := store.buffers[store.current_index].offset + int(cmd.param_index) * size_of(Slider_Params_Slot)
                    gl.BindBufferRange(
                        gl.UNIFORM_BUFFER,
                        u32(Shader_SSBO_Bind_Slot.SLIDER_PARAMS),
                        store.id,
                        slot_offset,
                        size_of(Slider_Params))

                    gl.DrawArraysInstanced(
                        gl.TRIANGLE_FAN,
                        0,
                        renderer.circle_geometry.count,
                        cmd.instance_count)

                    if (trace) { fmt.println("  drawslider", cmd.instance_count, cmd.param_index) }
                }
                case .BIND_PIPELINE: {
                    cmd := _command_consume(&command_queue, Command_Bind_Pipeline)

                    bound_pipeline = cmd.pipeline
                    sg.apply_pipeline(window.pipelines.data[_r_effective_pipeline(bound_pipeline, write_offscreen)])

                    if (trace) { fmt.println("  pipeline", cmd.pipeline) }
                }
                case .BIND_FRAMEBUFFER: {
                    cmd := _command_consume(&command_queue, Command_Bind_Framebuffer)

                    read, read_ok := _r_framebuffer_resolve(cmd.read)
                    write, write_ok := _r_framebuffer_resolve(cmd.write)
                    write_id := write.id if write_ok else 0
                    fbo_bind(read.id if read_ok else 0, write_id)

                    // note(isak): a fb change alone can flip the premultiplied routing (render_drawable
                    // binds its pipeline before its target), so re-apply the bound pipeline here.
                    write_offscreen = write_id != 0
                    sg.apply_pipeline(window.pipelines.data[_r_effective_pipeline(bound_pipeline, write_offscreen)])

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
                    // note(isak): GL expects y=0 to be the bottom, but our convention is the top, so we transform
                    gl.Scissor(cmd.x, i32(window.rect.h) - cmd.y - cmd.h, max(cmd.w, 0), max(cmd.h, 0))

                    if (trace) { fmt.println("  scissor", cmd.x, cmd.y, cmd.w, cmd.h) }
                }
                case .POST_PASS: {
                    cmd := _command_consume(&command_queue, Command_Post_Pass)

                    dst, ok := _r_framebuffer_resolve(cmd.dst)
                    if ok {
                        gl.Viewport(0, 0, dst.w if dst.id != 0 else i32(window.rect.w), dst.h if dst.id != 0 else i32(window.rect.h))

                        post_params: Post_Pass_Params
                        if window.bindless_supported {
                            post_params.src = cmd.src
                        } else {
                            for i in 0..<cmd.src_count {
                                gl.BindTextureUnit(u32(i), window.tex_id_lookup[cmd.src[i]])
                                post_params.src[i] = u32(i)
                            }
                        }
                        gl.NamedBufferSubData(window.post_param_buffer.id, 0, size_of(Post_Pass_Params), &post_params)
                        ubo_bind(&window.post_param_buffer, u32(Shader_SSBO_Bind_Slot.POST_PARAMS))

                        sbo_bind(&window.fullscreen_store, u32(Shader_SSBO_Bind_Slot.VERTEX_BUFFER))
                        sg.apply_pipeline(window.pipelines.data[cmd.pipeline])
                        fbo_bind(0, dst.id)

                        sg.draw(cmd.quad_index * 6, 6, 1)

                        // note(isak): hand the batch's quad buffer + default target back to whatever draws next
                        tbo_bind(&window.quad_store, u32(Shader_SSBO_Bind_Slot.VERTEX_BUFFER))
                        fbo_bind(0, 0)
                        gl.Viewport(0, 0, i32(window.rect.w), i32(window.rect.h))

                        // note(isak): the post pass set its own pipeline + restored the default
                        // target out from under our trackers; keep them in sync for the next bind.
                        bound_pipeline = cmd.pipeline
                        write_offscreen = false
                    }

                    if (trace) { fmt.println("  post_pass", cmd.pipeline, cmd.dst, cmd.quad_index) }
                }
            }
        }
        profiler_gpu_scope_end()
    }
    renderer.trace_frame = false
}


///////////////////////////////////////////////////////////////////////////
// note(isak): draw api - PS: we use our nice global window.renderer here to make the api easier

r_draw_quad_with_uv :: proc(geometry: ^Buffer(Quad), pos_min, pos_max, uv_min, uv_max: vec2,
                          color: Color, tex_index: u32, angle: f32 = 0, layer: f32 = 0) {
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

    resolved_tex_index := tex_index

    // note(isak): non-bindless path that remap global texture slots to a local texture unit.
    // this must happen AFTER the new_draw_on_next_push check so the texture is assigned
    // to the correct draw's unit map.
    if !window.bindless_supported {
        local := texture_unit_map_assign(&window.renderer.texture_unit_map, tex_index)
        if local == UNMAPPED_UNIT {
            // note(isak): hit 16 texture units, start a new draw and retry
            r_push_draw(
                index_offset = u32(geometry.count) * 6,
                index_count = 0
            )
            local = texture_unit_map_assign(&window.renderer.texture_unit_map, tex_index)
            assert(local != UNMAPPED_UNIT)
        }
        resolved_tex_index = u32(local)
    }

    #no_bounds_check {
        vert_i := geometry.count
        verts := geometry.data

        verts[vert_i] = {
            pos_min = pos_min,
            pos_max = pos_max,
            uv_min = {uv_min.x, uv_min.y},
            uv_max = {uv_max.x, uv_max.y},
            tex_layer = layer,
            color = transmute(u32)color,
            tex_index = resolved_tex_index,
            angle = angle
        }

        geometry.count += 1
        window.renderer.current_draw.index_count += 6
    }
}

r_draw_quad :: proc(geometry: ^Buffer(Quad), pos_min, pos_max, uv_min, uv_max: vec2,
                    color: Color, tex_index: u32 = 0, angle: f32 = 0, layer: f32 = 0) {
    r_draw_quad_with_uv(geometry, pos_min, pos_max, uv_min, uv_max, color, tex_index, angle, layer)
}

r_draw_rect :: proc(geometry: ^Buffer(Quad), r: Rect,
                    color: Color, tex_index: u32 = 0, angle: f32 = 0, layer: f32 = 0) {
    r_draw_quad_with_uv(geometry, {r.x, r.y}, {r.x + r.w, r.y + r.h},
                                {0, 0}, {1, 1}, color, tex_index, angle, layer)
}

r_draw_rect_with_uv :: proc(geometry: ^Buffer(Quad), r, uv: Rect,
                            color: Color, tex_index: u32 = 0, angle: f32 = 0, layer: f32 = 0) {
    r_draw_quad_with_uv(geometry, {r.x, r.y}, {r.x + r.w, r.y + r.h},
                                {uv.x, uv.y}, {uv.x + uv.w, uv.y + uv.h}, color, tex_index, angle, layer)
}

r_draw_layout_rect :: proc(geometry: ^Buffer(Quad), rect: Rect, anchor: Layout_Anchor,
                           color: Color = color_white, tex_index: u32 = 0, angle: f32 = 0, layer: f32 = 0) {
    r_draw_rect(geometry, rect_translate_by_anchor(rect, anchor), color, tex_index, angle, layer)
}


// todo(isak): thickness doesn't really work anymore... should prolly fetch scale from current transform
// todo(isak): add angle, but that requires placing the rects on the middle of each side with respect to it
r_draw_rect_outline :: proc(geometry: ^Buffer(Quad), rect: Rect, color: Color, thickness_px: f32) {
    //xform := window.renderer.current_global_data

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

transform_point_space :: proc(pt: vec2, source_to_common: mat3, dest_to_common: mat3) -> vec2 {
    h_pt := vec3{pt.x, pt.y, 1.0}
    h_pt = linalg.matrix3_inverse(dest_to_common) * source_to_common * h_pt
    return h_pt.xy
}


transform_rect_to_screen_corners :: proc(r: Rect, playfield_to_ndc: mat3, screen_to_ndc: mat3) -> [4]vec2 {
    corners := [4]vec2{
        {r.x,       r.y},
        {r.x + r.w, r.y},
        {r.x + r.w, r.y + r.h},
        {r.x,       r.y + r.h},
    }
    for i in 0..<4 {
        corners[i] = transform_point_space(corners[i], playfield_to_ndc, screen_to_ndc)
    }
    return corners
}

calculate_aabb_from_corners :: proc(corners: [4]vec2) -> Rect {
    min_pt := corners[0]
    max_pt := corners[0]
    for i in 1..<4 {
        min_pt.x = min(min_pt.x, corners[i].x)
        min_pt.y = min(min_pt.y, corners[i].y)
        max_pt.x = max(max_pt.x, corners[i].x)
        max_pt.y = max(max_pt.y, corners[i].y)
    }
    return {min_pt.x, min_pt.y, max_pt.x - min_pt.x, max_pt.y - min_pt.y}
}


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
