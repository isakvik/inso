package notosu

import os "core:os/os2"
import "core:strings"


Skin_Element :: enum {
    NONE,
    CURSOR,
    APPROACHCIRCLE,
    HITCIRCLE,
    HITCIRCLEOVERLAY,
    LIGHTING,

    COMBO_1,
}

Skin_Texture :: struct {
    texture: Texture,
    is_high_resolution: bool
}

Skin_Element_Path := #partial [Skin_Element]string {
    .CURSOR             = "cursor",
    .APPROACHCIRCLE     = "approachcircle",
    .HITCIRCLE          = "hitcircle",
    .HITCIRCLEOVERLAY   = "hitcircleoverlay",
    .LIGHTING           = "lighting",
    .COMBO_1            = "default-1",
}


supported_image_extensions :: []string{".png", ".jpg"}

// note(isak): returns index into bindless texture buffer
skin_texture :: proc(tex_id: Skin_Element) -> u32 { 
    return u32(tex_id) + len(Reserved_Texture_Slot) 
}

// todo(isak): @leak: since we allocate strings here, reloading the skin results in path strings that are never freed
// make a skin arena for unloading is probably easiest
load_skin_textures :: proc(skin_path: string) {

    for element in Skin_Element {
        if element == .NONE { continue }
        
        tex_err: os.Error
        for extension in supported_image_extensions {
            element_path := strings.concatenate({skin_path, Skin_Element_Path[element], "@2x", extension})
            tex := &window.skin_textures[element]
            
            tex.texture, tex_err = texture_from_file(element_path)
            if tex_err == os.General_Error.None {
                tex.is_high_resolution = true
                break
            }
    
            if tex_err == os.General_Error.Not_Exist {
                element_path = strings.concatenate({skin_path, Skin_Element_Path[element], extension})
                tex.texture, tex_err = texture_from_file(element_path)
            }

            if tex_err == os.General_Error.None {
                break
            }
        }

        // todo(isak): we handle as much as we handle here, but can supply a default skin like osu here
        // instead of asserting
        assert(tex_err == os.General_Error.None)
    }
}

unload_skin_textures :: proc() {
    texture_ids: [len(Skin_Element)]u32
    for element in Skin_Element {
        texture_ids[element] = window.skin_textures[element].texture.tex_id
    }
    texture_delete(texture_ids[:])
}
