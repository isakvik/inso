package notosu

import q "core:container/queue"
import "core:sys/windows"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"
import sg "vendor:sokol/gfx"
import stbi "vendor:stb/image"


window: struct {
    rect: Rect,
    aspect_ratio: f32, // note(isak): height over width
    screenspace_transform: Transform,
    playfield_to_screenspace_transform: Transform,
    renderer: Renderer,

    cursor_hidden: bool,

    handle: ^sdl.Window,
    gl_context: sdl.GLContext,
    
    ui_enabled: bool,
    map_dropdown: Debug_Dropdown,
    
    // note(isak): graphical resources used by the drawing context go here 

    bindings: sg.Bindings,
    pass_action: sg.Pass_Action,
    swapchain: sg.Swapchain,

    shaders: q.Queue(Shader),
    pipelines: q.Queue(sg.Pipeline),
    framebuffers: [Framebuffer_ID]GL_Framebuffer,
    
    // note(isak): we make a distinction between static and dynamic geometry; dynamic can be streamed
    // data into efficiently by using a triple buffer setup, while static is single-buffered and is fit
    // for bigger data that isn't updated as often (such as during a loading screen)

    // note(isak): single quad buffer for deferred rendering quad store, unused
    fullscreen_store: GL_Buffer(Quad),

    quad_store: GL_Triple_Buffer(Quad),
    
    slider_instance_store: GL_Buffer(vec2),
    
    text_store: GL_Triple_Buffer(Glyph_Quad),
    
    shader_global_buffer: GL_Uniform_Buffer(Shader_Globals),
    slider_param_buffer: GL_Uniform_Buffer(Slider_Globals),
    user_param_buffer: GL_Uniform_Buffer(User_Shader_Params),
    circle_geo_buffer: GL_Buffer(Slider_Vertex),
    texture_buffer: GL_Buffer(u64),

    white_texture: Texture,
    profiler_texture: Texture,
    font_atlas_texture: Texture,


    skin_textures: [Skin_Element_Type]Texture,
    is_high_resolution: [Skin_Element_Type]bool
}

window_init :: proc(rect: Rect) {
    windows.SetProcessDPIAware()
    
    window.rect = rect
    window.handle = sdl.CreateWindow("notosu!", i32(rect.w), i32(rect.h), sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE)
    window.aspect_ratio = f32(rect.h) / f32(rect.w)

    stbi.set_flip_vertically_on_load_thread(true)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MAJOR_VERSION, 4)
    sdl.GL_SetAttribute(sdl.GL_CONTEXT_MINOR_VERSION, 6)
    sdl.SetHint(sdl.HINT_RENDER_DRIVER, "opengl")

    sdl.GL_SetSwapInterval(0)
    sdl.SetWindowSurfaceVSync(window.handle, 0)

    window.gl_context = sdl.GL_CreateContext(window.handle)
    gl.load_up_to(4, 6, sdl.gl_set_proc_address)
    gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE)
    gl.Enable(gl.SCISSOR_TEST)

    win_x, win_y: i32
    sdl.GetWindowPosition(window.handle, &win_x, &win_y)
    window.rect.x = f32(win_x)
    window.rect.y = f32(win_y)

    window.cursor_hidden = sdl.HideCursor()
}

window_on_resize :: proc(new_w, new_h: i32) {
    window.rect.w = f32(new_w)
    window.rect.h = f32(new_h)
    window.swapchain.width = new_w
    window.swapchain.height = new_h
    window.aspect_ratio = window.rect.h / window.rect.w
    window.screenspace_transform = transform_from_bounds({0, 0, window.rect.w, window.rect.h}, 1)
    
    // note(isak): you can put this in a game facing function and have a pointer here, but why would you wanna do that?
    game.playfield_transform = transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    fbo_reinit(&window.framebuffers[.SLIDERS], new_w, new_h)
}

clipspace_transform := transform_from_bounds({0, 0, 1, 1}, 1)

window_cleanup :: proc() {
    sdl.GL_DestroyContext(window.gl_context)
    sdl.DestroyWindow(window.handle)
}
