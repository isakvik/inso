package notosu

import "base:runtime"
import "core:mem"
import "core:math/linalg"
import "core:fmt"
import "core:math"
import os "core:os/os2"
import "core:slice"
import "core:strings"
import "core:container/queue"

import gl "vendor:OpenGL"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"


quad_vs_path :: "shaders/main.vs.glsl"
quad_fs_path :: "shaders/main.fs.glsl"

slider_vs_path :: "shaders/slider.vs.glsl"
slider_fs_path :: "shaders/slider.fs.glsl"

text_vs_path :: "shaders/text.vs.glsl"
text_fs_path :: "shaders/text.fs.glsl"

Shader_ID :: enum {
    QUAD,
    SLIDER,
    TEXT
}


batch_max_vertices :: 64*1024
max_texture_handles :: 1024
//max_slider_draw_commands :: 1024


Reserved_Texture_Slots :: enum u32 {
    WHITE,
    PROFILER,
    FONT_ATLAS,
    SLIDER_FRAMEBUFFER
}

reserved_texture :: proc(slot: Reserved_Texture_Slots) -> u32 { return u32(slot) }


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



Transform :: struct {
    bounds_rect: vec4,
    aspect_ratio: f32,
}

default_transform :: Transform{
    bounds_rect = {-1, -1, 2, 2},
    aspect_ratio = 1
}


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

_Rect :: struct($T: typeid) {
    x, y, w, h: T,
}

Rect :: _Rect(f32)
Window_Rect :: _Rect(i32) // note(isak): window space rect measured in pixels

max_active_texture_resource_size :: 128 * 1024 * 1024

unit_circle_vertex_count :: 32

//////////////////////////////////////////////////////
// note(isak): resource api

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

    err: Shader_Error
    window.shaders[.QUAD], err = init_shader(quad_vs_path, quad_fs_path, quad_uniform_desc())
    assert(err == .NONE)
    window.quad_pipeline = sg.make_pipeline(quad_pipeline())

    window.shaders[.SLIDER], err = init_shader(slider_vs_path, slider_fs_path, slider_uniform_desc())
    assert(err == .NONE)
    window.slider_pipeline = sg.make_pipeline(slider_pipeline())
    
    window.shaders[.TEXT], err = init_shader(text_vs_path, text_fs_path, text_uniform_desc())
    assert(err == .NONE)
    window.text_pipeline = sg.make_pipeline(text_pipeline())
    

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
        width = window.rect.w,
        height = window.rect.h,
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
        {-1,-1,2,2}, {1,1,1,0.5}, reserved_texture(.SLIDER_FRAMEBUFFER))
    
    //
    
    renderer.text_geometry.size = batch_max_vertices
    

    commit_transform({
        bounds_rect = {-1,-1,2,2},
        aspect_ratio = window.aspect_ratio
    })

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
// note(isak): pipeline definitions

quad_pipeline :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.quad",
        shader = window.shaders[.QUAD].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = [4]sg.Color_Target_State {
            0 = { blend = {
                enabled = true,
                op_alpha = .SUBTRACT,
                src_factor_rgb = .SRC_ALPHA,
                src_factor_alpha = .SRC_ALPHA,
                dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            }}
        },
        depth = {compare = .LESS_EQUAL, write_enabled = true},
    },
}

slider_pipeline :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.slider",
        shader = window.shaders[.SLIDER].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = [4]sg.Color_Target_State {
            0 = { blend = {
                enabled = false,
                op_alpha = .MAX,
                src_factor_rgb = .ONE,
                src_factor_alpha = .ONE,
                dst_factor_rgb = .ONE,
                dst_factor_alpha = .ONE,
            }}
        },
        depth = {compare = .LESS_EQUAL, write_enabled = true},
    }
}

text_pipeline :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.text",
        shader = window.shaders[.TEXT].shader,
        index_type = .NONE,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = [4]sg.Color_Target_State {
            0 = { blend = {
                enabled = true,
                op_alpha = .ADD,
                src_factor_rgb = .SRC_ALPHA,
                dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                src_factor_alpha = .SRC_ALPHA,
                dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            }}
        },
        //depth = {compare = .LESS_EQUAL, write_enabled = true},
    },
}

// note(isak): i didn't get these to work... might not be better than ssbos anyway
quad_uniform_desc :: proc() -> [8]sg.Shader_Uniform_Block { return {} }
slider_uniform_desc :: proc() -> [8]sg.Shader_Uniform_Block { return {} }
text_uniform_desc :: proc() -> [8]sg.Shader_Uniform_Block { return {} }


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
    SET_BOUNDS,
    SET_MODE,
    CLEAR,
    DRAW,
    DRAW_SLIDER,
}

Command_Mode_Type :: enum(u8) {
    QUAD_UV,
    TEXT,
    BEGIN_SLIDERS,
    END_SLIDERS
}

Command_Header :: struct {
    command_type: Command_Type
}

Command_Set_Bounds :: struct {
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

Command_Draw_Text :: struct {
    glyph_offset: i32,
    glyph_count: i32,
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

command_push_set_bounds :: proc(cmd: Command_Set_Bounds) -> bool {
    return _command_push(cmd, .SET_BOUNDS)
}

command_push_set_mode :: proc(cmd: Command_Set_Mode) -> bool {
    return _command_push(cmd, .SET_MODE)
}

command_push_clear :: proc() -> bool {
    return _command_push_header(.CLEAR)
}

command_push_draw :: proc(cmd: Command_Draw) -> bool { 
    return _command_push(cmd, .DRAW)
}

command_push_draw_slider :: proc(cmd: Command_Draw_Slider) -> bool { 
    return _command_push(cmd, .DRAW_SLIDER)
}

//////////////////////////////////////////////////////
// note(isak): texture api

prepare_textures_for_rendering :: proc() {
    textures := &window.texture_buffer.data

    textures[Reserved_Texture_Slots.WHITE] = window.white_texture.tex_handle
    textures[Reserved_Texture_Slots.PROFILER] = window.profiler_texture.tex_handle
    textures[Reserved_Texture_Slots.FONT_ATLAS] = window.font_atlas_texture.tex_handle
    textures[Reserved_Texture_Slots.SLIDER_FRAMEBUFFER] = window.slider_framebuffer.color_texture_handles[0]
    num_elements := len(Reserved_Texture_Slots)

    for element in Skin_Element {
        textures[num_elements] = window.skin_textures[element].tex_handle
        num_elements += 1
    }

    for i in 0..<num_elements {
        gl.MakeTextureHandleResidentARB(textures[i])
    }
}

cleanup_textures_for_rendering :: proc() {
    textures := &window.texture_buffer.data
    
    num_elements := len(Reserved_Texture_Slots) + len(Skin_Element)
    for i in 0..<num_elements {
        gl.MakeTextureHandleNonResidentARB(textures[i])
    }
}


///////////////////////////////////////////////////////////////////////////
// note(isak): draw api - PS: we use our nice global window.renderer here to make the api easier

commit_transform :: proc(transform: Transform) {
    transform := transform
    buf := &window.transform_buffer
    gl.NamedBufferSubData(buf.id, 0, buf.size, &transform)
}

reset_transform :: proc() {
    push_transform(default_transform)
}

push_transform :: proc(transform: Transform) -> bool {
    return command_push_set_bounds({
        transform = transform
    })
}

/*
    note(isak): this takes care of draw command stats for the previously set current draw;
                we don't need an end_draw() as far as i can tell (except to avoid branching)
*/
begin_draw_with_transform :: proc(transform: Transform) -> bool {
    renderer := &window.renderer

    command_push_set_bounds({
        transform = transform
    }) or_return

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

push_rect :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: _Rect(f32), color: vec4, tex_index: u32 = 0) {
    push_quad_with_uvs(geometry, {rect.x,          rect.y         }, {0, 0},
                                 {rect.x,          rect.y + rect.h}, {0, 1},
                                 {rect.x + rect.w, rect.y         }, {1, 0},
                                 {rect.x + rect.w, rect.y + rect.h}, {1, 1}, color, tex_index)
}

push_screenspace_rect :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: Window_Rect, color: vec4, tex_index: u32 = 0) {
    push_rect(geometry, to_clipspace_rect(rect), color, tex_index)
}

push_layout_rect :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: _Rect($T), anchor: Layout_Anchor, color: vec4, tex_index: u32 = 0) {
    push_rect(geometry, rect_translate_by_anchor(rect, anchor), color, tex_index) 
}

push_screenspace_layout_rect :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: _Rect($T), anchor: Layout_Anchor, color: vec4, tex_index: u32 = 0) {
    push_screenspace_rect(geometry, rect_translate_by_anchor(rect, anchor), color, tex_index) 
}


populate_slider_circle_vertices :: proc(geometry: ^Buffer(Slider_Vertex)) {
    #no_bounds_check {
        vert_i := geometry.count
        verts := geometry.data

        // note(isak): the middle of our circle is raised for depth testing
        verts[vert_i + 0] = { pos = { 0, 0, 1 } }
        verts[vert_i + 1 + unit_circle_vertex_count] = { pos = { 0, 1, 0 } }

        th: f32
        it_angle := math.TAU * (f32(1) / unit_circle_vertex_count)
        for i in 0..<unit_circle_vertex_count {
            verts[int(vert_i) + i + 1] = { 
                pos = { math.sin_f32(th), math.cos_f32(th), 0 }
            }
            th += it_angle
        }

        geometry.count = 2 + unit_circle_vertex_count
    }
}

//////////////////////////////////////////////////////
// note(isak): layout api

rect_translate_by_anchor :: proc(rect: _Rect($T), anchor: Layout_Anchor) -> _Rect(T) {
    result := _Rect(T) {
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

rect_f32_translate_to_inner_f32 :: proc(inner, outer: _Rect(f32)) -> _Rect(f32) {
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

rect_u32_translate_to_inner_u32 :: proc(inner, outer: Window_Rect) -> Window_Rect {
    return {
        x = outer.x + inner.x,
        y = outer.y + inner.y,
        w = inner.w,
        h = inner.h
    }
}

rect_f32_translate_to_inner_u32 :: proc(inner: _Rect(f32), outer: Window_Rect) -> Window_Rect {
    if outer.w <= 0 || outer.h <= 0 {
        return {
            x = outer.x,
            y = outer.y
        }
    }
    return {
        x = outer.x + i32(inner.x * f32(outer.w)),
        y = outer.y + i32(inner.y * f32(outer.h)),
        w = i32(inner.w * f32(outer.w)),
        h = i32(inner.h * f32(outer.h))
    }
}

rect_translate_to_inner :: proc {
    rect_f32_translate_to_inner_f32,
    rect_u32_translate_to_inner_u32,
    rect_f32_translate_to_inner_u32,
}


to_clipspace_rect :: proc(rect: Window_Rect) -> _Rect(f32) {
    inv_ar := f32(window.rect.w) / f32(window.rect.h)
    return {
        x = (f32(rect.x) / f32(window.rect.w) * 2 * inv_ar) - inv_ar,
        y = (f32(rect.y) / f32(window.rect.h) * 2) - 1,
        w = (f32(rect.w) / f32(window.rect.w) * 2 * inv_ar),
        h = (f32(rect.h) / f32(window.rect.h) * 2),
    }
}

to_screenspace_rect :: proc(rect: _Rect(f32)) -> Window_Rect {
    return {
        x = i32(rect.x * f32(window.rect.w)),
        y = i32(rect.y * f32(window.rect.h)),
        w = i32(rect.w * f32(window.rect.w)),
        h = i32(rect.h * f32(window.rect.h))
    }
}
