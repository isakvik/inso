package notosu

import "core:fmt"
import os "core:os"

import fs "vendor:fontstash"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"


/* todo(isak): 
    - string caching by way of a pool system that can allocate/free within the buffer
        @speed, but it's probably not necessary at all
        easily viable for constant strings/constant positions? may as well just use a small buffer for em
*/


DEFAULT_FONT_ATLAS_SIZE :: 512
MAX_GLYPHS              :: 1024


Font :: enum {
    FALLBACK,
    DEFAULT,
}

Text_Align_Horizontal :: enum {
    Left   = int(fs.AlignHorizontal.LEFT),
    Center = int(fs.AlignHorizontal.CENTER),
    Right  = int(fs.AlignHorizontal.RIGHT),
}

Text_Align_Vertical :: enum {
    Top      = int(fs.AlignVertical.TOP),
    Middle   = int(fs.AlignVertical.MIDDLE),
    Bottom   = int(fs.AlignVertical.BOTTOM),
    Baseline = int(fs.AlignVertical.BASELINE),
}

Glyph_Quad :: struct {
    pos_min: [2]f32,
    pos_max: [2]f32,
    uv_min:  [2]f32,
    uv_max:  [2]f32,
    color:   [4]u8,
    __padding: [3]u32
}

// note(isak) @release: arial unicode ships with some microsoft products and contains pretty much everything, but
// we can't really depend on it being there. so if it doesn't exist, we use the bundled font, but we should
// probably just slap arial unicode into our executable at release time
font_paths := [Font]string{
    .FALLBACK = "c:/Windows/Fonts/ARIAL_UNICODE_MS.ttf",
    .DEFAULT = "data/Roboto-Regular.ttf",
}

text_engine: struct {
    ctx: fs.FontContext,
    
    fallback_font_id: int,
}

text_init :: proc() {
    fs.Init(&text_engine.ctx, DEFAULT_FONT_ATLAS_SIZE, DEFAULT_FONT_ATLAS_SIZE, .TOPLEFT)
    text_engine.ctx.callbackResize = text_resize_callback
    text_engine.ctx.callbackUpdate = text_update_callback

    if !os.exists(font_paths[.FALLBACK]) {
        font_paths[.FALLBACK] = font_paths[.DEFAULT]
    }
    
    for font in Font {
        fs.AddFontPath(
            &text_engine.ctx, 
            fmt.enum_value_to_string(font) or_else unreachable(),
            font_paths[font])

        if font != .FALLBACK {
            fs.AddFallbackFont(&text_engine.ctx, int(font), int(Font.FALLBACK))
        }
    }

    window.font_atlas_texture = texture_from_size(
        DEFAULT_FONT_ATLAS_SIZE, DEFAULT_FONT_ATLAS_SIZE,
        gl.R8, 
        gl.RED
    )

    texture_write_to(window.font_atlas_texture, 
                     {0, 0, DEFAULT_FONT_ATLAS_SIZE, DEFAULT_FONT_ATLAS_SIZE},
                     raw_data(text_engine.ctx.textureData),
                     len(text_engine.ctx.textureData))

    window.renderer.text_draw = {
        instance_count = 1
    }
}

text_resize_callback :: proc(ctx: rawptr, w, h: int) {
    _texture_reinit(&window.font_atlas_texture, i32(w), i32(h), ctx)
    fs.__dirtyRectReset(cast(^fs.FontContext)ctx)
}

text_update_callback :: proc(ctx: rawptr, dirty_rect: [4]f32, texture_data: rawptr) {
    dirty_rect := [4]i32{
        i32(dirty_rect[0]),
        i32(dirty_rect[1]),
        i32(dirty_rect[2]) - i32(dirty_rect[0]),
        i32(dirty_rect[3]) - i32(dirty_rect[1]),
    }

    for i in 0..<dirty_rect[3] {
        texture_write_to(window.font_atlas_texture,
                         {f32(dirty_rect[0]), f32(dirty_rect[1] + i), f32(dirty_rect[2]), 1},
                         rawptr(uintptr(texture_data) + uintptr(dirty_rect[0] + window.font_atlas_texture.w * (dirty_rect[1] + i))),
                         int(dirty_rect[2]))
    }
}

// todo(isak): this is actually pretty slow since it has to push a bunch of stuff for every call.
// string and state caching would help, but that might not be so useful during play mode?
push_text :: proc(
    renderer: ^Renderer,
    text: string,
    pos: [2]f32,
    size: f32 = 36,
    color: [4]u8 = max(u8),
    blur: f32 = 0,
    spacing: f32 = 0,
    font: Font = .DEFAULT,
    align_h: Text_Align_Horizontal = .Left,
    align_v: Text_Align_Vertical   = .Baseline,
    x_inc: ^f32 = nil,
    y_inc: ^f32 = nil,
) {
    state := fs.__getState(&text_engine.ctx)
    state^ = {
        size    = size * sdl.GetWindowPixelDensity(window.handle),
        blur    = blur,
        spacing = spacing,
        font    = int(font),
        ah      = fs.AlignHorizontal(align_h),
        av      = fs.AlignVertical(align_v),
    }

    if y_inc != nil {
        _, _, lh := fs.VerticalMetrics(&text_engine.ctx)
        y_inc^ += lh
    }

    text_vertex_buffer := &renderer.text_geometry
    text_glyph_next_index := renderer.text_geometry.count

    for iter := fs.TextIterInit(&text_engine.ctx, pos.x, pos.y, text); true; {
        quad: fs.Quad
        fs.TextIterNext(&text_engine.ctx, &iter, &quad) or_break
        
        buffer_push(text_vertex_buffer, Glyph_Quad {
            pos_min = {quad.x0, quad.y0},
            pos_max = {quad.x1, quad.y1},
            uv_min  = {quad.s0, quad.t0},
            uv_max  = {quad.s1, quad.t1},
            color   = color
        })
    }
    
    if x_inc != nil && text_vertex_buffer.count > 0 {
        first := text_vertex_buffer.data[text_glyph_next_index]
        last := text_vertex_buffer.data[text_vertex_buffer.count - 1]
        x_inc^ += last.pos_max.x - first.pos_min.x
    }
}

text_submit_geometry :: proc(renderer: ^Renderer) {
    // note(isak): the state management isn't needed, but this checks if texture updates
    // is necessary and calls the callback with the dirty rect
    fs.EndState(&text_engine.ctx)

    // note(isak): since we do vertex picking and our vertex data composes a whole glyph,
    // i've written the shader to draw a glyph quad by invoking a quad 6 times
    r_bind_layer_and_push_current_state(.DEBUG)
    r_bind_pipeline({ pipeline = builtin_pipeline_slot(.TEXT) })
    r_bind_ssbo(&window.text_store, .VERTEX_BUFFER)

    r_push_draw(
        index_offset = 0,
        index_count = renderer.text_geometry.count * 6,
        instance_count = 1
    )

    // note(isak): for non-bindless text, assign font atlas to unit 0.
    // must happen after r_push_draw so we populate the NEW draw's map, not the previous one.
    // (text.vs.glsl hardcodes texIndex=0 in non-bindless mode)
    if !window.bindless_supported {
        texture_unit_map_assign(&renderer.texture_unit_map, builtin_texture(.FONT_ATLAS))
    }
}
