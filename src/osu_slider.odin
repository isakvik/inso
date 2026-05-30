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

    if path.type == .BEZIER {
        // todo(yokes): make new logic for calculating slider ball pos on bezier (should only need to get "t" correctly)
        pos_at = calculate_bezier_point_from_time(hobj, time_at, path)
    } else if path.type == .ARC {
        pos_at = calculate_bezier_point_from_time(hobj, time_at, path)
    } else if path.type == .LINEAR {
        pos_at = calculate_straight_point_from_time(hobj, time_at, path)
    }
    return pos_at + hobj.script_pos_translation
}

// flattens a b-spline curve of the given degree into piecewise-linear points, appending them to output.
// the final curve endpoint is intentionally not appended; callers handle that themselves.
// https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L86
flatten_bspline_into :: proc(output: ^queue.Queue(vec2), curve: Slider_Curve, degree: int) {
    new_curve := slice.clone(curve, context.temp_allocator)

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
            bezier_approximate(parent, output, subdivision_buffer_1, subdivision_buffer_2, degree + 1)

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
}

// todo(yokes): red nodes get repeated
calculate_bezier_curve_distance :: proc(output: ^queue.Queue(vec2), curve: Slider_Curve) -> (distance: f64) {

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L86
    if len(curve) < 2 {
        return 0
    }

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L91
    point_count : int = len(curve) - 1
    degree := min(max(1, len(curve) - 1), point_count)

    // measure only the segment this curve appends (incl. the connector to the previous curve's last point)
    // so multi-curve paths don't re-sum points from earlier curves
    distance_from := max(int(output.len) - 1, 0)
    flatten_bspline_into(output, curve, degree)
    queue.push(output, curve[len(curve)-1])

    distance = calculate_approx_distance_from_piecewise(output, distance_from)
    return distance
}

calculate_approx_distance_from_piecewise :: proc(output: ^queue.Queue(vec2), from := 0) -> (total_distance: f64) {
    for i in from..<int(output.len) - 1 {
        total_distance += f64(linalg.vector_length(queue.get(output, i + 1) - queue.get(output, i)))
    }
    return total_distance
}

calculate_approx_distance_from_curve :: proc(p0: vec2, p1: vec2) -> (total_distance: f64) {
    curr_distance := f64(linalg.vector_length(p1 - p0))
    total_distance += curr_distance

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
    
    //curve_m_i := min(i64(path.distance_osupx / clamp(base_dist, 1.0, 100.0)), i64(slider_max_points), i64(len(path_instances) - 1))
    curve_m_i := min(i64(slider_max_points), i64(len(path_instances) - 1))

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

// extends the slider end by `curve_distance` more osu!px, in a straight line along the end tangent.
// `from` is this slider's first instance index, so the scan never reads a previous slider's geometry.
write_instances_over_distance :: proc(instance_buf: ^Buffer(vec2), curve_distance: f64, from: i32) {
    if instance_buf.count - from < 2 do return

    end_pos := instance_buf.data[instance_buf.count - 1]

    // the resampler pads the tail with copies of the end point when the curve is shorter than the
    // slider length, so scan back for the last distinct point to recover the true end tangent
    end_dir : vec2
    found_dir := false
    for i := instance_buf.count - 2; i >= from; i -= 1 {
        prev := instance_buf.data[i]
        if prev != end_pos {
            end_dir = end_pos - prev
            found_dir = true
            break
        }
    }
    if !found_dir do return

    end_dir_unit := end_dir / linalg.length(end_dir)
    write_instances_from_straight(instance_buf, end_pos, end_pos + end_dir_unit * f32(curve_distance), curve_distance)
}

// resamples the accumulated piecewise curve in `output` into points spaced an equal distance apart,
// pushing them straight into instance_buf. `output` is read-only here.
write_equal_spacing_points_from_curves :: proc(instance_buf: ^Buffer(vec2), path: ^Slider_Path, output: ^queue.Queue(vec2)) {
    m_i_curve := min(i32(path.distance_osupx / f64(clamp(base_dist, 1.0, 100.0))), i32(slider_max_points))
    curr_point := 0

    distance_at := 0.0
    last_distance_at := 0.0

    curr_curve := output.data
    curr_curve_len := int(output.len)
    if curr_curve_len < 1 {
        log.info("calculate_equal_points_from_curves: curr_curve_len == 0")
        return
    }

    last_curve := curr_curve[curr_point]

    // once the flattened curve is consumed, switch to extrapolating evenly-spaced points along the end
    // tangent. the true curve end informs the tangent but is never pushed as a point, since its uneven
    // distance to the previous point would briefly slow the sliderball down there.
    extrapolating := false
    curve_end     : vec2
    curve_length  : f64
    end_tangent   : vec2

    for i in 0..<m_i_curve + 1 {
        // note(yokes): why is this i32? seems to work though
        pref_distance := i32(f64(i) * path.distance_osupx) / m_i_curve

        if !extrapolating {
            // walk forward until the accumulated distance reaches the target. do NOT stop after a single
            // segment: flattened segments are often shorter than the resample step, so stopping early lets
            // distance_at lag behind pref_distance and the lerp below extrapolates past the segment (t > 1),
            // which makes multi-curve sliders visibly jump at sharp curvature changes.
            for distance_at < f64(pref_distance) {
                last_distance_at = distance_at
                if curr_curve_len > 0 && curr_point > -1 && curr_point < curr_curve_len {
                    last_curve = curr_curve[curr_point]
                }
                curr_point += 1

                if curr_point >= curr_curve_len {
                    // the curve is shorter than the slider length. record its end and end tangent, then
                    // extrapolate the remaining points in a straight line for the rest of the loop.
                    curr_point = curr_curve_len - 1
                    curve_end = curr_curve[curr_curve_len - 1]
                    curve_length = distance_at
                    for j := curr_curve_len - 2; j >= 0; j -= 1 {
                        if curr_curve[j] != curve_end {
                            end_tangent = linalg.normalize(curve_end - curr_curve[j])
                            break
                        }
                    }
                    extrapolating = true
                    break
                }

                if curr_curve_len > 0 && curr_point > 0 && curr_point < curr_curve_len {
                    distance_at += calculate_approx_distance_from_curve(curr_curve[curr_point - 1], curr_curve[curr_point])
                }
            }
        }

        point : vec2
        if extrapolating {
            // evenly-spaced point past the curve end, so the join keeps the resample spacing intact
            point = curve_end + end_tangent * f32(f64(pref_distance) - curve_length)
        } else {
            this_point : vec2 = curr_curve_len > 0 && curr_point > -1 && curr_point < curr_curve_len ? curr_curve[curr_point] : vec2({0, 0})
            if distance_at - last_distance_at > 1 {
                t : f64 = (f64(pref_distance) - last_distance_at) / (distance_at - last_distance_at)
                point = vec2({math.lerp(last_curve.x, this_point.x, f32(t)), math.lerp(last_curve.y, this_point.y, f32(t))})
            } else {
                point = this_point
            }
        }
        buffer_push(instance_buf, point)
    }
}

calculate_points_between_instances :: proc(instance_buf: ^Buffer(vec2), output: ^queue.Queue(vec2), curve_distance: f64) -> (total_distance: f64) {
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
                write_instances_from_straight(instance_buf, queue.get(output, i), queue.get(output, i + 1), curr_distance)
            } else if i != 0 {
                buffer_push(instance_buf, point)
            }

            total_distance += curr_distance
        }
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
    instance_buf: ^Buffer(vec2), curve: Slider_Curve, curve_distance: f64
) -> (total_distance: f64) {
    pr : Circular_Arc_Properties = circular_arc_properties_from_triangle(curve)
    if !pr.is_valid {
        total_distance = bezier_to_piecewise_linear(instance_buf, curve, curve_distance)
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

bezier_to_piecewise_linear :: proc(
    instance_buf: ^Buffer(vec2), curve: Slider_Curve, curve_distance: f64
) -> (total_distance: f64) {
    return b_spline_to_piecewise_linear(instance_buf, curve, max(1, len(curve) - 1), curve_distance)
}

b_spline_to_piecewise_linear :: proc(
    instance_buf: ^Buffer(vec2), curve: Slider_Curve, degree: int, curve_distance: f64
) -> (total_distance: f64) {
    assert(degree >= 1, "curve degree error: lower than 1")

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L86
    if len(curve) < 2 {
        return 0
    }

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L91
    point_count : int = len(curve) - 1
    degree := min(degree, point_count)

    output : queue.Queue(vec2)
    queue.init(&output, allocator = context.temp_allocator)

    flatten_bspline_into(&output, curve, degree)

    // append the true curve endpoint if the flattening didn't already land on it
    if output.data[output.len-1] != curve[len(curve)-1] {
        queue.push(&output, curve[len(curve)-1])
    }
    total_distance = calculate_points_between_instances(instance_buf, &output, curve_distance)

    return total_distance
}

bezier_tolerance : f32 = 0.25
bezier_is_flat_enough :: proc(curve: Slider_Curve) -> bool {
    for i in 1..<len(curve) - 1 {
        deviation := linalg.vector_length2((curve[i - 1] - 2 * curve[i] + curve[i + 1]))
        if deviation > bezier_tolerance * bezier_tolerance * 4 {
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
    instance_buf: ^Buffer(vec2), start_pos: vec2, end_pos: vec2, curve_distance: f64
) {
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
}

/* todo(yokes): redo entire thing? mcosu does it differently
    - calculate where instances should go, but do not push them
    - entire slider is filled before calculate_equal_points_between_instances is called
*/
write_piecewise_linear_from_curve :: proc(
    instance_buf: ^Buffer(vec2), output: ^queue.Queue(vec2), curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64
) -> (travelled_distance: f64) {

    if len(curve) > 1 {
        // todo(yokes): if the slider is linear each node counts as "red"
        if type == .LINEAR || len(curve) < 3 {
            travelled_distance = calculate_bezier_curve_distance(output, curve)
        } else if type == .ARC {
            //note(yokes): circular_arc_to_piecewise_linear checks if the slider is too straight and draws accordingly
            travelled_distance = circular_arc_to_piecewise_linear(instance_buf, curve, curve_distance)
        } else if type == .BEZIER {
            travelled_distance = calculate_bezier_curve_distance(output, curve)
        }
    }
    return travelled_distance
}

/*
    note(isak): calculates and writes slider instances, or positions used for rendering to the screen, based on a 
    given path. unless sliders exit the playfield, it writes instances into the bounds of <0, playfield_size>
*/
write_instances_from_path :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, alloc: runtime.Allocator = context.allocator
) -> (instance_count: i32, instance_offset: i32) {
    instance_offset = instance_buf.count

    path.curves = split_path_into_curves(path, alloc)
    approx_distance_covered_by_curve : f64 = 0

    output : queue.Queue(vec2)
    buffer_push(instance_buf, path.nodes[0])
    distance_to_cover := path.distance_osupx
    for curve, i in path.curves {
        if distance_to_cover > 0 {
            approx_distance_covered_by_curve +=
                write_piecewise_linear_from_curve(instance_buf,
                                                  &output,
                                                  curve,
                                                  path.type,
                                                  distance_to_cover)
            if approx_distance_covered_by_curve > distance_to_cover {
                break
            }
        }
    }

    write_equal_spacing_points_from_curves(instance_buf, path, &output)

    // the bezier/linear path extrapolates its own leftover inside calculate_equal_points_from_curves, so the
    // instances already span the full length. only the arc path (which leaves `output` empty and writes
    // instance_buf directly) still needs a straight extension appended here. must run after the body is in
    // the buffer so the tangent is read from this slider's actual end, not whatever instance preceded it.
    if output.len == 0 && distance_to_cover > approx_distance_covered_by_curve {
        write_instances_over_distance(instance_buf, distance_to_cover - approx_distance_covered_by_curve, instance_offset)
    }

    // note(isak): compute the bounding box from the finished curve
    path.bounds_min = {math.F32_MAX, math.F32_MAX}
    path.bounds_max = {math.F32_MIN, math.F32_MIN}
    for i in instance_offset..<instance_buf.count {
        p := instance_buf.data[i]
        path.bounds_min = {min(path.bounds_min.x, p.x), min(path.bounds_min.y, p.y)}
        path.bounds_max = {max(path.bounds_max.x, p.x), max(path.bounds_max.y, p.y)}
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
