package notosu

import sb "swap_buffer"
import "slotmap"
import rb "ring_buffer"

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import q "core:container/queue"

import sdl "vendor:sdl3"


playfield_size_osupx :: f32(512)
playfield_rect :: Rect{ 0, 0, playfield_size_osupx, playfield_size_osupx }

osu_slider_curve_points_separation :: f32(2.5)

// note(isak): state struct. keep it lean, put large data fields in arenas and point to it here
game: struct {
    dt: f64, 
    active_mapset: ^Mapset,
    active_notosu_map: ^Notosu_Map,
    active_map: ^Osu_Map,
    active_skin: [Skin_Element_Type]Skin_Element,
    
    mode: Game_Mode,
    
    // note(isak): map game logic fields
    
    beatmap: Beatmap,
    
    paused: bool,
    time_rate: f32,
    
    // note(isak): map game view fields
    
    ui_timeline: UI_Timeline,
    
    input: struct {
        k1, k2, m1, m2: Button_State,
        k1_key, k2_key: sdl.Scancode, //TODO(yokes): add keybinding menu
        
        mouse_keys_enabled: bool,
        mouse_pos: vec2,
    }
}

// note(isak): we reserve the first slot for safety reasons, and we crash on modification for debug reasons
@(rodata) null_drawable := Drawable{}
@(rodata) null_element := Element{}

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
    index: int,
    type: Hit_Object_Type,
    start_time_ms, end_time_ms: f64,
    pos, script_pos_translation: vec2,
    
    type_flags: int,
    hitsound_flags: byte,

    slider_path_index: int,
    slider_repeats, slider_repeat_at: int,
    
    gfx_handles: []Drawable_Handle,
}

hit_object_pos :: proc(hobj: ^Hit_Object) -> vec2 {
    return hobj.pos + hobj.script_pos_translation
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
    HIT_OBJECTS,
    OVERLAY,
    UI,
    DEBUG
}

Judgement :: enum {
    NONE,
    
    MISS,
    BAD,
    GOOD,
    GREAT,
    
    SLIDER_SMALL_SCOREPOINT, // 10
    SLIDER_LARGE_SCOREPOINT, // 30
    
    IGNORED_HIT, // note(isak): used when we need a result that doesn't affect score 
    COMBO_BREAK, // note(isak): intended for scripted misses
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
    
    audio_filepath: string,
    hit_objects: []Hit_Object,
    slider_paths: []Slider_Path,
}

osu_on_init :: proc() {
    game.time_rate = 1.0
    game.mode = .PLAY
    
    ui_init_timeline(&game.ui_timeline)
    
    game.input.k1_key = sdl.Scancode.Z
    game.input.k2_key = sdl.Scancode.X

    beatmap_on_init(&game.beatmap)
}


osu_on_update :: proc(dt: f64) {
    game.dt = dt

    updated_systems := mapset_check_system_file_watch(&game.active_mapset.watch)
    if updated_systems[.OSU_FILE] {
        beatmap_reload(&game.beatmap)
    } else if updated_systems[.SCRIPTS] {
        lua_reload(game.active_notosu_map.lua_entry_point)
        lua_call_beatmap_func("on_init")
    }
    
    // note(isak): game logic - map
    
    beatmap_on_update(&game.beatmap)
    
    // todo(isak): this really handles a bunch of debug stuff too. fix up the modes and such
    #partial switch game.mode {
        case .PLAY: handle_play_input_events()
    }
    
    map_time := game.beatmap.music_time_ms
    hobj_it := get_visible_hobj_iterator(&game.beatmap.visible_hit_object_state, map_time)
    
    playfield_transform := transform_from_bounds(rect_to_array(playfield_rect), window.aspect_ratio)
    
    //-- @temp
    // todo(isak): valid key presses system needs testing
    if valid_key_press() {
        for &hobj, i in hobj_it {
            if len(hobj.gfx_handles) == 2 {
                continue
            }
            
            hobj_pos := hit_object_pos(&hobj)
            if !point_in_circle(game.input.mouse_pos, hobj_pos, game.beatmap.circle_radius_osupx) {
                continue
            }
            
            clear_hitobject_drawables(&hobj)
            
            hobj.gfx_handles = reserve_handles(&game.beatmap.persistent_gfx, 2) or_continue
            
            hobj.gfx_handles[0] = drawable_new({
                flags = {.ACTIVE},
                element = builtin_element_slot(.CLICKED_HIT_CIRCLE_OVERLAY),
                layer = .HIT_OBJECTS,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_white,
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
            hobj.gfx_handles[1] = drawable_new({
                flags = {.ACTIVE},
                element = builtin_element_slot(.CLICKED_HIT_CIRCLE),
                layer = .HIT_OBJECTS,
                size = game.beatmap.circle_radius_osupx * 2,
                anchor = .CENTER,
                color = color_purple,
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
            
            drawable_new_expiring(&game.beatmap.gameplay_expiring_gfx, {
                flags = {.ACTIVE},
                element = builtin_element_slot(.JUDGEMENT),
                layer = .HIT_OBJECTS,
                pos = hobj_pos,
                size = [2]f32{0.5, 1} * game.beatmap.circle_radius_osupx,
                anchor = .CENTER,
                color = color_sky_blue,
                
                angle_vel = 360.0,
                
                start_time_ms = map_time,
                end_time_ms = map_time + 600
            })
        } 
    }
    //--
    
    
    if lua_cares_about_event(.ON_KEY_DOWN) {
        for code in sdl.Scancode {
            if is_key_pressed(code) do lua_beatmap_on_key_pressed(code)
        }
    }
    if lua_cares_about_event(.ON_KEY_UP) {
        for code in sdl.Scancode {
            if is_key_released(code) do lua_beatmap_on_key_released(code)
        }
    }
    if lua_cares_about_event(.ON_CONTROLLER_PRESSED) {
        if is_pressed(game.input.k1) do lua_beatmap_on_controller_pressed("k1")
        if is_pressed(game.input.k2) do lua_beatmap_on_controller_pressed("k2")
        if is_pressed(game.input.m1) do lua_beatmap_on_controller_pressed("m1")
        if is_pressed(game.input.m2) do lua_beatmap_on_controller_pressed("m2")
    }
    if lua_cares_about_event(.ON_CONTROLLER_RELEASED) {
        if is_released(game.input.k1) do lua_beatmap_on_controller_released("k1")
        if is_released(game.input.k2) do lua_beatmap_on_controller_released("k2")
        if is_released(game.input.m1) do lua_beatmap_on_controller_released("m1")
        if is_released(game.input.m2) do lua_beatmap_on_controller_released("m2")
    }
    
    
    // beatmap render
    
    r_bind_layer_and_push_current_state(.HIT_OBJECTS)
    
    //-- @temp
    // todo(isak): for the eventual rewrite here that takes object type into account, consider a
    // function pointer in the hitobject struct that renders (and maybe one that updates? continual
    // logic is necessary for sliders... hitting circles is a keyboard event kind of thing)
    for &hobj in hobj_it {
        if map_time < hobj.start_time_ms - game.beatmap.preempt_ms || hobj.end_time_ms < map_time {
            continue
        }
        if hobj.type == .SLIDER {
            render_slider(&window.renderer, &hobj)
        }
    }
    //--
    
    r_bind_framebuffer({read = .DEFAULT, write = .DEFAULT})
    r_push_transform(playfield_transform)

    // note(isak): we render hitobject elements back to front for correct blending
    // todo(isak): @speed - use persistent_gfx for visible set optimization
    #reverse for &hobj in game.beatmap.hit_objects {
        #reverse for handle in hobj.gfx_handles {
            e := slotmap.get(&game.beatmap.drawables, handle) or_continue
            if .ACTIVE in e.flags {
                render_drawable(e, map_time, hit_object_pos(&hobj))
            }
        }
    }
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.gameplay_expiring_gfx)
    
    r_bind_layer_and_push_current_state(.BACKGROUND, transform = playfield_transform)
    
    process_and_draw_expiring_gfx_refs(&game.beatmap.map_expiring_gfx)
    
    // ui render
    
    // todo(isak): "screens" implementation for determining relevant UI components?
    handle_and_render_timeline()
    render_input_display()
}

// note(isak): this function assumes the start times of objects are sorted, but doesn't require end times to be.
// a pathological case might be a 2B element that stretches from the beginning of the map to the end
// todo(isak): latest object state is not implemented
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

handle_play_input_events :: proc() {
    if is_key_pressed(.ESCAPE) || is_key_pressed(.SPACE) {
        beatmap_pause(&game.beatmap, !game.paused)
    }
    if is_key_pressed(.R) {
        beatmap_reload(&game.beatmap)
    }
    if is_key_pressed(.HOME) {
        game.time_rate = 1
    }
    if is_key_pressed(.PAGEUP) {
        game.time_rate *= 2
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    if is_key_pressed(.PAGEDOWN) {
        game.time_rate /= 2
        sound_set_speed(&game.beatmap.music, game.time_rate)
    }
    
    if is_key_pressed(.F10) {
        game.input.mouse_keys_enabled = !game.input.mouse_keys_enabled
    }
    
    game.input.k1.is_down = keyboard.buttons[game.input.k1_key]
    game.input.k1.was_down = keyboard.buttons_prev_frame[game.input.k1_key]
    game.input.k2.is_down = keyboard.buttons[game.input.k2_key]
    game.input.k2.was_down = keyboard.buttons_prev_frame[game.input.k2_key]
    game.input.m1 = mouse.buttons[.LEFT]
    game.input.m2 = mouse.buttons[.RIGHT]
}

valid_key_press :: proc() -> bool {
    if game.input.mouse_keys_enabled {
        if is_pressed(game.input.k1) && !is_down(game.input.m1) ||
            is_pressed(game.input.k2) && !is_down(game.input.m2) {
            return true
        }
        
        return is_pressed(game.input.m1) && !is_down(game.input.k1) || 
            is_pressed(game.input.m2) && !is_down(game.input.k2)
    } else {
        return is_pressed(game.input.k1) || is_pressed(game.input.k2)
    }
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
calculate_bezier_point_from_time :: proc(t: f64, curve: Slider_Curve, base_slider_velocity: f64, slider_velocity: f64) {
    //note(yokes): draw sliderball, move sliderball accordingly?
    //note(yokes): quick test on stable, 1x sv 5/4 slider has 500 distance. i believe i understand how the math works now
    //note(yokes): if a green line is in the middle of a slider, should it change the slider speed mid-slider? stable nor lazer does this but i believe this would leave more room... nvm not possible atm

    slider_speed := base_slider_velocity * slider_velocity //base_sv is 1 when making a new map
    //int i := 0;
    for point in curve {
        
    }


}

base_dist : f32 = 2.5

calculate_points_between_instances :: proc(instance_buf: ^Buffer(vec2), output: ^q.Queue(vec2), curve_distance: f64) -> (total_distance: f64) {
    curr_distance : f64 = 0
    for point, i in output.data[:output.len] {
        if i < int(output.len) - 1 {
            curr_distance = f64(linalg.vector_length(q.get(output, i + 1) - q.get(output, i)))
            total_distance += curr_distance

            if f32(curr_distance) > base_dist {
                //todo(yokes): at the moment the end point overlaps an instance with the start point of the next output.data
                write_instances_from_straight(instance_buf, q.get(output, i), q.get(output, i + 1), curr_distance)
            } else {
                buffer_push(instance_buf, point)
            }

        } else {
            buffer_push(instance_buf, point)
        }
    }
    return curve_distance
}

Circular_Arc_Properties :: struct {
    is_valid: bool,
    theta_start, theta_range, theta_end: f64,
    direction: f64,
    radius: f32,
    center: vec2,
}

circular_arc_tol : f32 = 0.1
// https://github.com/ppy/osu-framework/blob/ca40f0a4d314b2acbad09f63e63824ae2670aa29/osu.Framework/Utils/PathApproximator.cs#L175
circular_arc_to_piecewise_linear :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, curve_distance: f64) -> (total_distance: f64) {
    pr : Circular_Arc_Properties = circular_arc_properties_from_triangle(curve)
    if !pr.is_valid {
        instance_count, instances_at : i32
        instance_count, instances_at, total_distance = bezier_to_piecewise_linear(instance_buf, curve, curve_distance)
        return total_distance
    }

    amount_points := 2 * pr.radius <= circular_arc_tol ? 2 : max(2, int(math.ceil(f32(pr.theta_range) / (2 * math.acos_f32(1 - circular_arc_tol / pr.radius)))))

    output : q.Queue(vec2)
    q.init(&output, allocator = context.temp_allocator)

    for i in 0..<amount_points {
        fract := f64(i) / f64(amount_points - 1)
        theta := pr.theta_start + pr.direction * fract * pr.theta_range
        o : vec2 = {math.cos(f32(theta)), math.sin(f32(theta))} * pr.radius
        q.push(&output, pr.center + o)
    }

    total_distance = calculate_points_between_instances(instance_buf, &output, curve_distance)
    return total_distance
}

circular_arc_properties_from_triangle :: proc(curve: Slider_Curve) -> (result: Circular_Arc_Properties) {
    a : vec2 = curve[0]
    b : vec2 = curve[1]
    c : vec2 = curve[2]

    if abs((b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y)) < 0.001 {
        result.is_valid = false
        return
    }

    d := 2 * (a.x * (b - c).y + b.x * (c - a).y + c.x * (a - b).y)
    a_sq := linalg.vector_length2(a)
    b_sq := linalg.vector_length2(b)
    c_sq := linalg.vector_length2(c)

    result.center = {
        a_sq * (b - c).y + b_sq * (c - a).y + c_sq * (a - b).y,
        a_sq * (c - b).x + b_sq * (a - c).x + c_sq * (b - a).x} / d

    d_a := a - result.center
    d_c := c - result.center

    result.radius = linalg.vector_length(d_a)

    result.theta_start = math.atan2(f64(d_a.y), f64(d_a.x))
    result.theta_end = math.atan2(f64(d_c.y), f64(d_c.x))

    for result.theta_end < result.theta_start {
        result.theta_end += 2 * math.PI
    }

    result.direction = 1
    result.theta_range = result.theta_end - result.theta_start

    ortho_a_to_c := c - a
    ortho_a_to_c = {ortho_a_to_c.y, -ortho_a_to_c.x}

    if linalg.vector_dot(ortho_a_to_c, b - a) < 0 {
        result.direction = -result.direction
        result.theta_range = 2 * math.PI - result.theta_range
    }

    result.is_valid = true
    return
}

bezier_to_piecewise_linear :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, curve_distance: f64) -> (instance_count, instances_at: i32, total_distance: f64) {
    return b_spline_to_piecewise_linear(instance_buf, curve, max(1, len(curve) - 1), curve_distance)
    
}

b_spline_to_piecewise_linear :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, degree: int, curve_distance: f64) -> (instance_count, instances_at: i32, total_distance: f64) {
    assert(degree >= 1, fmt.tprintfln("curve degree error: lower than 1 ::", degree))

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L86
    if len(curve) < 2 {
        return 0, instance_buf.count, 0
    }

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L91
    point_count : int = len(curve) - 1
    degree := min(degree, point_count)

    output : q.Queue(vec2)
    q.init(&output, allocator = context.temp_allocator)
    
    to_flatten : q.Queue([]vec2)
    temp_points: q.Queue(vec2)
    q.init(&temp_points, allocator = context.temp_allocator)
    q.init(&to_flatten, allocator = context.temp_allocator) //todo(yokes): check capacity, default for now
    q.append_elems(&to_flatten, b_spline_to_bezier_internal(&temp_points, curve, degree))
    free_buffers : q.Queue([]vec2)
    q.init(&free_buffers, allocator = context.temp_allocator) //todo(yokes): check capacity, default for now

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L102

    subdivision_buffer_1 := make([]vec2, degree + 1, allocator = context.temp_allocator)
    subdivision_buffer_2 := make([]vec2, degree * 2 + 1, allocator = context.temp_allocator)

    left_child : []vec2 = subdivision_buffer_2

    for to_flatten.len > 0 {
        parent : []vec2 = q.pop_back(&to_flatten)
        
        // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L119
        if bezier_is_flat_enough(parent) {
            bezier_approximate(parent, &output, subdivision_buffer_1, subdivision_buffer_2, degree + 1)

            q.push(&free_buffers, parent)
            continue
        }

        // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L129
        right_child : []vec2 = free_buffers.len > 0 ? q.pop_back(&free_buffers) : make([]vec2, degree + 1, context.temp_allocator)
        bezier_subdivide(parent, left_child, right_child, subdivision_buffer_1, degree + 1)

        for i in 0..<degree + 1 {
            parent[i] = left_child[i]
        }

        q.push(&to_flatten, right_child)
        q.push(&to_flatten, parent)
    }

    //main goal is to edit the curve such that the instances pushed are the new coordinates where the slider is drawn
    instances_at = instance_buf.count
    total_distance = calculate_points_between_instances(instance_buf, &output, curve_distance)
    return i32(output.len), instances_at, total_distance
}

bezier_tolerance : f32 = 0.25
bezier_is_flat_enough :: proc(curve: Slider_Curve) -> bool {
    for i in 1..<len(curve) - 1 {
        if linalg.vector_length2((curve[i - 1] - 2 * curve[i] + curve[i + 1])) > bezier_tolerance * bezier_tolerance * 4 {
            return false
        }
    }
    return true
}

//todo(yokes): this can be optimized by buffer_pushing instances instead of storing coordinates to an output
bezier_approximate :: proc(curve: Slider_Curve, output: ^q.Queue(vec2), subdivision_buffer_1: []vec2, subdivision_buffer_2: []vec2, count: int) {
    l := subdivision_buffer_2
    r := subdivision_buffer_1

    bezier_subdivide(curve, l, r, subdivision_buffer_1, count)

    for i in 0..<count - 1 {
        l[count + i] = r[i + 1]
    }

    q.push_back(output, curve[0])
    
    for i in 1..<count - 1 {
        index := 2 * i
        p := 0.25 * (l[index - 1] + 2 * l[index] + l[index + 1])
        q.push_back(output, p)
    }
}

bezier_subdivide :: proc(curve: Slider_Curve, l: []vec2, r: []vec2, subdivision_buffer: []vec2, count: int) {
    midpoints := subdivision_buffer

    for i in 0..<count {
        midpoints[i] = curve[i]
    }

    for i in 0..<count {
        l[i] = midpoints[0]
        r[count - i - 1] = midpoints[count - i - 1]

        for j in 0..<count - i - 1 {
            midpoints[j] = (midpoints[j] + midpoints[j + 1]) / 2
        }
    }

}

b_spline_to_bezier_internal :: proc(result: ^q.Queue(vec2), curve: Slider_Curve, degree: int) -> []vec2 {
    point_count := len(curve) - 1
    local_degree := min(degree, point_count)

    if degree == point_count {
        q.push_back_elems(result, ..curve[:]) // Uses push_back to avoid reversing the stack later
        return curve[:]
    }
    else
    {
        for i in 0..<point_count - degree {
            sub_bezier := make([]vec2, degree + 1, allocator = context.temp_allocator)
            sub_bezier[0] = curve[i]

            for j in 0..<degree - 1 {
                sub_bezier[j + 1] = curve[i + 1]

                for k in 1..<degree - j {
                    l := f32(min(k, point_count - degree - i))
                    curve[i + k] = (l * curve[i + k] + curve[i + k + 1]) / (l + 1)
                }
            }
            sub_bezier[degree] = curve[i + 1]
            q.push_back_elems(result, ..sub_bezier[:])
        }
        q.push_back_elems(result, ..curve[(point_count - degree):])
        return curve[(point_count - degree):]
    }
}

write_instances_from_straight :: proc(instance_buf: ^Buffer(vec2), start_pos: vec2, end_pos: vec2, curve_distance: f64) -> f64 {
    remaining_distance := curve_distance
    curr_distance : f32 = 0
    xy_vector : vec2 = end_pos - start_pos
    iterations := linalg.length(xy_vector) / base_dist

    for i in 0..<iterations {
        curr_distance += base_dist
        buffer_push(instance_buf, start_pos + i * xy_vector / iterations)
        
        if (curr_distance + base_dist) > f32(remaining_distance) {
            remaining_distance = remaining_distance - f64(curr_distance)
            iterations_remaining := f32(remaining_distance) / base_dist
            buffer_push(instance_buf, start_pos + iterations_remaining * xy_vector)
            break
        }
    }

    travelled_distance := math.pow(math.pow(end_pos.y - start_pos.y, 2) + math.pow(end_pos.x - start_pos.x, 2), 0.5)
    remaining_distance = curve_distance - f64(travelled_distance)
    if remaining_distance < 0.01 {
        return 0
    }
    return f64(travelled_distance)
}

write_instances_from_curve :: proc(instance_buf: ^Buffer(vec2), curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64) -> f64 {
    remaining_distance := curve_distance
    instance_count, instances_at : i32
    if type == .ARC {
        //todo(yokes): copy the tolerance from lazer code to check if a slider is parallell
        is_parallel: bool

        if is_parallel {
            remaining_distance = write_instances_from_straight(instance_buf, curve[0], curve[2], curve_distance)
        } else {
            remaining_distance = circular_arc_to_piecewise_linear(instance_buf, curve, curve_distance)
        }
    } else if type == .LINEAR || len(curve) < 3 {
        remaining_distance = write_instances_from_straight(instance_buf, curve[0], curve[1], curve_distance)
    } else {
        instance_count, instances_at, remaining_distance = b_spline_to_piecewise_linear(instance_buf, curve, max(1, len(curve)), curve_distance)
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
    /*
    for curve in path.curves {
        buffer_push(instance_buf, curve[0])
    }*/

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

is_down :: proc "c" (button: Button_State) -> bool {
    return button.is_down
}

is_pressed :: proc "c" (button: Button_State) -> bool {
    return button.is_down && !button.was_down
}

is_released :: proc "c" (button: Button_State) -> bool {
    return !button.is_down && button.was_down
}

is_key_down :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code]
}

is_key_pressed :: proc "c" (code: sdl.Scancode) -> bool {
    return keyboard.buttons[code] && !keyboard.buttons_prev_frame[code]
}

is_key_released :: proc "c" (code: sdl.Scancode) -> bool {
    return !keyboard.buttons[code] && keyboard.buttons_prev_frame[code]
}
