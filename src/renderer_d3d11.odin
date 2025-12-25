package notosu

import "core:container/queue"
import os "core:os/os2"

import sdl "vendor:sdl3"
import d3d "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import sg "vendor:sokol/gfx"
import slog "vendor:sokol/log"


quad_vs_path :: "shaders/main.vs.hlsl"
quad_fs_path :: "shaders/main.fs.hlsl"

slider_vs_path :: "shaders/slider.vs.glsl"
slider_fs_path :: "shaders/slider.fs.glsl"

text_vs_path :: "shaders/text.vs.glsl"
text_fs_path :: "shaders/text.fs.glsl"


d3d_context: struct {
    hwnd: dxgi.HWND,
    device: ^d3d.IDevice,
    device_context: ^d3d.IDeviceContext,

    swapchain: ^dxgi.ISwapChain1,
	dxgi_adapter: ^dxgi.IAdapter,
    dxgi_device: ^dxgi.IDevice,
	dxgi_factory: ^dxgi.IFactory2,

    framebuffer: ^d3d.ITexture2D,
    framebuffer_view: ^d3d.IRenderTargetView,

    depth_buffer: ^d3d.ITexture2D,
	depth_buffer_view: ^d3d.IDepthStencilView,

}

d3d_init :: proc() {
    using d3d_context

    properties := sdl.GetWindowProperties(window.handle)
    hwnd = dxgi.HWND(sdl.GetPointerProperty(properties, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))

    feature_levels := [?]d3d.FEATURE_LEVEL{._11_0}

    base_device: ^d3d.IDevice
    base_device_context: ^d3d.IDeviceContext

    d3d.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &feature_levels[0], 
                        len(feature_levels), d3d.SDK_VERSION, &base_device, nil, 
                        &base_device_context)
                        
    base_device->QueryInterface(d3d.IDevice_UUID, (^rawptr)(&device))
    base_device_context->QueryInterface(d3d.IDeviceContext_UUID, (^rawptr)(&device_context))

    device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
    dxgi_device->GetAdapter(&dxgi_adapter)
    dxgi_adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&dxgi_factory))

    swapchain_desc := dxgi.SWAP_CHAIN_DESC1{
        Width  = 0,
        Height = 0,
        Format = .B8G8R8A8_UNORM_SRGB,
        Stereo = false,
        SampleDesc = {
            Count   = 1,
            Quality = 0,
        },
        BufferUsage = { .RENDER_TARGET_OUTPUT },
        BufferCount = 2,
        Scaling     = .STRETCH,
        SwapEffect  = .DISCARD,
        AlphaMode   = .UNSPECIFIED,
        Flags       = {},
    }

    dxgi_factory->CreateSwapChainForHwnd(device, hwnd, &swapchain_desc, nil, nil, &swapchain)



    swapchain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&framebuffer))
    device->CreateRenderTargetView(framebuffer, nil, &framebuffer_view)

    depth_buffer_desc: d3d.TEXTURE2D_DESC
    framebuffer->GetDesc(&depth_buffer_desc)
    depth_buffer_desc.Format = .D24_UNORM_S8_UINT
    depth_buffer_desc.BindFlags = {.DEPTH_STENCIL}

    device->CreateTexture2D(&depth_buffer_desc, nil, &depth_buffer)

    device->CreateDepthStencilView(depth_buffer, nil, &depth_buffer_view)
    
    sg.setup({
        environment = {
            d3d11 = {
                device = &device,
                device_context = &device_context
            },
        },
        logger = {func = slog.func},
    })
}

d3d_cleanup :: proc() {

}


Renderer :: struct {
    quad_geometry: Geometry_Buffer(Quad_Vertex),

    slider_instances: Buffer(vec2),

    command_queue: queue.Queue(u8),

    current_draw: ^Command_Draw,
    null_draw: Command_Draw,

    trace_frame: bool
}

Quad_Vertex :: struct {

}

Geometry_Buffer :: struct(T: typeid) {
    vertices: Buffer(T),
    indices: Buffer(u32),
}


renderer_init :: proc() {
    err: Shader_Error
    window.shaders[.QUAD], err = init_shader(quad_vs_path, quad_fs_path)
    assert(err == .NONE)
}

renderer_cleanup :: proc() {
    
}

batch_begin :: proc(renderer: ^Renderer) {

}

batch_end :: proc(renderer: ^Renderer) {
    
}

begin_draw_with_transform :: proc(transform: Transform) {

}

push_rect :: proc(geometry: ^Geometry_Buffer(Quad_Vertex), rect: _Rect(f32), color: vec4, tex_index: u32 = 0) {

}

texture_from_file :: proc(path: string) -> (Texture, os.Error) {
    return {}, os.General_Error.None
}

texture_delete :: proc(ids: []u32) {

}
