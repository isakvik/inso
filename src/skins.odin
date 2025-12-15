package notosu

import os "core:os/os2"
import "core:strings"


Skin_Element :: enum {
    CURSOR,
    APPROACHCIRCLE,
    HITCIRCLE,
    HITCIRCLEOVERLAY,
    LIGHTING,
}

Skin_Element_Path := #partial [Skin_Element]string {
    .CURSOR             = "cursor",
    .APPROACHCIRCLE     = "approachcircle",
    .HITCIRCLE          = "hitcircle",
    .HITCIRCLEOVERLAY   = "hitcircleoverlay",
    .LIGHTING           = "lighting",
}

supported_image_extensions :: []string{".png", ".jpg"}

skin_texture_slot :: proc(tex_id: Skin_Element) -> u32 { 
    return u32(tex_id) + len(Reserved_Texture_Slots) 
}

load_skin_textures :: proc(skin_path: string) {

    tex_err: os.Error
    for element in Skin_Element {
        for extension in supported_image_extensions {
            element_path := strings.concatenate({skin_path, Skin_Element_Path[element], extension})
            window.skin_textures[element], tex_err = texture_from_file(element_path)
    
            if tex_err == os.General_Error.Not_Exist {
                element_path = strings.concatenate({skin_path, Skin_Element_Path[element], "@2x", extension})
                window.skin_textures[element], tex_err = texture_from_file(element_path)
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
        texture_ids[element] = window.skin_textures[element].tex_id
    }
    texture_delete(texture_ids[:])
}
