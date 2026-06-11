package notosu

import q "core:container/queue"
import "core:fmt"
import "core:log"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import stbi "vendor:stb/image"


window: struct {
    rect: Rect,
    aspect_ratio: f32, // note(isak): height over width
    screenspace_transform: Transform,
    renderer: Renderer,

    cursor_hidden: bool,
    focused: bool,
    mouse_inside: bool,
    minimized: bool,
    fullscreen: bool,
    bindless_supported: bool,
    intel_gpu: bool,

    handle: ^sdl.Window,
    gl_context: sdl.GLContext,

    // note(isak): graphical resources used by the drawing context go here

    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,

    shaders: q.Queue(Shader),
    pipelines: q.Queue(sg.Pipeline),
    framebuffers: [Builtin_Framebuffer_Slot]GL_Framebuffer,

    // note(isak): we make a distinction between static and dynamic geometry; dynamic can be streamed
    // data into efficiently by using a triple buffer setup, while static is single-buffered and is fit
    // for bigger data that isn't updated as often (such as during a loading screen)

    // note(isak): single quad buffer for deferred rendering quad store, unused
    fullscreen_store: GL_Buffer(Quad),

    quad_store: GL_Triple_Buffer(Quad),

    slider_instance_store: GL_Buffer(vec2),

    text_store: GL_Triple_Buffer(Glyph_Quad),

    shader_global_buffer: GL_Uniform_Buffer(Shader_Globals),
    slider_param_buffer: GL_Uniform_Buffer(Slider_Params),
    user_param_buffer: GL_Uniform_Buffer(User_Shader_Params),
    post_param_buffer: GL_Uniform_Buffer(Post_Pass_Params),
    circle_geo_buffer: GL_Buffer(Slider_Vertex),
    texture_buffer: GL_Buffer(u64),

    // note(isak): non-bindless fallback
    tex_id_lookup: [MAX_TEXTURE_HANDLES]u32,

    white_texture: Texture,
    profiler_texture: Texture,
    font_atlas_texture: Texture,

    skin_textures: [Skin_Element_Type]Texture,
    is_high_resolution: [Skin_Element_Type]bool
}

window_init :: proc(rect: Rect) {
    _platform_dpi_init()

    window.rect = rect
    window.handle = sdl.CreateWindow(
        fmt.ctprintf("notosu! - v%s", VERSION), 
        i32(rect.w), i32(rect.h), sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE | sdl.WINDOW_TRANSPARENT)
    window.aspect_ratio = f32(rect.h) / f32(rect.w)

    stbi.set_flip_vertically_on_load_thread(true)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 4)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 6)
    sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengl")

    window.gl_context = sdl.GL_CreateContext(window.handle)
    sdl.GL_SetSwapInterval(0)
    gl.load_up_to(4, 6, sdl.gl_set_proc_address)
    gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE)
    gl.Enable(gl.SCISSOR_TEST)

    window.bindless_supported = gl_has_extension("GL_ARB_bindless_texture")
    log.infof("GL_ARB_bindless_texture: {}", window.bindless_supported ? "supported" : "not supported")

    // note(isak): intel igpus have only partial bindless texture support, but report the extension available
    // and crash on shader compile. they also diverge from nvidia on a few other points (see slider_render_path)
    window.intel_gpu = gl_vendor_is_intel()
    if window.intel_gpu {
        log.infof("intel gpu detected ({} / {}), forcing no-bindless fallback",
            gl.GetString(gl.VENDOR), gl.GetString(gl.RENDERER))
        window.bindless_supported = false
    }

    win_x, win_y: i32
    sdl.GetWindowPosition(window.handle, &win_x, &win_y)
    window.rect.x = f32(win_x)
    window.rect.y = f32(win_y)

    window.cursor_hidden = sdl.HideCursor()
    window.focused = true
    window.mouse_inside = true

    max_vs_ssbo, max_combined_ssbo, max_fs_ssbo: i32
    gl.GetIntegerv(gl.MAX_VERTEX_SHADER_STORAGE_BLOCKS, &max_vs_ssbo)
    gl.GetIntegerv(gl.MAX_FRAGMENT_SHADER_STORAGE_BLOCKS, &max_fs_ssbo)
    gl.GetIntegerv(gl.MAX_COMBINED_SHADER_STORAGE_BLOCKS, &max_combined_ssbo)
    log.infof("SSBO blocks - vertex: {}, fragment: {}, combined: {}",
        max_vs_ssbo, max_fs_ssbo, max_combined_ssbo)
}

window_on_resize :: proc(new_w, new_h: i32) {
    window.rect.w = f32(new_w)
    window.rect.h = f32(new_h)
    window.swapchain.width = new_w
    window.swapchain.height = new_h
    window.aspect_ratio = window.rect.h / window.rect.w
    window.screenspace_transform = transform_from_bounds({0, 0, window.rect.w, window.rect.h}, 1)
    
    game.playfield_transform = playfield_build_transform()
    game.playfield_dirty_transform = false
    
    fbo_reinit(&window.framebuffers[.SLIDERS], new_w, new_h)

    if game.active_mapset != nil {
        for &rt in game.active_mapset.render_targets.data {
            if rt.scale > 0 {
                fbo_reinit(&rt.fbo, i32(window.rect.w * rt.scale), i32(window.rect.h * rt.scale))
            }
        }
    }
}

clipspace_transform := transform_from_bounds({0, 0, 1, 1}, 1)

window_toggle_fullscreen :: proc() {
    window.fullscreen = !window.fullscreen
    sdl.SetWindowFullscreen(window.handle, window.fullscreen)
}

window_apply_vsync :: proc(enabled: bool) {
    sdl.GL_SetSwapInterval(1 if enabled else 0)
}

window_cleanup :: proc() {
    sdl.GL_DestroyContext(window.gl_context)
    sdl.DestroyWindow(window.handle)
}
