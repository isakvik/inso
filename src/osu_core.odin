package notosu

import "core:image/netpbm"
import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import q "core:container/queue"

import "core:fmt"

import sdl "vendor:sdl3"


osu_playfield_size_osupx :: f32(512)
playfield_rect :: Rect{ 0, 0, osu_playfield_size_osupx, osu_playfield_size_osupx }

osu_slider_curve_points_separation :: f32(2.5)

// note(isak): state struct. keep it lean, put large data fields in arenas

game: struct {
    dt: f64, 
    active_mapset: ^Mapset,
    active_map: ^Osu_Map,
    active_skin: [Skin_Element_Type]Skin_Element,
    
    mode: Game_Mode,
    
    // note(isak): map game logic fields
    
    beatmap: Beatmap,
    
    paused: bool,
    time_rate: f64,
    
    // note(isak): map game view fields

    gfx_handles: rb.Ring_Buffer(slotmap.Handle),
    temp_gfx_refs: sb.Swap_Buffer(slotmap.Handle),
    
    entities: slotmap.Slotmap(Entity),
    next_entity_id: int, // note(isak): rolling entity id sequence
    
    /*
        note(isak): entities refer to an element, which in turn refer to a set of animations that determine 
        the final transform. the given element of an entity can be overridden mid-map by scripts for effects
    */
    elements: q.Queue(Element),
    animations: q.Queue(Animation),
    
    script_gfx_objects: q.Queue(Graphics_Object),

    ui_timeline: UI_Timeline,
}

null_element := Element{}

osu_controller: struct {
    k1, k2, m1, m2: Button_State,
    k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu
    
    mouse_keys_enabled: bool,
    mouse_pos: vec2,
}

// note(isak): core types

Visibility_State :: struct {
    earliest_i, latest_i: int,
}

Hit_Object_Type :: enum {
    NONE,
    CIRCLE,
    SLIDER,
    SPINNER,
    // CUSTOM // note(isak) big plans?
}

Hit_Object :: struct {
    start_time_ms, end_time_ms: f64,
    pos: vec2,
    type: Hit_Object_Type,
    
    type_flags: int,
    hitsound_flags: byte,

    slider_path_index: int,
    slider_repeats: int,
    
    gfx_handles: []slotmap.Handle,
}

Slider_Path_Type :: enum {
    NONE,
    LINEAR,
    BEZIER,
    ARC,
    CATMULL,
}

Slider_Node :: vec2
Slider_Curve :: []Slider_Node

Slider_Path :: struct {
    pos: vec2,
    type: Slider_Path_Type,
    distance_osupx: f64,

    nodes: []Slider_Node, // note(isak): slice into our array of all nodes
    curves: []Slider_Curve, // note(isak): slice into mapset arena
    
    instance_count, first_instance_at: i32, // note(isak): this could be a slice, but data reads are probs unnecessary
}


Game_Mode :: enum {
    UNINITIALIZED,
    MENU,
    PLAY,
}

Layer :: enum {
    BACKGROUND,
    FOREGROUND,
    OVERLAY,
    HIT_OBJECTS,
    UI,
    DEBUG
}

Osu_Sample_Set :: enum {
    NORMAL,
    SOFT,
    DRUM
}

Notosu_Map :: struct {
    lua_entry_point: string,
    shaders: []Shader,
}

Osu_Map :: struct {
    using Osu_Map_File_Data: struct {
        audio_filename: string,
        audio_lead_in: f64,
        sample_set: Osu_Sample_Set,
    
        title: string,
        title_unicode: string,
        artist: string,
        artist_unicode: string,
        creator: string,
        difficulty_name: string,
    
        diff_hp_drain: f64,
        diff_circle_size: f64,
        diff_overall_difficulty: f64,
        diff_approach_rate: f64,
        diff_slider_velocity: f64,
        diff_slider_tickrate: int,
        
        bg_filename: string,
    },
    
    hit_objects: []Hit_Object,
    slider_paths: []Slider_Path,
}

osu_on_init :: proc() {
    game.next_entity_id = 1
    game.time_rate = 1.0
    game.mode = .PLAY
    
    ui_init_timeline(&game.ui_timeline)
    
    osu_controller.k1_key = sdl.Scancode.Z
    osu_controller.k2_key = sdl.Scancode.X

    osu_on_beatmap_init()
}

osu_on_beatmap_init :: proc() {
    // map graphics init
    
    q.init(&game.elements, 1024, memory.allocs[.MAPSET])
    q.append(&game.elements, null_element)
    q.init(&game.animations, 1024, memory.allocs[.MAPSET])

    write_default_elements(&game.elements, &game.animations)
    
    rb.init(&game.gfx_handles, 8192, memory.allocs[.ENTITIES])
    game.gfx_handles.length = cap(game.gfx_handles.data)
    
    sb.init(&game.temp_gfx_refs, 8192)
    slotmap.init(&game.entities, 8192)
    
    // map logic init
    
    game.beatmap.start_time_ms = -(game.beatmap.preempt_ms + game.active_map.audio_lead_in)
    game.beatmap.circle_radius_osupx = convert_circle_size_to_radius_osupx(game.active_map.diff_circle_size)
    game.beatmap.preempt_ms = convert_approach_rate_to_preempt_ms(game.active_map.diff_approach_rate)
    
    game.beatmap.length_ms = game.active_map.hit_objects[len(game.active_map.hit_objects) - 1].end_time_ms + 1000
    
    game.beatmap.hit_objects = game.active_map.hit_objects
    game.beatmap.slider_paths = game.active_map.slider_paths
    
    sound_set_position_ms(&game.beatmap.music, 1800)
    
    // todo(isak): opinionated entity pushing; needs to be rewritten to take scriptable objects and skin metrics
    // into account
    write_default_entities_from_map(game.active_map)
}

osu_on_map_destroy :: proc() {
    for &hobj in game.beatmap.hit_objects {
        hobj.gfx_handles = {}
    }
    
    rb.destroy(&game.gfx_handles)
    sb.destroy(&game.temp_gfx_refs)
    slotmap.destroy(&game.entities)
}

osu_reload_map :: proc() {
    osu_on_map_destroy()
    
    game.mode = .PLAY
    game.beatmap.visible_hit_object_state = {}
    
    game.active_mapset = mapset_free_and_reload(game.active_mapset)
    game.active_map = &game.active_mapset.osu_map
    osu_on_beatmap_init()
}


osu_on_update :: proc(dt: f64) {
    game.dt = dt
    map_dt := dt * game.time_rate * (game.paused ? 0 : 1)

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        osu_reload_map()
    }
    
    if game.beatmap.music_time_ms > game.beatmap.length_ms {
        game.beatmap.music_time_ms = clamp(game.beatmap.start_time_ms, -1800, 0)
        osu_reload_map()
    }
    
    // note(isak): game logic - map

    // note(isak): map play time is determined by the sound library (and whether we were able to play music or not), 
    // but song time interpolation is required because BASS reports play position in buffer size granularity
    music_time := get_music_position_interpolated_ms()
    game.beatmap.music_time_ms = music_time
    
    #partial switch game.mode {
        case .PLAY: handle_play_input_events()
    }
    
    hobj_it := get_visible_hobj_iterator(&game.beatmap.visible_hit_object_state, music_time)
    
    playfield_transform := transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    if valid_key_press() {
        for &hobj, i in hobj_it {
            if len(hobj.gfx_handles) == 2 {
                continue
            }
            
            if !point_in_circle(osu_controller.mouse_pos, hobj.pos, game.beatmap.circle_radius_osupx) {
                continue
            }
            
            clear_hitobject_entities(&hobj)
            
            hobj.gfx_handles = reserve_handles(&game.gfx_handles, 2) or_continue
            hobj.gfx_handles[0] = push_entity({
                flags = {.ACTIVE},
                element = element_id(.CLICKED_HIT_CIRCLE_OVERLAY),
                pos = hobj.pos,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_white,
                start_time_ms = music_time,
                end_time_ms = music_time + 600
            })
            hobj.gfx_handles[1] = push_entity({
                flags = {.ACTIVE},
                element = element_id(.CLICKED_HIT_CIRCLE),
                pos = hobj.pos,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_purple,
                start_time_ms = music_time,
                end_time_ms = music_time + 600
            })
            
            push_entity_temp({
                flags = {.ACTIVE},
                element = element_id(.JUDGMENT),
                pos = hobj.pos,
                size = [2]f32{0.5, 1} * game.beatmap.circle_radius_osupx,
                anchor = .CENTER,
                color = color_sky_blue,
                
                angle_vel = 360.0,
                
                start_time_ms = music_time,
                end_time_ms = music_time + 600
            })
        }
    }
    
    // game render
    
    r_push_layer(.HIT_OBJECTS)
    
    for hobj, i in hobj_it {
        if music_time < hobj.start_time_ms - game.beatmap.preempt_ms || hobj.end_time_ms < music_time {
            continue
        }
        if hobj.type == .SLIDER {
            render_slider(&window.renderer, &game.beatmap.slider_paths[hobj.slider_path_index])
        }
    }
    
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(playfield_transform)

    // note(isak): we render hitobject elements back to front for correct blending
    // todo(isak): @speed - long iteration, but seems necessary to not cull gfx objects outside an 
    // object's given start/end time window
    #reverse for &hobj in game.beatmap.hit_objects {
        #reverse for handle in hobj.gfx_handles {
            e := slotmap.get(&game.entities, handle) or_continue
            if .ACTIVE in e.flags {
                render_entity(e, music_time)
            }
        }
    }
    
    process_and_draw_temp_gfx_handles()
    
    // render ui
    // todo(isak): "screens" implementation for determining relevant UI components?

    seek_to_ms: f64
    if ui_update_timeline(&game.ui_timeline, &seek_to_ms) {
        sound_set_position_ms(&game.beatmap.music, seek_to_ms)
    }
    render_timeline(&game.ui_timeline)
    
    render_input_display()
}

mapset_texture :: proc(name: string) -> u32 {
    assert(game.active_mapset != nil)
    return map_texture(game.active_mapset.texture_slot_by_name[name])
}

mapset_shader :: proc(name: string) -> u32 {
    assert(game.active_mapset != nil)
    return map_pipeline(game.active_mapset.shader_slot_by_name[name])
}

// note(isak): this function assumes the start times of objects are sorted, but doesn't require end times to be.
// a pathological case might be a 2B element that stretches from the beginning of the map to the end
// todo(isak): it doesn't read from the latest object state; it's a viable small optimization
get_visible_hobj_iterator :: proc(state: ^Visibility_State, time: f64) -> []Hit_Object {
    result: []Hit_Object
    updated_from_index := state.earliest_i

    hit_objects := game.beatmap.hit_objects
    if len(hit_objects) > 0 {
        looking_for_finished_objects := true
        count_until_next_unstarted_hobj: int
        includes_final_index := 1

        for hobj, i in hit_objects[state.earliest_i:] {
            count_until_next_unstarted_hobj = i
            if time < hobj.start_time_ms - game.beatmap.preempt_ms {
                includes_final_index = 0
                break
            }
            if looking_for_finished_objects {
                if hobj.end_time_ms < time {
                    updated_from_index += 1
                } else {
                    looking_for_finished_objects = false
                }
            }
        }
        state.latest_i = updated_from_index + count_until_next_unstarted_hobj + includes_final_index
        state.earliest_i = updated_from_index
        result = hit_objects[state.earliest_i:min(state.latest_i, len(hit_objects))]
    }
    return result
}


split_path_into_curves :: proc(path: ^Slider_Path, alloc: runtime.Allocator) -> []Slider_Curve {
    // todo(isak): we just make a curve for each node here for testing, but we have to read nodes to figure out 
    // which ones are red nodes and split by those
    result := make_slice([]Slider_Curve, 1)
    result[0] = path.nodes[:]
    return result
}

// https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L878
// note(yokes): "t" is for time which means we need to calculate the time it takes to get "d" distance beforehand
calculate_bezier_point_from_time :: proc(t: f64, curve: Slider_Curve) {
    
    //int i := 0;
    for point in curve {
        
    }


}

bezier_to_piecewise_linear :: proc(curve: Slider_Curve, degree: int) {
    assert(degree < 1, fmt.tprintfln("curve degree error: lower than 1 ::", degree))
    
}

base_dist : f32 = 2.5
write_instances_from_straight :: proc(instance_buf: ^Buffer(vec2), start_pos: [2]f32, end_pos: [2]f32, curve_distance: f64) -> f64 {
    remaining_distance := curve_distance
    h := (end_pos.y - start_pos.y) / (end_pos.x - start_pos.x)
    y := base_dist / (math.pow(math.pow(h, 2) + 1, 0.5))
    x := base_dist * h / (math.pow(math.pow(h, 2) + 1, 0.5))
    iterations := abs((end_pos.x - start_pos.x) / x)
    xy_vector : [2]f32 = {x, y}
    for i in 0..<iterations {
        buffer_push(instance_buf, start_pos + i * xy_vector)
    }

    travelled_distance := math.pow(math.pow(end_pos.y - start_pos.y, 2) + math.pow(end_pos.x - start_pos.x, 2), 0.5)
    buffer_push(instance_buf, start_pos + iterations * xy_vector)
    remaining_distance = curve_distance - f64(travelled_distance)
    return remaining_distance
}

write_instances_from_curve :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64) -> f64 {
    remaining_distance := curve_distance    
    if type == .ARC {
        is_parallel: bool

        if is_parallel {
            remaining_distance = write_instances_from_straight(instance_buf, curve[0], curve[2], curve_distance)
        } else {
            //todo(yokes): instance_buf points between nodes (arc)
            remaining_distance = write_instances_from_straight(instance_buf, curve[0], curve[1], curve_distance)
        }
    } else if type == .LINEAR || len(curve) < 3 {
        //todo(yokes): instance_buf points between nodes (linear) copy "is_parrallel" code or something
        remaining_distance = write_instances_from_straight(instance_buf, curve[0], curve[1], curve_distance)
    } else {
        //todo(yokes): instance_buf points inbetween nodes (bezier) https://en.wikipedia.org/wiki/B%C3%A9zier_curve
        remaining_distance = write_instances_from_straight(instance_buf, curve[0], curve[1], curve_distance)
    }

    return remaining_distance
}

/*
    note(isak): calculates and writes slider instances, or positions used for rendering to the screen, based on a 
    given path. it should write instances into the bounds of [0, playfield_size]
*/
write_instances_from_path :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, alloc: runtime.Allocator = context.allocator
) -> (i32, i32) {
    instance_offset := instance_buf.count

    // todo(isak): test code that just pushes a point for each node
    path.curves = split_path_into_curves(path, alloc)
    for curve in path.curves {
        buffer_push(instance_buf, curve[0])
    }

    // todo(yokes): test code with straight sliders (start- and endpoint)
    //buffer_push(instance_buf, [[100,100], [200, 200]])
    if false {
        return instance_buf.count - instance_offset, instance_offset
    }

    distance_to_cover := path.distance_osupx
    for curve in path.curves {
        if distance_to_cover > 0 {
            distance_covered_by_curve := 
                write_instances_from_curve(instance_buf, 
                                           curve, 
                                           path.type,
                                           distance_to_cover)
            distance_to_cover -= distance_covered_by_curve
        }
    }
    if true {
        return instance_buf.count - instance_offset, instance_offset
    }
    

    // todo(yokes): if we still have distance left over but zero curves, a linear path needs to cover
    // the remaining distance. maybe mcosu has something neat for this?
    if distance_to_cover > 0 {

    }

    return 0, 0
}

//////////////////////////////////////////////////////
// NOTE(yokes): in-game button input api

is_down :: proc(button: Button_State) -> bool {
    return button.is_down
}

is_pressed :: proc(button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

is_released :: proc(button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

is_key_down :: proc(code: sdl.Scancode) -> bool {
    return keyboard.buttons[code]
}

is_key_pressed :: proc(code: sdl.Scancode) -> bool {
    return keyboard.buttons[code] && !keyboard.buttons_prev_frame[code]
}

is_key_released :: proc(code: sdl.Scancode) -> bool {
    return !keyboard.buttons[code] && keyboard.buttons_prev_frame[code]
}
