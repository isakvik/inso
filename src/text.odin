package notosu

import "core:fmt"
import "core:mem"
import "core:sys/windows"
import sa "core:container/small_array"

import fs "vendor:fontstash"
import gl "vendor:OpenGL"
import sg "vendor:sokol/gfx"
import sdl "vendor:sdl3"


DEFAULT_FONT_ATLAS_SIZE :: 512
MAX_GLYPHS              :: 1024


Font :: enum {
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


@(rodata)
fonts := [Font][]byte{
    .DEFAULT = #load("C:/Windows/Fonts/GeorgiaPro-Regular.ttf"),
}

font_paths := [Font]string{
    .DEFAULT = "C:/Windows/Fonts/GeorgiaPro-Regular.ttf",
}


@(rodata)
fallback_font := #load("C:/Windows/Fonts/ARIAL_UNICODE_MS.ttf")

fallback_font_path := "C:/Windows/Fonts/ARIAL_UNICODE_MS.ttf"


text_engine: struct {
    ctx: fs.FontContext,
    
    fallback_font_id: int,
}

text_init :: proc() {
    fs.Init(&text_engine.ctx, DEFAULT_FONT_ATLAS_SIZE, DEFAULT_FONT_ATLAS_SIZE, .TOPLEFT)
    text_engine.ctx.callbackResize = text_resize_callback
    text_engine.ctx.callbackUpdate = text_update_callback
    
    text_engine.fallback_font_id = 
        fs.AddFontMem(&text_engine.ctx, "Arial (fallback)", fallback_font, freeLoadedData=false)
    
    for font in Font {
        fs.AddFontPath(
            &text_engine.ctx, 
            fmt.enum_value_to_string(font) or_else unreachable(),
            font_paths[font])
        fs.AddFallbackFont(&text_engine.ctx, int(font), text_engine.fallback_font_id)
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
}

text_resize_callback :: proc(pixels: rawptr, w, h: int) {
    texture_reinit(&window.font_atlas_texture, i32(w), i32(h), pixels)
}

text_update_callback :: proc(pixels: rawptr, dirty_rect: [4]f32, texture_data: rawptr) {
    /*dirty_rect := Window_Rect{
        i32(dirty_rect[0]),
        i32(dirty_rect[1]),
        i32(dirty_rect[2]) - i32(dirty_rect[0]),
        i32(dirty_rect[3]) - i32(dirty_rect[1]),
    }*/
    // note(isak): can potentially push only the dirty rect, but it requires copying only the relevant
    // parts of the fontstash texture data out, as the texture data here just points to the whole atlas
    texture_write_to(window.font_atlas_texture, 
                     {0, 0, DEFAULT_FONT_ATLAS_SIZE, DEFAULT_FONT_ATLAS_SIZE}, 
                     texture_data, 
                     len(text_engine.ctx.textureData))
}

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
    
    for iter := fs.TextIterInit(&text_engine.ctx, pos.x, pos.y, text); true; {
        quad: fs.Quad
        fs.TextIterNext(&text_engine.ctx, &iter, &quad) or_break

        buffer_push(&renderer.text_geometry, Glyph_Quad {
            pos_min = {quad.x0, quad.y0},
            pos_max = {quad.x1, quad.y1},
            uv_min  = {quad.s0, quad.t0},
            uv_max  = {quad.s1, quad.t1},
            color   = color
        })
    }
    
    if x_inc != nil {
        last := renderer.text_geometry.data[renderer.text_geometry.count - 1]
        x_inc^ += last.pos_max.x - pos.x
    }
}

text_end_frame :: proc(renderer: ^Renderer) {
    // note(isak): bad api - the state management isn't needed, but this checks if texture updates
    //             is necessary and calls the callback with the dirty rect
    fs.EndState(&text_engine.ctx)
    
    command_push_draw_text({
        glyph_count = renderer.text_geometry.count
    })
}

