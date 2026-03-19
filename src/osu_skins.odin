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

    COMBO_0,
    COMBO_1,
    COMBO_2,
    COMBO_3,
    COMBO_4,
    COMBO_5,
    COMBO_6,
    COMBO_7,
    COMBO_8,
    COMBO_9,
}

Skin_Sample_Set :: enum {
    NORMAL,
    SOFT,
    DRUM
}

Skin_Hitsound_Type :: enum u32 {
    HITNORMAL,
    HITWHISTLE,
    HITFINISH,
    HITCLAP,

    SLIDERSLIDE,
    SLIDERWHISTLE,
    SLIDERTICK,
}

Skin_Element :: struct {
    texture: ^Texture,
    is_high_resolution: bool,
    metrics: Rect,
}

Skin_Element_Path := #partial [Skin_Element_Type]string {
    .CURSOR          = "cursor",
    .APPROACHCIRCLE  = "approachcircle",
    .HITCIRCLE       = "hitcircle",
    .HITCIRCLEOVERLAY = "hitcircleoverlay",
    .LIGHTING        = "lighting",

    .HIT0    = "hit0",
    .HIT50   = "hit50",
    .HIT100  = "hit100",
    .HIT300  = "hit300",

    .COMBO_0 = "default-0",
    .COMBO_1 = "default-1",
    .COMBO_2 = "default-2",
    .COMBO_3 = "default-3",
    .COMBO_4 = "default-4",
    .COMBO_5 = "default-5",
    .COMBO_6 = "default-6",
    .COMBO_7 = "default-7",
    .COMBO_8 = "default-8",
    .COMBO_9 = "default-9",
}

skin_sample_set_name := [Skin_Sample_Set]string {
    .NORMAL = "normal",
    .SOFT   = "soft",
    .DRUM   = "drum",
}

skin_hitsound_type_name := [Skin_Hitsound_Type]string {
    .HITNORMAL   = "hitnormal",
    .HITWHISTLE  = "hitwhistle",
    .HITFINISH   = "hitfinish",
    .HITCLAP     = "hitclap",
    .SLIDERSLIDE = "sliderslide",
    .SLIDERWHISTLE = "sliderwhistle",
    .SLIDERTICK  = "slidertick",
}

Hitsound :: Sample

Skin :: struct {
    path: string,
    elements: [Skin_Element_Type]Skin_Element,
    hitsounds: [Skin_Sample_Set][Skin_Hitsound_Type]Hitsound,
}


supported_image_extensions :: []string{".png", ".jpg"}
supported_audio_extensions :: []string{".wav", ".ogg"}

skin_load :: proc(skin_path: string) -> (result: ^Skin) {
    context.allocator = memory.allocators[.SKIN]
    result = new(Skin)
    result.path, _ = strings.clone(skin_path)

    os.change_directory(result.path)
    defer os.change_directory(app.base_dir)

    skin_load_elements(result)
    skin_load_hitsounds(result)
    return result
}

skin_load_elements :: proc(skin: ^Skin) {
    for element in Skin_Element_Type {
        tex_err: os.Error
        for extension in supported_image_extensions {
            element_path := strings.concatenate({Skin_Element_Path[element], "@2x", extension})
            tex_store := &window.skin_textures[element]
            tex := skin.elements[element]

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

skin_load_hitsounds :: proc(skin: ^Skin) {
    for sample_set in Skin_Sample_Set {
        for hitsound_type in Skin_Hitsound_Type {
            stem := strings.concatenate({
                skin_sample_set_name[sample_set], "-",
                skin_hitsound_type_name[hitsound_type],
            }, context.temp_allocator)

            for extension in supported_audio_extensions {
                path := strings.concatenate({stem, extension}, context.temp_allocator)
                if !os.exists(path) {
                    continue
                }
                
                sample, ok := sample_load_file(path)
                if ok {
                    skin.hitsounds[sample_set][hitsound_type] = sample
                    break
                }
            }
        }
    }
}

skin_unload :: proc(skin: ^Skin) {
    for &set in skin.hitsounds {
        for &hitsound in set {
            if hitsound.handle != 0 {
                sample_destroy(&hitsound)
            }
        }
    }

    texture_ids: [len(Skin_Element_Type)]u32
    for element in Skin_Element_Type {
        texture_ids[element] = window.skin_textures[element].tex_id
    }
    texture_free(texture_ids[:])

    virtual.arena_free_all(&memory.arenas[.SKIN])
}

skin_reload :: proc(skin: ^Skin) {
    temp_path := strings.clone(skin.path, context.temp_allocator)
    skin_unload(skin)
    skin_load(temp_path)
}
