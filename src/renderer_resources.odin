package inso

import "core:math"
import "core:container/queue"

import gl "vendor:OpenGL"
import sg "vendor:sokol/gfx"


quad_vs_path :: "shaders/quad.vs.glsl"
quad_fs_path :: "shaders/quad.fs.glsl"

slider_vs_path :: "shaders/slider.vs.glsl"
slider_fs_path :: "shaders/slider.fs.glsl"
slider_present_fs_path :: "shaders/slider_present.fs.glsl"

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
    SLIDER_PRESENT,
}

builtin_shader_slot :: proc(s: Builtin_Shader_Slot) -> u32 {
    return u32(s)
}

Builtin_Pipeline_Slot :: enum {
    QUAD,
    QUAD_PREMULTIPLIED,
    QUAD_PREMULTIPLIED_OVER,
    QUAD_ADDITIVE,
    SLIDER,
    TEXT,
    TEXT_PREMULTIPLIED,
    SLIDER_PRESENT,
    SLIDER_PRESENT_PREMULTIPLIED,
}

builtin_pipeline_slot :: proc(s: Builtin_Pipeline_Slot) -> u32 {
    return u32(s)
}

user_pipeline_slot :: proc(s: u32) -> u32 {
    return len(Builtin_Pipeline_Slot) + s
}

// note(isak): the CLEAR handler forces the depth mask on, then restores it to whatever the bound
// pipeline wants - only mesh shaders (DepthWrite) actually write depth.
pipeline_writes_depth :: proc(id: Pipeline_ID) -> bool {
    if int(id) < len(Builtin_Pipeline_Slot) {
        return false
    }
    if game.active_mapset != nil {
        user_idx := int(id) - len(Builtin_Pipeline_Slot)
        if user_idx >= 0 && user_idx < len(game.active_mapset.shader_depth_writes) {
            return game.active_mapset.shader_depth_writes[user_idx]
        }
    }
    return false
}

Framebuffer_ID :: u32

Builtin_Framebuffer_Slot :: enum u32 {
    DEFAULT,
    SLIDERS,
    BACKBUFFER, // note(isak): full-frame capture target for [General] Backbuffer maps
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
    TRANSFORMS,    // per-frame transform ring SSBO, indexed by Quad/Glyph_Quad transform_index; binding 17
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

// note(isak): per-draw slider params, one slot per DRAW_SLIDER command. border/body colors
// live in Shader_Globals (skin-global, read by slider_present.fs)
Slider_Params :: struct {
    transform:          Transform, // slider-space -> ndc; sliders don't use the frame transform ring
    script_translation: vec2,  // osupx, applied in VS before coord normalization
    base_instance:      u32,   // replaces gl_BaseInstance for intel compat
    radius_osupx:       f32,   // per-object radius, used in VS instead of global circleSizeOsupx
}

// note(isak): every frame's slider params live in one persistently-mapped ring buffer, one slot
// per draw. #align(256) pads each slot to the max UBO offset alignment so any slot offset is a
// legal BindBufferRange offset with no per-slot alignment math.
Slider_Params_Slot :: struct #align(256) {
    params: Slider_Params,
}
#assert(size_of(Slider_Params_Slot) % 256 == 0) // every slot offset must be a legal UBO range offset


Builtin_Texture_Slot :: enum u32 {
    WHITE,
    PROFILER,
    FONT_ATLAS,
    SLIDER_FRAMEBUFFER,
    BACKBUFFER,
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

skin_texture_block_len :: proc() -> u32 {
    return u32(len(Skin_Element_Type)) + u32(len(window.skin_frame_textures))
}

// note(isak): map textures and render targets share the global slot space after the builtin and skin
// slots, so this is how many of them can coexist before we run out of texture handles.
max_user_textures :: proc() -> int {
    return MAX_TEXTURE_HANDLES - len(Builtin_Texture_Slot) - int(skin_texture_block_len())
}

// note(isak): these return indices into the bindless texture buffer
builtin_texture :: proc(slot: Builtin_Texture_Slot) -> u32 { return u32(slot) }
skin_texture :: proc(skin_el: Skin_Element_Type) -> u32 { return u32(skin_el) + len(Builtin_Texture_Slot) }
user_texture :: proc(tex_id: u32) -> u32 { return tex_id + len(Builtin_Texture_Slot) + skin_texture_block_len() }

// note(isak): frame 0 samples the element's own slot; frames 1.. sit in the appended frame block,
// contiguous per element from frame_slot_base. frame is clamped against the element's frame_count.
skin_frame_texture :: proc(skin_el: Skin_Element_Type, frame: int) -> u32 {
    if frame <= 0 do return skin_texture(skin_el)
    block_base := u32(len(Builtin_Texture_Slot)) + u32(len(Skin_Element_Type))
    return block_base + game.active_skin.elements[skin_el].frame_slot_base + u32(frame - 1)
}



Blend_Mode :: enum {
    NONE,
    ALPHA,
    ADDITIVE,
    ADDITIVE_ALPHA,
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
        // note(isak): straight-alpha in, premultiplied out with a coverage alpha valid for re-sampling; 
        // draw it back with premultiplied-over
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
        // note(isak): composites an already-premultiplied source over dest, taking src rgb as-is (factor ONE)
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
    case .ADDITIVE_ALPHA:
        // note(isak): additive weighted by source alpha, so transparent texels contribute nothing instead of 
        // adding opaque squares
        blend = {
            enabled          = true,
            src_factor_rgb   = .SRC_ALPHA,
            dst_factor_rgb   = .ONE,
            op_rgb           = .ADD,
            src_factor_alpha = .SRC_ALPHA,
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

// note(isak): depth_write is read from [Shader] DepthWrite key
quad_pipeline_desc :: proc(blend: Blend_Mode = .ALPHA, depth_write := false) -> sg.Pipeline_Desc {
    return {
        label = "builtin.quad",
        shader = window.shaders.data[builtin_shader_slot(.QUAD)].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = blend_state_for_mode(blend) }
        },
        depth = {compare = .LESS_EQUAL, write_enabled = depth_write},
    },
}

slider_pipeline_desc :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.slider",
        shader = window.shaders.data[builtin_shader_slot(.SLIDER)].shader,
        cull_mode = .NONE,
        // note(isak): MAX-blends the distance field written by slider.fs; max over overlapping
        // circles of (1 - d/r) is the distance to the nearest path point, so the union of
        // circles needs no depth attachment (blend factors are ignored for MIN/MAX equations)
        colors = {
            0 = { blend = {
                enabled          = true,
                op_rgb           = .MAX,
                op_alpha         = .MAX,
                src_factor_rgb   = .ONE,
                src_factor_alpha = .ONE,
                dst_factor_rgb   = .ONE,
                dst_factor_alpha = .ONE,
            }},
        },
    }
}

// note(isak): composites a slider body into its layer: quad VS + a FS that samples the
// SLIDERS distance field and maps it through the border/body banding (sliderParams stays
// bound from the body draw right before this)
slider_present_pipeline_desc :: proc(blend: Blend_Mode = .ALPHA) -> sg.Pipeline_Desc {
    return {
        label = "builtin.slider_present",
        shader = window.shaders.data[builtin_shader_slot(.SLIDER_PRESENT)].shader,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
            0 = { blend = blend_state_for_mode(blend) }
        },
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
        textures[Builtin_Texture_Slot.BACKBUFFER] = window.framebuffers[.BACKBUFFER].color_texture_handles[0]

        for skin_el in Skin_Element_Type {
            textures[num_elements] = window.skin_textures[skin_el].tex_handle
            num_elements += 1
        }
        for &frame in window.skin_frame_textures {
            if num_elements >= MAX_TEXTURE_HANDLES do break
            textures[num_elements] = frame.tex_handle
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
        window.textures_resident = true
    } else {
        ids := &window.tex_id_lookup
        ids[Builtin_Texture_Slot.WHITE] = window.white_texture.tex_id
        ids[Builtin_Texture_Slot.PROFILER] = window.profiler_texture.tex_id
        ids[Builtin_Texture_Slot.FONT_ATLAS] = window.font_atlas_texture.tex_id
        ids[Builtin_Texture_Slot.SLIDER_FRAMEBUFFER] = window.framebuffers[.SLIDERS].color_textures[0]
        ids[Builtin_Texture_Slot.BACKBUFFER] = window.framebuffers[.BACKBUFFER].color_textures[0]

        for skin_el in Skin_Element_Type {
            ids[num_elements] = window.skin_textures[skin_el].tex_id
            num_elements += 1
        }
        for &frame in window.skin_frame_textures {
            if num_elements >= MAX_TEXTURE_HANDLES do break
            ids[num_elements] = frame.tex_id
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
    num_elements := min(len(Builtin_Texture_Slot) + int(skin_texture_block_len()) + int(game.active_mapset.textures.len) + int(game.active_mapset.render_targets.len), MAX_TEXTURE_HANDLES)
    for i in 0..<num_elements {
        if textures[i] > 0 {
            gl.MakeTextureHandleNonResidentARB(textures[i])
        }
    }
    window.textures_resident = false
}


populate_slider_circle_vertices :: proc(geometry: ^Buffer(Slider_Vertex)) {
    #no_bounds_check {
        vert_i := geometry.count
        verts := geometry.data

        verts[vert_i + 0] = { pos = { 0, 0, 0 } }
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
