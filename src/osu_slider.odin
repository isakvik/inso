package notosu

import "core:path/slashpath"
import "core:log"
import "base:runtime"
import "core:container/queue"
import "core:math"
import "core:math/linalg"
import "core:slice"

base_dist : f64 = 2.5
slider_max_points : f64 = 9999

split_path_into_curves :: proc(path: ^Slider_Path, alloc: runtime.Allocator) -> (result: []Slider_Curve) {
    
    curves := make([dynamic]Slider_Curve)
    
    if len(path.nodes) >= 2 {
        curve_count := 1
        first_node_i := 0
        
        append(&curves, Slider_Curve{})
        first_curve := &curves[0]
        
        current_curve := first_curve
        prev_node := Slider_Node{min(f32), min(f32)}
        
        for node, i in path.nodes {
            if i == len(path.nodes) - 1 {
                current_curve^ = path.nodes[first_node_i:len(path.nodes)]
                break
            }
            
            if node == prev_node {
                current_curve^ = path.nodes[first_node_i:i]
                
                append(&curves, Slider_Curve{})
                current_curve = &curves[len(curves) - 1]
                
                first_node_i = i
                curve_count += 1
            }
            prev_node = node
        }
        result = curves[:]
    } else {
        result = make([]Slider_Curve, 1)
        result[0] = path.nodes[:]
    }
    return result
}

calculate_curve_from_time :: proc(hobj: ^Hitobject, time_at: f64, path: ^Slider_Path) -> (pos_at: vec2) {
    //time stuff: osu_mapset.odin ~#L825
    if hobj.type != .SLIDER {
        return hobj.pos
    }
    //todo(yokes): find which slider and curve is currently active using time_at
    //bezier: needs logic fixes, sliderball does not move linearly
    //arc: done
    //straight: done
    slider_duration := (hobj.end_time_ms - hobj.start_time_ms) / f64(hobj.slider_state.path_travel_count)
    current_repeat := int(math.floor_f64((time_at - hobj.start_time_ms) / slider_duration))
    time_ref := time_at - slider_duration * f64(current_repeat)
    t := (time_at - hobj.start_time_ms) / (hobj.end_time_ms - hobj.start_time_ms)

    if path.type == .BEZIER {
        distance_duration : f64 = 0
        duration_checkpoint : f64 = 0 // holds the ms of previous distance_duration
        curve_distance : f64 = 0
        distance_travelled : f64 = 0
        // note(yokes): i believe total distance resets every frame, so it doesn't actually check future curves
        distance_to_travel : f64 = path.distance_osupx

        // todo(yokes): make new logic for calculating slider ball pos on bezier (should only need to get "t" correctly)

        pos_at = calculate_bezier_point_from_time(hobj, time_at, path)
        
    } else if path.type == .ARC {
        pos_at = calculate_bezier_point_from_time(hobj, time_at, path)
        /*
        curve := path.curves[0]
        if current_repeat % 2 == 0 {pos_at.x += path.pos.x
            pos_at = calculate_arc_point_from_time(time_ref, hobj.start_time_ms, hobj.end_time_ms, curve, false)
        } else {
            pos_at = calculate_arc_point_from_time(time_ref, hobj.start_time_ms, hobj.end_time_ms, curve, true)

        }*/
    } else if path.type == .LINEAR {
        pos_at = calculate_straight_point_from_time(hobj, time_at, path)
    }
    return pos_at + hobj.script_pos_translation
}

calculate_bezier_curve_distance :: proc(hobj: ^Hitobject, path: ^Slider_Path, curve: Slider_Curve) -> (distance: f64) {

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L86
    if len(curve) < 2 {
        return 0
    }

    new_curve := slice.clone(curve, context.temp_allocator)

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L91
    point_count : int = len(curve) - 1
    degree := min(max(1, len(curve) - 1), point_count)

    output : queue.Queue(vec2)
    queue.init(&output, allocator = context.temp_allocator)
    
    to_flatten : queue.Queue([]vec2) //todo(yokes): should contain all curves which are not approximated well enough yet
    temp_points: queue.Queue(vec2)
    queue.init(&temp_points, allocator = context.temp_allocator)
    queue.init(&to_flatten, allocator = context.temp_allocator) //todo(yokes): check capacity, default for now
    queue.append_elems(&to_flatten, b_spline_to_bezier_internal(&temp_points, new_curve, degree))
    free_buffers : queue.Queue([]vec2)
    queue.init(&free_buffers, allocator = context.temp_allocator) //todo(yokes): check capacity, default for now

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L102

    subdivision_buffer_1 := make([]vec2, degree + 1, allocator = context.temp_allocator)
    subdivision_buffer_2 := make([]vec2, degree * 2 + 1, allocator = context.temp_allocator)

    left_child : []vec2 = subdivision_buffer_2

    for to_flatten.len > 0 {
        parent : []vec2 = queue.pop_back(&to_flatten)
        
        // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L119
        if bezier_is_flat_enough(parent) {
            bezier_approximate(parent, &output, subdivision_buffer_1, subdivision_buffer_2, degree + 1)

            queue.push(&free_buffers, parent)
            continue
        }

        // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L129
        right_child : []vec2 = free_buffers.len > 0 ? queue.pop_back(&free_buffers) : make([]vec2, degree + 1, context.temp_allocator)
        bezier_subdivide(parent, left_child, right_child, subdivision_buffer_1, degree + 1)

        for i in 0..<degree + 1 {
            parent[i] = left_child[i]
        }

        queue.push(&to_flatten, right_child)
        queue.push(&to_flatten, parent)
    }

    distance = calculate_distance_from_piecewise(path, &output, hobj.slider_state.distance)
    return distance
}

calculate_distance_from_piecewise :: proc(path: ^Slider_Path, output: ^queue.Queue(vec2), curve_distance: f64) -> (total_distance: f64) {
    for point, i in output.data[:output.len] {
        if i < int(output.len) - 1 {
            curr_distance := f64(linalg.vector_length(queue.get(output, i + 1) - queue.get(output, i)))
            total_distance += curr_distance
            /*
            if total_distance > curve_distance {
                break
            }*/
        }
        
        path.bounds_min.x, path.bounds_min.y = min(path.bounds_min.x, point.x), min(path.bounds_min.y, point.y)
        path.bounds_max.x, path.bounds_max.y = max(path.bounds_max.x, point.x), max(path.bounds_max.y, point.y)
    }
    return total_distance
}

// https://github.com/McKay42/McOsu/blob/db2add20ea291f6f3b6d022fcd4eba100a5bd161/src/App/Osu/OsuSliderCurves.cpp#L230
// https://github.com/McKay42/McOsu/blob/master/src/App/Osu/OsuSliderCurves.cpp#L435
// todo(yokes): beziers are slower than arcs and straights. why?
// note(yokes): "t" is for time which means we need to calculate the time it takes to get "d" distance beforehand
calculate_bezier_point_from_time :: proc(hobj: ^Hitobject, time_at: f64, path: ^Slider_Path) -> (point: vec2) {

    path_instances := window.renderer.slider_instances.data[path.first_instance_at:path.first_instance_at+path.instance_count]

    if len(path_instances) < 1 {
        return vec2({0,0})
    }
    
    curve_m_i := min(i64(path.distance_osupx / clamp(base_dist, 1.0, 100.0)), i64(slider_max_points), i64(len(path_instances) - 1))
    //curve_m_i := min(i64(slider_max_points), i64(len(path_instances) - 1))

    duration := hobj.end_time_ms - hobj.start_time_ms
    elapsed  := clamp(time_at - hobj.start_time_ms, 0, duration)

    repeat_count := hobj.slider_state.path_travel_count
    t_passes  := (elapsed / duration) * f64(repeat_count)
    pass_idx  := min(int(t_passes), repeat_count - 1)
    pass_frac := t_passes - f64(pass_idx)

    t_on_path := pass_frac if pass_idx % 2 == 0 else 1.0 - pass_frac

    index_f := t_on_path * f64(curve_m_i)
    index := i64(index_f)

    if index >= curve_m_i {
        if curve_m_i > -1 && curve_m_i < i64(len(path_instances)) {
            return path_instances[curve_m_i]
        }
    } else {
        pos_i := path_instances[index]
        pos_i2 := path_instances[index + 1]

        t2 : f64 = index_f - f64(index)

        return vec2({linalg.lerp(pos_i.x, pos_i2.x, f32(t2)), linalg.lerp(pos_i.y, pos_i2.y, f32(t2))})
    }
    return vec2({0, 0})
}

calculate_arc_point_from_time :: proc(time_at: f64, time_start: f64, time_end: f64, curve: Slider_Curve, reversed: bool) -> (point: vec2) {
    pr : Circular_Arc_Properties = circular_arc_properties_from_triangle(curve)

    t := (time_at - time_start) / (time_end - time_start)
    if reversed {
    t = 1 - t
    }
    theta := pr.theta_start + pr.direction * t * pr.theta_range
    return pr.center + {math.cos(f32(theta)), math.sin(f32(theta))} * pr.radius
}

calculate_straight_point_from_time :: proc(hobj: ^Hitobject, time_at: f64, path: ^Slider_Path) -> (point: vec2) {
    duration := hobj.end_time_ms - hobj.start_time_ms
    elapsed  := clamp(time_at - hobj.start_time_ms, 0, duration)

    // t_passes goes from 0 to slider_repeats over the full duration
    repeat_count := hobj.slider_state.path_travel_count
    t_passes  := (elapsed / duration) * f64(repeat_count)
    pass_idx  := min(int(t_passes), repeat_count - 1)
    pass_frac := t_passes - f64(pass_idx)

    // even passes go forward (0->1), odd passes go backward (1->0)
    t_on_path := pass_frac if pass_idx % 2 == 0 else 1.0 - pass_frac

    return linalg.lerp(path.pos, path.end_pos, vec2{f32(t_on_path), f32(t_on_path)})
}

calculate_distance_of_straight_bezier :: proc(
    hobj: ^Hitobject, path: ^Slider_Path, start_pos: vec2, end_pos: vec2
) -> f64 {
    //remaining_distance := curve_distance
    curr_distance : f64 = 0
    /*xy_vector : vec2 = end_pos - start_pos
    
    iterations := linalg.length(xy_vector) / f32(base_dist)
    xy_step := xy_vector / iterations
    last_point_added := start_pos

    for i in 1..<(iterations + 1) {
        if (curr_distance + base_dist) > curve_distance {
            remaining_distance = remaining_distance - f64(curr_distance)
            iterations_remaining := remaining_distance / base_dist
            last_point_added += xy_step * f32(iterations_remaining)

            break
        }

        curr_distance += base_dist
        last_point_added = start_pos + i * xy_step
    }
    
    pts := [?]vec2{start_pos, last_point_added}
    for point in pts {
        path.bounds_min.x, path.bounds_min.y = min(path.bounds_min.x, point.x), min(path.bounds_min.y, point.y)
        path.bounds_max.x, path.bounds_max.y = max(path.bounds_max.x, point.x), max(path.bounds_max.y, point.y)
    }

    travelled_distance := math.pow(math.pow(last_point_added.y - start_pos.y, 2) + math.pow(last_point_added.x - start_pos.x, 2), 0.5)
    remaining_distance = curve_distance - f64(travelled_distance)
    if remaining_distance < 0.01 {
        return curve_distance
    }
    return f64(travelled_distance)*/

    pts := [?]vec2{start_pos, end_pos}
    for point in pts {
        path.bounds_min.x, path.bounds_min.y = min(path.bounds_min.x, point.x), min(path.bounds_min.y, point.y)
        path.bounds_max.x, path.bounds_max.y = max(path.bounds_max.x, point.x), max(path.bounds_max.y, point.y)
    }

    travelled_distance := math.pow(math.pow(end_pos.y - start_pos.y, 2) + math.pow(end_pos.x - start_pos.x, 2), 0.5)
    return f64(travelled_distance)

}

write_instances_over_distance :: proc(instance_buf: ^Buffer(vec2), path: ^Slider_Path, curve_distance: f64) {
    last := instance_buf.count - 1
    l0 := instance_buf.data[last - 1]
    l1 := instance_buf.data[last]
    l_vector : vec2 = (l1 - l0)
    l_distance_mult := f32(curve_distance) / linalg.length(l_vector)

    write_instances_from_straight(instance_buf, path, l1, l1 + l_vector * l_distance_mult, curve_distance)
}

/*todo(yokes): make new proc which calculates instances with distance (or close to) base_dist between each
    many parameters with unknown origins, find out what they are and how to use them, evt. which parameters we already have which can replace them:
    - this_curve
    - curr_curve_points
    - m_curve_points
    - m_curve_point_segments | looks like a queue with vec2s
*/
/*
calculate_equal_points_between_instances :: proc(instance_buf: ^Buffer(vec2), path: ^Slider_Path, output: ^queue.Queue(vec2), curve_distance: f64) -> (total_distance: f64) {
    m_i_curve := min(i32(path.distance_osupx / f64(clamp(osu_slider_curve_points_separation, 1.0, 100.0))), path.instance_count)
    curr_curve_index := 0
    curr_point := 0

    distance_at := 0.0
    last_distance_at := 0.0

    curr_curve := path.curves[curr_curve_index]
    //todo(yokes): check if len(curr_curve) < 1


    last_curve := curr_curve[curr_point]

    last_curve_point_for_next_segment_start : vec2
    curr_curve_points : vec2

    for i in 0..<m_i_curve + 1 {
        pref_distance := i32(f64(i) * path.distance_osupx) / m_i_curve

        for distance_at < f64(pref_distance) {
            last_distance_at = distance_at
            if len(curr_curve) > 0 && curr_point > -1 && curr_point < len(curr_curve) {
                last_curve = curr_curve[curr_point]
            }
            curr_point += 1

            if curr_point >= len(curr_curve) {
                curr_curve_index += 1

                if len(curr_curve_points) > 0 {
                    //m_curve_point_segments.push_back(curr_curve_points)
                    //curr_curve_points.clear()

                    if len(m_curve_points) > 0 {
                        curr_curve_points.push_back(last_curve_point_for_next_segment_start)
                    }
                
                    if curr_curve_index < len(path.curves) {
                        curr_curve = path.curves[curr_curve_index]
                        curr_point = 0
                    } else {
                        curr_point = len(curr_curve) - 1
                        if last_distance_at == distance_at {
                            break
                        }
                    }
                }
                if len(curr_curve) - 1 > 0 && curr_point > -1 && curr_point < len(path.curves) - 1 {
                    //distance_at += distance of curr_curve (path.curves[curr_curve_index])
                    break
                }
            }

            this_curve : vec2 = len(curr_curve) > 0 && curr_point > -1 && curr_point < len(curr_curve) ? curr_curve[curr_point] : vec2({0, 0})

            m_curve_points.push_back(vec2({0, 0}))
            curr_curve_points.push_back(vec2({0, 0}))
            if distance_at - last_distance_at > 1 {
                t : f64 = (f64(pref_distance) - last_distance_at) / (distance_at - last_distance_at)
                m_curve_points[i] = vec2({math.lerp(last_curve.x, this_curve.x, t), math.lerp(last_curve.y, this_curve.y, t)})
            } else {
                m_curve_points[i] = this_curve
            }

            last_curve_point_for_next_segment_start = this_curve
            curr_curve_points[len(curr_curve_points) - 1] = this_curve
        }

        if len(curr_curve_points) > 0 {
            m_curve_point_segments.push_back(curr_curve_points)
        }

        if len(m_curve_points) == 0 {
            log.debug("calculate_equal_points_between_instances: len(m_curve_points) == 0")
        }

        segmented_length := 0.0
        for s in 0..<len(m_curve_point_segments) {
            for p in 0..<len(m_curve_point_segments[s]) {
                segmented_length += p == 0 ? 0 : linalg.length(m_curve_point_segments[s][p] - m_curve_point_segments[s][p-1])
            }
        }

        //todo(yokes): according to mcosu source code this is incorrect
        if segmented_length > path.distance_osupx && len(m_curve_point_segments) > 1 && len(m_curve_point_segments[0]) > 1 {
            excess : f64 = segmented_length - path.distance_osupx
            for excess > 0 {
                for s := (len(m_curve_point_segments)-1); s >= 0; s -= 1 {
                    for p := (len(m_curve_point_segments[s])-1); p >= 0; p -= 1 {
                        curr_length := p == 0 ? 0 : linalg.length(m_curve_point_segments[s][p] - m_curve_point_segments[s][p-1])
                        if curr_length >= excess && p != 0 {
                            segment_vector := linalg.normalize(m_curve_point_segments[s][p] - m_curve_point_segments[s][p-1])
                            m_curve_point_segments[s][p] -= segment_vector * excess
                            excess = 0.0
                            break
                        } else { // ???? what??
                            m_curve_point_segments[s].erase(m_curve_point_segments[s].begin() + p)
                            excess -= curr_length
                        }
                    }
                }
            }
        }
    }
}
*/
calculate_points_between_instances :: proc(instance_buf: ^Buffer(vec2), path: ^Slider_Path, output: ^queue.Queue(vec2), curve_distance: f64) -> (total_distance: f64) {
    for point, i in output.data[:output.len] {
        curr_distance : f64 = 0
        if i < int(output.len) - 1 {
            curr_distance = f64(linalg.vector_length(queue.get(output, i + 1) - queue.get(output, i)))

            if total_distance + curr_distance > curve_distance {
                remaining_distance := abs(curve_distance - total_distance)
                distance_between_last := linalg.vector_length(output.data[i+1] - point)
                vec2_between_last := output.data[i+1] - point

                buffer_push(instance_buf, point + vec2_between_last * f32(remaining_distance) / distance_between_last)
                total_distance += remaining_distance
                break
            }

            if curr_distance > base_dist {
                //todo(yokes): at the moment the end point overlaps an instance with the start point of the next output.data
                write_instances_from_straight(instance_buf, path, queue.get(output, i), queue.get(output, i + 1), curr_distance)
            } else if i != 0 {
                buffer_push(instance_buf, point)
            }

            total_distance += curr_distance
        }
        
        path.bounds_min.x, path.bounds_min.y = min(path.bounds_min.x, point.x), min(path.bounds_min.y, point.y)
        path.bounds_max.x, path.bounds_max.y = max(path.bounds_max.x, point.x), max(path.bounds_max.y, point.y)
    }
    return total_distance
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
circular_arc_to_piecewise_linear :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, curve: Slider_Curve, curve_distance: f64
) -> (total_distance: f64) {
    pr : Circular_Arc_Properties = circular_arc_properties_from_triangle(curve)
    if !pr.is_valid {
        instance_count, instances_at : i32
        instance_count, instances_at, total_distance = bezier_to_piecewise_linear(instance_buf, path, curve, curve_distance)
        return total_distance
    }

    amount_points := 2 * pr.radius <= circular_arc_tol ? 2 : max(2, int(math.ceil(f32(pr.theta_range) / (2 * math.acos_f32(1 - circular_arc_tol / pr.radius)))))

    output : queue.Queue(vec2)
    queue.init(&output, allocator = context.temp_allocator)

    for i in 0..<amount_points {
        fract := f64(i) / f64(amount_points - 1)
        theta := pr.theta_start + pr.direction * fract * pr.theta_range
        o : vec2 = {math.cos(f32(theta)), math.sin(f32(theta))} * pr.radius
        queue.push(&output, pr.center + o)
    }

    total_distance = calculate_points_between_instances(instance_buf, path, &output, curve_distance)
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

bezier_to_piecewise_linear :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, curve: Slider_Curve, curve_distance: f64
) -> (instance_count, instances_at: i32, total_distance: f64) {
    return b_spline_to_piecewise_linear(instance_buf, path, curve, max(1, len(curve) - 1), curve_distance)
}

b_spline_to_piecewise_linear :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, curve: Slider_Curve, degree: int, curve_distance: f64
) -> (instance_count, instances_at: i32, total_distance: f64) {
    assert(degree >= 1, "curve degree error: lower than 1")

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L86
    if len(curve) < 2 {
        return 0, instance_buf.count, 0
    }

    new_curve := slice.clone(curve, context.temp_allocator)

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L91
    point_count : int = len(curve) - 1
    degree := min(degree, point_count)

    output : queue.Queue(vec2)
    queue.init(&output, allocator = context.temp_allocator)
    
    to_flatten : queue.Queue([]vec2) //todo(yokes): should contain all curves which are not approximated well enough yet
    temp_points: queue.Queue(vec2)
    queue.init(&temp_points, allocator = context.temp_allocator)
    queue.init(&to_flatten, allocator = context.temp_allocator) //todo(yokes): check capacity, default for now
    queue.append_elems(&to_flatten, b_spline_to_bezier_internal(&temp_points, new_curve, degree))
    free_buffers : queue.Queue([]vec2)
    queue.init(&free_buffers, allocator = context.temp_allocator) //todo(yokes): check capacity, default for now

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L102

    subdivision_buffer_1 := make([]vec2, degree + 1, allocator = context.temp_allocator)
    subdivision_buffer_2 := make([]vec2, degree * 2 + 1, allocator = context.temp_allocator)

    left_child : []vec2 = subdivision_buffer_2

    for to_flatten.len > 0 {
        parent : []vec2 = queue.pop_back(&to_flatten)
        
        // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L119
        if bezier_is_flat_enough(parent) {
            bezier_approximate(parent, &output, subdivision_buffer_1, subdivision_buffer_2, degree + 1)

            queue.push(&free_buffers, parent)
            continue
        }

        // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L129
        right_child : []vec2 = free_buffers.len > 0 ? queue.pop_back(&free_buffers) : make([]vec2, degree + 1, context.temp_allocator)
        bezier_subdivide(parent, left_child, right_child, subdivision_buffer_1, degree + 1)

        for i in 0..<degree + 1 {
            parent[i] = left_child[i]
        }

        queue.push(&to_flatten, right_child)
        queue.push(&to_flatten, parent)
    }

    //main goal is to edit the curve such that the instances pushed are the new coordinates where the slider is drawn
    instances_at = instance_buf.count
    if output.data[output.len-1] != curve[len(curve)-1] {
        instances_at += 1
        queue.push(&output, curve[len(curve)-1])
    }
    total_distance = calculate_points_between_instances(instance_buf, path, &output, curve_distance)
    
    
    return i32(output.len), instances_at, total_distance
}

bezier_tolerance : f32 = 0.25
bezier_is_flat_enough :: proc(curve: Slider_Curve) -> bool {
    for i in 1..<len(curve) - 1 {
        test := linalg.vector_length2((curve[i - 1] - 2 * curve[i] + curve[i + 1]))
        if linalg.vector_length2((curve[i - 1] - 2 * curve[i] + curve[i + 1])) > bezier_tolerance * bezier_tolerance * 4 {
            return false
        }
    }
    return true
}

//todo(yokes): this can be optimized by buffer_pushing instances instead of storing coordinates to an output
bezier_approximate :: proc(curve: Slider_Curve, output: ^queue.Queue(vec2), subdivision_buffer_1: []vec2, subdivision_buffer_2: []vec2, count: int) {
    l := subdivision_buffer_2
    r := subdivision_buffer_1

    bezier_subdivide(curve, l, r, subdivision_buffer_1, count)

    for i in 0..<count - 1 {
        l[count + i] = r[i + 1]
    }

    queue.push_back(output, curve[0])
    
    for i in 1..<count - 1 {
        index := 2 * i
        p := 0.25 * (l[index - 1] + 2 * l[index] + l[index + 1])
        queue.push_back(output, p)
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

b_spline_to_bezier_internal :: proc(result: ^queue.Queue(vec2), curve: Slider_Curve, degree: int) -> []vec2 {
    point_count := len(curve) - 1
    local_degree := min(degree, point_count)

    if degree == point_count {
        queue.push_back_elems(result, ..curve[:]) // Uses push_back to avoid reversing the stack later
        return curve[:]
        //return result.data[:]
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
            queue.push_back_elems(result, ..sub_bezier[:])
        }
        slice_from := result.len
        queue.push_back_elems(result, ..curve[(point_count - degree):])
        return curve[(point_count - degree):]
        //return result.data[slice_from:]
    }
}

write_instances_from_straight :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, start_pos: vec2, end_pos: vec2, curve_distance: f64
) -> f64 {
    remaining_distance := curve_distance
    curr_distance : f64 = 0
    xy_vector : vec2 = end_pos - start_pos
    
    iterations := linalg.length(xy_vector) / f32(base_dist)
    xy_step := xy_vector / iterations
    last_point_added := start_pos

    for i in 1..<(iterations+1) {
        if (curr_distance + base_dist) >= curve_distance {
            remaining_distance = remaining_distance - f64(curr_distance)
            iterations_remaining := remaining_distance / base_dist
            buffer_push(instance_buf, last_point_added + xy_step * f32(iterations_remaining))
            break
        }

        curr_distance += base_dist
        last_point_added = start_pos + i * xy_step
        buffer_push(instance_buf, last_point_added)
    }

    pts := [?]vec2{start_pos, last_point_added}
    /*if curr_distance < curve_distance {
        buffer_push(instance_buf, end_pos)
        curr_distance += f64(linalg.length(end_pos - last_point_added))

        pts = [?]vec2{start_pos, end_pos}
    }*/
    
    for point in pts {
        path.bounds_min.x, path.bounds_min.y = min(path.bounds_min.x, point.x), min(path.bounds_min.y, point.y)
        path.bounds_max.x, path.bounds_max.y = max(path.bounds_max.x, point.x), max(path.bounds_max.y, point.y)
    }

    travelled_distance := linalg.length(end_pos - start_pos)
    remaining_distance = curve_distance - f64(travelled_distance)
    if remaining_distance < 0.01 {
        return curve_distance
    }
    return f64(travelled_distance)
}

write_instances_from_curve :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64
) -> (travelled_distance: f64) {
    
    if len(curve) > 1 {
        // todo(yokes): if the slider is linear each node counts as "red"
        if type == .LINEAR || len(curve) < 3 {
            travelled_distance = write_instances_from_straight(instance_buf, path, curve[0], curve[1], curve_distance)
        } else if type == .ARC {
            //todo(yokes): copy the tolerance from lazer code to check if a slider is parallel
            is_parallel: bool
    
            if is_parallel {
                travelled_distance = write_instances_from_straight(instance_buf, path, curve[0], curve[2], curve_distance)
            } else {
                travelled_distance = circular_arc_to_piecewise_linear(instance_buf, path, curve, curve_distance)
            }
        } else if type == .BEZIER {
            //instance_count, instances_at
            _, _, travelled_distance = b_spline_to_piecewise_linear(instance_buf, path, curve, max(1, len(curve)), curve_distance)
        } 
    }
    return travelled_distance
}

/*
    note(isak): calculates and writes slider instances, or positions used for rendering to the screen, based on a 
    given path. it should write instances into the bounds of [0, playfield_size]
*/
write_instances_from_path :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, alloc: runtime.Allocator = context.allocator
) -> (instance_count: i32, instance_offset: i32) {
    instance_offset = instance_buf.count

    path.curves = split_path_into_curves(path, alloc)

    buffer_push(instance_buf, path.nodes[0])
    distance_to_cover := path.distance_osupx
    for curve, i in path.curves {
        
        if distance_to_cover > 0 {
            distance_covered_by_curve := 
                write_instances_from_curve(instance_buf,
                                           path,
                                           curve, 
                                           path.type,
                                           distance_to_cover)
            distance_to_cover -= distance_covered_by_curve
        }
    }

    if distance_to_cover > 0 {
        write_instances_over_distance(instance_buf, path, distance_to_cover)
    }
    
    path.pos, path.end_pos = instance_buf.data[instance_offset], instance_buf.data[max(instance_buf.count-1, 0)]
    
    instance_count = instance_buf.count - instance_offset
    if instance_count >= 2 {
        p0 := instance_buf.data[instance_offset]
        p1 := instance_buf.data[instance_offset + 1]
        path.head_angle_rad = math.atan2(p1.y - p0.y, p1.x - p0.x)

        last := instance_buf.count - 1
        
        l0 := instance_buf.data[last]
        l1 := instance_buf.data[last - 1]
        path.end_angle_rad = math.atan2(l1.y - l0.y, l1.x - l0.x)
    }
    
    return instance_count, instance_offset
}
