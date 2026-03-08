package notosu

import "core:mem/virtual"
import os "core:os/os2"
import "core:strings"


Skin_Element_Type :: enum u32 {
    CURSOR,
    APPROACHCIRCLE,
    HITCIRCLE,
    HITCIRCLEOVERLAY,
    LIGHTING,
    
    HIT0,
    HIT50,
    HIT100,
    HIT300,

    COMBO_1,
}

Skin_Element :: struct {
    texture: ^Texture,
    is_high_resolution: bool,
    metrics: Rect,
}

Skin_Element_Path := #partial [Skin_Element_Type]string {
    .CURSOR = "cursor",
    .APPROACHCIRCLE = "approachcircle",
    .HITCIRCLE = "hitcircle",
    .HITCIRCLEOVERLAY = "hitcircleoverlay",
    .LIGHTING = "lighting",
    
    .HIT0 = "hit0",
    .HIT50 = "hit50",
    .HIT100 = "hit100",
    .HIT300 = "hit300",
    
    .COMBO_1 = "default-1",
}

Skin :: struct {
    path: string,
    elements: [Skin_Element_Type]Skin_Element,
}


supported_image_extensions :: []string{".png", ".jpg"}


skin_load :: proc(skin_path: string) -> (result: ^Skin) {
    context.allocator = memory.allocators[.SKIN]
    result = new(Skin)
    result.path, _ = strings.clone(skin_path)
    
    os.change_directory(result.path)
    defer os.change_directory(app.base_dir)

    for element in Skin_Element_Type {
        tex_err: os.Error
        for extension in supported_image_extensions {
            element_path := strings.concatenate({Skin_Element_Path[element], "@2x", extension})
            tex_store := &window.skin_textures[element]
            tex := result.elements[element]
            
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
    return result
}

skin_unload :: proc() {
    texture_ids: [len(Skin_Element_Type)]u32
    for element in Skin_Element_Type {
        texture_ids[element] = window.skin_textures[element].tex_id
    }
    texture_free(texture_ids[:])
    
    virtual.arena_free_all(&memory.arenas[.SKIN])
}

skin_reload :: proc(skin: ^Skin) {
    temp_path := strings.clone(skin.path, context.temp_allocator)
    skin_unload()
    skin_load(temp_path)
}
