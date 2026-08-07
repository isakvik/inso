package imgui_impl_opengl3

import imgui "../"

when      ODIN_OS == .Windows { foreign import lib "../imgui_windows_x64.lib" }
else when ODIN_OS == .Linux   { foreign import lib "../imgui_linux_x64.a" }
else when ODIN_OS == .Darwin  {
	when ODIN_ARCH == .amd64 { foreign import lib "../imgui_darwin_x64.a" } else { foreign import lib "../imgui_darwin_arm64.a" }
}

// imgui_impl_opengl3.h
// Last checked `v1.91.7-docking` (a9cd0f5)
@(link_prefix="ImGui_ImplOpenGL3_")
foreign lib {
	// Backend API
	Init           :: proc(glsl_version: cstring = nil) -> bool ---
	Shutdown       :: proc() ---
	NewFrame       :: proc() ---
	RenderDrawData :: proc(draw_data: ^imgui.DrawData) ---

	// (Optional) Called by Init/NewFrame/Shutdown
	CreateFontsTexture   :: proc() -> bool ---
	DestroyFontsTexture  :: proc() ---
	CreateDeviceObjects  :: proc() -> bool ---
	DestroyDeviceObjects :: proc() ---
}
