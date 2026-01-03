package notosu

import "core:math"

import gl "vendor:OpenGL"
import sg "vendor:sokol/gfx"


quad_vs_path :: "shaders/main.vs.glsl"
quad_fs_path :: "shaders/main.fs.glsl"

slider_vs_path :: "shaders/slider.vs.glsl"
slider_fs_path :: "shaders/slider.fs.glsl"

text_vs_path :: "shaders/text.vs.glsl"
text_fs_path :: "shaders/text.fs.glsl"


Pipeline_ID :: enum {
    QUAD,
    SLIDER,
    TEXT
}

Framebuffer_ID :: enum {
    DEFAULT,
    SLIDERS,
}

Reserved_Texture_Slots :: enum u32 {
    WHITE,
    PROFILER,
    FONT_ATLAS,
    SLIDER_FRAMEBUFFER
}

reserved_texture :: proc(slot: Reserved_Texture_Slots) -> u32 { return u32(slot) }



//////////////////////////////////////////////////////
// note(isak): pipeline definitions

quad_pipeline :: proc() -> sg.Pipeline_Desc {
    return {
        label = "builtin.quad",
        shader = window.shaders[.QUAD].shader,
        //index_type = .UINT16,
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
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
        colors = {
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
        cull_mode = .NONE,
        blend_color = {1.0, 1.0, 1.0, 1.0},
        colors = {
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
// note(isak): texture api

prepare_textures_for_rendering :: proc() {
    textures := &window.texture_buffer.data

    textures[Reserved_Texture_Slots.WHITE] = window.white_texture.tex_handle
    textures[Reserved_Texture_Slots.PROFILER] = window.profiler_texture.tex_handle
    textures[Reserved_Texture_Slots.FONT_ATLAS] = window.font_atlas_texture.tex_handle
    textures[Reserved_Texture_Slots.SLIDER_FRAMEBUFFER] = window.framebuffers[.SLIDERS].color_texture_handles[0]
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
