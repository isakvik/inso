package notosu

import os "core:os/os2"
import "core:strings"


Skin_Element_Type :: enum u32 {
    CURSOR,
    APPROACHCIRCLE,
    HITCIRCLE,
    HITCIRCLEOVERLAY,
    LIGHTING,

    COMBO_1,
}

Skin_Element :: struct {
    texture: ^Texture,
    is_high_resolution: bool,
    metrics: Rect,
}

Skin_Element_Path := #partial [Skin_Element_Type]string {
    .CURSOR             = "cursor",
    .APPROACHCIRCLE     = "approachcircle",
    .HITCIRCLE          = "hitcircle",
    .HITCIRCLEOVERLAY   = "hitcircleoverlay",
    .LIGHTING           = "default-1",
    .COMBO_1            = "default-1",
}


supported_image_extensions :: []string{".png", ".jpg"}


// todo(isak): @leak: since we allocate strings here, reloading the skin results in path strings that are never freed
// make a skin arena for unloading is probably easiest
load_skin_textures :: proc(skin_path: string) {
    
    os.change_directory(skin_path)
    defer os.change_directory(app.base_dir)

    for element in Skin_Element_Type {
        tex_err: os.Error
        for extension in supported_image_extensions {
            element_path := strings.concatenate({Skin_Element_Path[element], "@2x", extension})
            tex_store := &window.skin_textures[element]
            tex := &game.active_skin[element]
            
            tex_store^, tex_err = texture_from_file(element_path)
            if tex_err == os.General_Error.None {
                tex.is_high_resolution = true
                break
            }
    
            if tex_err == os.General_Error.Not_Exist {
                element_path = strings.concatenate({Skin_Element_Path[element], extension})
                tex_store^, tex_err = texture_from_file(element_path)
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
    texture_ids: [len(Skin_Element_Type)]u32
    for element in Skin_Element_Type {
        texture_ids[element] = window.skin_textures[element].tex_id
    }
    texture_free(texture_ids[:])
}
