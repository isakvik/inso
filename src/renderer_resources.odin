package notosu

import "core:math"
import "core:container/queue"

import gl "vendor:OpenGL"
import sg "vendor:sokol/gfx"


quad_vs_path :: "shaders/quad.vs.glsl"
quad_fs_path :: "shaders/quad.fs.glsl"

slider_vs_path :: "shaders/slider.vs.glsl"
slider_fs_path :: "shaders/slider.fs.glsl"

text_vs_path :: "shaders/text.vs.glsl"
text_fs_path :: "shaders/text.fs.glsl"


// todo(isak): unused indexer, see texture_kind
Pipeline_Kind :: enum u8 {
    BUILTIN,
    MAP_SPECIFIC,
}
Pipeline_Index :: struct {
    kind: Pipeline_Kind,
    index: u8,
}

Pipeline_ID :: u32

Builtin_Shader_Slot :: enum {
    QUAD,
    SLIDER,
    TEXT,
}

builtin_shader_slot :: proc(s: Builtin_Shader_Slot) -> u32 {
    return u32(s)
}

Builtin_Pipeline_Slot :: enum {
    QUAD,
    QUAD_PREMULTIPLIED,
    QUAD_PREMULTIPLIED_OVER,
    SLIDER,
    TEXT,
    TEXT_PREMULTIPLIED,
}

builtin_pipeline_slot :: proc(s: Builtin_Pipeline_Slot) -> u32 {
    return u32(s)
}

user_pipeline_slot :: proc(s: u32) -> u32 {
    return len(Builtin_Pipeline_Slot) + s
}

Framebuffer_ID :: u32

Builtin_Framebuffer_Slot :: enum u32 {
    DEFAULT,
    SLIDERS,
}

builtin_framebuffer :: proc(s: Builtin_Framebuffer_Slot) -> Framebuffer_ID { return Framebuffer_ID(s) }
user_framebuffer :: proc(i: u32) -> Framebuffer_ID { return i + len(Builtin_Framebuffer_Slot) }

Shader_SSBO_Bind_Slot :: enum u32 {
    NONE,
    VERTEX_BUFFER,
    INDEX_BUFFER,
    TRANSFORM,
    TEXTURES,
    INSTANCE_BUFFER,
    SLIDER_PARAMS, // todo(isak): this is implemented as a UBO, should use its own slot namespace
    USER_PARAMS,   // user-accessible f32[64] UBO, always bound; binding 7
    USER_0,        // user-bindable SSBO slots; binding 8-15
    USER_1,
    USER_2,
    USER_3,
    USER_4,
    USER_5,
    USER_6,
    USER_7,
    POST_PARAMS,   // post-pass src texture slots UBO; binding 16
}

// note(isak): always-bound UBO for Lua-accessible shader params (Shader.set_param / set_vec4).
// the 64 floats are tightly packed here; in std140 a `float[]` array has a 16-byte stride, so
// shaders must read them as a vec4 array to match this layout:
//   layout(std140, binding=7) uniform UserParams { vec4 params[16]; };
// the i-th float written by Shader.set_param(i, v) is then params[i/4][i%4].
User_Shader_Params :: struct #align(16) {
    data: [64]f32,
}

// note(isak): per-pass src texture slots for post passes.
// shaders access it as: layout(std140, binding=16) uniform PostParams { uvec4 srcSlots; };
Post_Pass_Params :: struct #align(16) {
    src: [4]u32,
}

// note(isak): per-draw slider params, uploaded before each DRAW_SLIDER command
Slider_Params :: struct {
    border_color:       vec4,
    body_color:         vec4,
    script_translation: vec2,  // osupx, applied in VS before coord normalization
    base_instance:      u32,   // replaces gl_BaseInstance for intel compat
    radius_osupx:       f32,   // per-object radius, used in VS instead of global circleSizeOsupx
}


Builtin_Texture_Slot :: enum u32 {
    WHITE,
    PROFILER,
    FONT_ATLAS,
    SLIDER_FRAMEBUFFER
}


// todo(isak): unused, but it might be better to index with this just for invariant purposes
Texture_Kind :: enum u32 {
    RESERVED,
    SKIN,
    MAP,
}

Texture_Index :: struct {
    kind: Texture_Kind,
    index: u32
}

// note(isak): map textures and render targets share the global slot space after the builtin and skin
// slots, so this is how many of them can coexist before we run out of texture handles.
MAX_USER_TEXTURES :: MAX_TEXTURE_HANDLES - len(Builtin_Texture_Slot) - len(Skin_Element_Type)

// note(isak): these return indices into the bindless texture buffer
builtin_texture :: proc(slot: Builtin_Texture_Slot) -> u32 { return u32(slot) }
skin_texture :: proc(skin_el: Skin_Element_Type) -> u32 { return u32(skin_el) + len(Builtin_Texture_Slot) }
user_texture :: proc(tex_id: u32) -> u32 { return tex_id + len(Builtin_Texture_Slot) + len(Skin_Element_Type) }



Blend_Mode :: enum {
    NONE,
    ALPHA,
    ADDITIVE,
    MAX,
    PREMULTIPLIED,
    PREMULTIPLIED_OVER,
}

blend_state_for_mode :: proc(mode: Blend_Mode) -> (blend: sg.Blend_State) {
    switch mode {
    case .NONE:
        blend = { enabled = false }
    case .ALPHA:
        blend = {
            enabled          = true,
            op_alpha         = .SUBTRACT,
            src_factor_rgb   = .SRC_ALPHA,
            src_factor_alpha = .SRC_ALPHA,
            dst_factor_rgb   = .ONE_MINUS_SRC_ALPHA,
            dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        }
    case .PREMULTIPLIED:
        // note(isak): takes straight-alpha shader output and accumulates a correctly premultiplied
        // result: rgb = src.rgb*src.a + dst.rgb*(1-src.a), a = src.a + dst.a*(1-src.a). unlike
        // .ALPHA's screen-tuned alpha, this produces a coverage alpha valid for re-sampling. draw
        // the resulting texture back with premultiplied-over (src factor ONE) to composite it.
        blend = {
            enabled          = true,
            op_rgb           = .ADD,
            op_alpha         = .ADD,
            src_factor_rgb   = .SRC_ALPHA,
            src_factor_alpha = .ONE,
            dst_factor_rgb   = .ONE_MINUS_SRC_ALPHA,
            dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        }
    case .PREMULTIPLIED_OVER:
        // note(isak): composites an already-premultiplied source (e.g. a captured render target)
        // over the destination: rgb = src.rgb + dst.rgb*(1-src.a). the src rgb is taken as-is
        // (factor ONE) rather than re-multiplied by alpha, which is what .ALPHA would wrongly do.
        blend = {
            enabled          = true,
            op_rgb           = .ADD,
            op_alpha         = .ADD,
            src_factor_rgb   = .ONE,
            src_factor_alpha = .ONE,
            dst_factor_rgb   = .ONE_MINUS_SRC_ALPHA,
            dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        }
    case .ADDITIVE:
        blend = {
            enabled          = true,
            src_factor_rgb   = .ONE,
            dst_factor_rgb   = .ONE,
            op_rgb           = .ADD,
            src_factor_alpha = .ONE,
            dst_factor_alpha = .ONE,
            op_alpha         = .ADD,
        }
    case .MAX: 
        blend = {
            enabled          = true,
            op_alpha         = .MAX,
            src_factor_rgb   = .ONE,
            src_factor_alpha = .ONE,
            dst_factor_rgb   = .ONE,
            dst_factor_alpha = .ONE,
        }
    }
    return blend
}

//////////////////////////////////////////////////////
// note(isak): pipeline definitions

quad_pipeline_desc :: proc(blend: Blend_Mode = .ALPHA) -> sg.Pipeline_Desc {
    return {
        label = "builtin.quad",
        shader = window.shaders.data[builtin_shader_slot(.QUAD)].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = blend_state_for_mode(blend) }
        },
        depth = {compare = .LESS_EQUAL, write_enabled = true},
    },
}

slider_pipeline_desc :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.slider",
        shader = window.shaders.data[builtin_shader_slot(.SLIDER)].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 0.0}, // note(isak): clears to 0 alpha so black transparency works
        depth = {compare = .LESS_EQUAL, write_enabled = true},
    }
}

text_pipeline_desc :: proc(blend: Blend_Mode = .ALPHA) -> sg.Pipeline_Desc {
    return {
        label = "builtin.text",
        shader = window.shaders.data[builtin_shader_slot(.TEXT)].shader,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = blend_state_for_mode(blend) }
        },
        //depth = {compare = .LESS_EQUAL, write_enabled = true},
    },
}


//////////////////////////////////////////////////////
// note(isak): texture api

/*
    note(isak): textures are initialized with bindless handles and written to a SSBO-based array. 
    this array is indexed with three kinds of IDs:
    - reserved slots
    - skin slots
    - map slots
    only map slots are dynamic since the rest depends on what we handle in code, so we write those in during map load

    todo(isak): i don't actually know the texture resource limits; every resource being active at the same time
    may break horrifically down the line, but at that point we should have a decent amount of test scenes for me 
    to write a packing system or another way of handling multi-texture draws that doesn't hit the limit
*/
prepare_textures_for_rendering :: proc() {
    num_elements := len(Builtin_Texture_Slot)

    if window.bindless_supported {
        textures := &window.texture_buffer.data
        textures[Builtin_Texture_Slot.WHITE] = window.white_texture.tex_handle
        textures[Builtin_Texture_Slot.PROFILER] = window.profiler_texture.tex_handle
        textures[Builtin_Texture_Slot.FONT_ATLAS] = window.font_atlas_texture.tex_handle
        textures[Builtin_Texture_Slot.SLIDER_FRAMEBUFFER] = window.framebuffers[.SLIDERS].color_texture_handles[0]

        for skin_el in Skin_Element_Type {
            textures[num_elements] = window.skin_textures[skin_el].tex_handle
            num_elements += 1
        }
        for i in 0..<int(game.active_mapset.textures.len) {
            if num_elements >= MAX_TEXTURE_HANDLES do break
            textures[num_elements] = queue.get_ptr(&game.active_mapset.textures, uint(i)).tex_handle
            num_elements += 1
        }
        for i in 0..<game.active_mapset.render_targets.len {
            if num_elements >= MAX_TEXTURE_HANDLES do break
            rt := queue.get_ptr(&game.active_mapset.render_targets, uint(i))
            textures[num_elements] = rt.fbo.color_texture_handles[0]
            num_elements += 1
        }
        for i in 0..<num_elements {
            if textures[i] > 0 {
                gl.MakeTextureHandleResidentARB(textures[i])
            }
        }
    } else {
        ids := &window.tex_id_lookup
        ids[Builtin_Texture_Slot.WHITE] = window.white_texture.tex_id
        ids[Builtin_Texture_Slot.PROFILER] = window.profiler_texture.tex_id
        ids[Builtin_Texture_Slot.FONT_ATLAS] = window.font_atlas_texture.tex_id
        ids[Builtin_Texture_Slot.SLIDER_FRAMEBUFFER] = window.framebuffers[.SLIDERS].color_textures[0]

        for skin_el in Skin_Element_Type {
            ids[num_elements] = window.skin_textures[skin_el].tex_id
            num_elements += 1
        }
        for i in 0..<int(game.active_mapset.textures.len) {
            if num_elements >= MAX_TEXTURE_HANDLES do break
            ids[num_elements] = queue.get_ptr(&game.active_mapset.textures, uint(i)).tex_id
            num_elements += 1
        }
        for i in 0..<game.active_mapset.render_targets.len {
            if num_elements >= MAX_TEXTURE_HANDLES do break
            rt := queue.get_ptr(&game.active_mapset.render_targets, uint(i))
            ids[num_elements] = rt.fbo.color_textures[0]
            num_elements += 1
        }
    }
}

cleanup_textures_for_rendering :: proc() {
    if !window.bindless_supported do return

    textures := &window.texture_buffer.data
    num_elements := min(len(Builtin_Texture_Slot) + len(Skin_Element_Type) + game.active_mapset.textures.len + game.active_mapset.render_targets.len, MAX_TEXTURE_HANDLES)
    for i in 0..<num_elements {
        if textures[i] > 0 {
            gl.MakeTextureHandleNonResidentARB(textures[i])
        }
    }
}


populate_slider_circle_vertices :: proc(geometry: ^Buffer(Slider_Vertex)) {
    #no_bounds_check {
        vert_i := geometry.count
        verts := geometry.data

        // note(isak): the middle of our circle is raised for depth testing
        verts[vert_i + 0] = { pos = { 0, 0, 1 } }
        verts[vert_i + 1 + UNIT_CIRCLE_VERTEX_COUNT] = { pos = { 0, 1, 0 } }

        th: f32
        it_angle := math.TAU * (f32(1) / UNIT_CIRCLE_VERTEX_COUNT)
        for i in 0..<UNIT_CIRCLE_VERTEX_COUNT {
            verts[int(vert_i) + i + 1] = { 
                pos = { math.sin_f32(th), math.cos_f32(th), 0 }
            }
            th += it_angle
        }

        geometry.count = 2 + UNIT_CIRCLE_VERTEX_COUNT
    }
}
