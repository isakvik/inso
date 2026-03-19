package notosu

import "base:runtime"
import "core:container/queue"
import "core:math"
import "core:math/linalg"

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

// https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L878
// note(yokes): "t" is for time which means we need to calculate the time it takes to get "d" distance beforehand
calculate_bezier_point_from_time :: proc(instance_buf: ^Buffer(vec2), time_at: f64, time_start: f64, time_end: f64, curve: Slider_Curve, base_slider_velocity: f64, slider_velocity: f64) -> (point: vec2) {
    //note(yokes): draw sliderball, move sliderball accordingly?
    //note(yokes): quick test on stable, 1x sv 5/4 slider has 500 distance. i believe i understand how the math works now
    //note(yokes): if a green line is in the middle of a slider, should it change the slider speed mid-slider? stable nor lazer does this but i believe this would leave more room... nvm not possible atm

    slider_speed := base_slider_velocity * slider_velocity //base_sv is 1 when making a new map
    distance_per_beat := 100 * slider_speed //base speed is 100 per 1/4
    degree := max(1, len(curve) - 1)
    t := (time_at - time_start) / time_end
    for i in 0..<degree + 1 {
        binom_coeff := f64(math.binomial(degree, i)) * math.pow_f64(1 - t, f64(degree - i)) * math.pow_f64(t, f64(i))
        point.x += f32(binom_coeff) * (curve[i].x)
        point.y += f32(binom_coeff) * (curve[i].y)
    }
    buffer_push(instance_buf, point)
    return point
}

base_dist : f64 = 2.5

//todo(yokes): make a procedure for calculating points on bezier and arch sliders when the curve is too slight
//check todos under circular_arc_to_piecewise_linear and bezier_to_piecewise_linear
calculate_points_between_instances :: proc(instance_buf: ^Buffer(vec2), path: ^Slider_Path, output: ^queue.Queue(vec2), curve_distance: f64) -> (total_distance: f64) {
    for point, i in output.data[:output.len] {
        if i < int(output.len) - 1 {
            curr_distance := f64(linalg.vector_length(queue.get(output, i + 1) - queue.get(output, i)))
            total_distance += curr_distance

            if curr_distance > base_dist {
                //todo(yokes): at the moment the end point overlaps an instance with the start point of the next output.data
                write_instances_from_straight(instance_buf, path, queue.get(output, i), queue.get(output, i + 1), curr_distance)
            } else {
                buffer_push(instance_buf, point)
            }

        } else {
            buffer_push(instance_buf, point)
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

    // https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L91
    point_count : int = len(curve) - 1
    degree := min(degree, point_count)

    output : queue.Queue(vec2)
    queue.init(&output, allocator = context.temp_allocator)
    
    to_flatten : queue.Queue([]vec2) //todo(yokes): should contain all curves which are not approximated well enough yet
    temp_points: queue.Queue(vec2)
    queue.init(&temp_points, allocator = context.temp_allocator)
    queue.init(&to_flatten, allocator = context.temp_allocator) //todo(yokes): check capacity, default for now
    queue.append_elems(&to_flatten, b_spline_to_bezier_internal(&temp_points, curve, degree))
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
    total_distance = calculate_points_between_instances(instance_buf, path, &output, curve_distance)
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
        queue.push_back_elems(result, ..curve[(point_count - degree):])
        return curve[(point_count - degree):]
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

    for i in 0..<iterations {
        curr_distance += base_dist
        last_point_added = start_pos + i * xy_step
        buffer_push(instance_buf, last_point_added)
        
        if (curr_distance + base_dist) > remaining_distance {
            remaining_distance = remaining_distance - f64(curr_distance)
            iterations_remaining := remaining_distance / base_dist
            buffer_push(instance_buf, last_point_added + xy_step * f32(iterations_remaining))
            break
        }
    }
    
    pts := [?]vec2{start_pos, last_point_added}
    for point in pts {
        path.bounds_min.x, path.bounds_min.y = min(path.bounds_min.x, point.x), min(path.bounds_min.y, point.y)
        path.bounds_max.x, path.bounds_max.y = max(path.bounds_max.x, point.x), max(path.bounds_max.y, point.y)
    }

    travelled_distance := math.pow(math.pow(end_pos.y - start_pos.y, 2) + math.pow(end_pos.x - start_pos.x, 2), 0.5)
    remaining_distance = curve_distance - f64(travelled_distance)
    if remaining_distance < 0.01 {
        return 0
    }
    return f64(travelled_distance)
}

write_instances_from_curve :: proc(
    instance_buf: ^Buffer(vec2), path: ^Slider_Path, curve: Slider_Curve, type: Slider_Path_Type, curve_distance: f64
) -> (travelled_distance: f64) {
    
    if len(curve) > 1 {
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
    
    path.pos, path.end_pos = instance_buf.data[instance_offset], instance_buf.data[max(instance_buf.count-1, 0)]

    // todo(yokes): if we still have distance left over but zero curves, a linear path needs to cover
    // the remaining distance. maybe mcosu has something neat for this?
    if distance_to_cover > 0 {

    }
    
    instance_count = instance_buf.count - instance_offset
    return instance_count, instance_offset
}
