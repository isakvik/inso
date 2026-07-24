package inso

import "core:math"
import "core:math/linalg"
import "core:slice"

// spacing between emitted slider instances
SLIDER_POINT_DIST_OSUPX: f64 : 2.5
// how far a flattened bezier may deviate from the true curve before it's subdivided further in osupx
SLIDER_BEZIER_TOLERANCE : f32 : 0.25
// how finely circular arcs are tessellated in osupx
SLIDER_CIRCULAR_ARC_TOLERANCE : f32 : 0.1

/*
    note(isak): builds the equidistant slider instances for `path` and appends them to `instance_buf`.
    the sliderball and the body renderer both read these instances back by index (see 
    calculate_bezier_point_from_time), so they must be evenly spaced for the slider velocity to be constant.

    two passes:
      1. flatten every curve into one piecewise-linear approximation.
      2. march that approximation by arc length, emitting a point every base_dist up to the slider's pixel
         length, extrapolating straight along the end tangent if the slider outruns its control geometry.
*/
write_instances_from_path :: proc(instance_buf: ^Buffer(vec2), path: ^Slider_Path) -> (instance_count: i32, instance_offset: i32) {
    instance_offset = instance_buf.count

    raw := make([dynamic]vec2, context.temp_allocator)
    flatten_path_into(&raw, path)

    // degenerate paths (single-node "invisible" sliders, unsupported curve types) flatten to
    // nothing; anchor them at the head so pos/end_pos and the gfx reading them don't sit at (0,0)
    if len(raw) == 0 && len(path.nodes) > 0 {
        append(&raw, path.nodes[0])
    }

    write_equidistant_resampling(instance_buf, raw[:], path.distance_osupx)

    instance_count = instance_buf.count - instance_offset

    // note(isak): cache the bounding box, endpoints and endpoint tangents calculated from the emitted instances
    path.bounds_min = { max(f32), max(f32) }
    path.bounds_max = { min(f32), min(f32) }
    for i in instance_offset ..< instance_buf.count {
        p := instance_buf.data[i]
        path.bounds_min = { min(path.bounds_min.x, p.x), min(path.bounds_min.y, p.y) }
        path.bounds_max = { max(path.bounds_max.x, p.x), max(path.bounds_max.y, p.y) }
    }

    if instance_count >= 1 {
        path.pos     = instance_buf.data[instance_offset]
        path.end_pos = instance_buf.data[instance_buf.count - 1]
    }
    if instance_count >= 2 {
        head0 := instance_buf.data[instance_offset]
        head1 := instance_buf.data[instance_offset + 1]
        path.head_angle_rad = math.atan2(head1.y - head0.y, head1.x - head0.x)

        tail0 := instance_buf.data[instance_buf.count - 1]
        tail1 := instance_buf.data[instance_buf.count - 2]
        path.end_angle_rad = math.atan2(tail1.y - tail0.y, tail1.x - tail0.x)
    }

    return instance_count, instance_offset
}

//////////////////////////////////////////////////////
// pass 1: flattening every segment into one polyline

flatten_path_into :: proc(out: ^[dynamic]vec2, path: ^Slider_Path) {
    nodes := path.nodes
    // segments are split at repeated (red-anchor) nodes; the anchor is shared by both neighbours.
    seg_start := 0
    for i in 1 ..< len(nodes) - 1 {
        if nodes[i] == nodes[i - 1] {
            flatten_segment_into(out, nodes[seg_start:i], path.type)
            seg_start = i
        }
    }
    if len(nodes) >= 2 {
        flatten_segment_into(out, nodes[seg_start:], path.type)
    }
}

flatten_segment_into :: proc(out: ^[dynamic]vec2, seg: []vec2, type: Slider_Path_Type) {
    if len(seg) < 3 {
        flatten_bezier_into(out, seg) // a straight line (degree 1); the flattener no-ops on len < 2
        return
    }
    #partial switch type {
    case .ARC:             flatten_arc_into(out, seg)
    case .LINEAR, .BEZIER: flatten_bezier_into(out, seg)
    // CATMULL / NONE: unsupported, emit nothing
    }
}

// adaptive recursive subdivision of a single bezier (degree = len(control) - 1) into piecewise-linear
// points appended to `out`, ending exactly on the control endpoint.
// https://github.com/ppy/osu-framework/blob/master/osu.Framework/Utils/PathApproximator.cs#L86
flatten_bezier_into :: proc(out: ^[dynamic]vec2, control: []vec2) {
    if len(control) < 2 do return
    count := len(control)

    midpoints := make([]vec2, count, context.temp_allocator)
    flat_out  := make([]vec2, count * 2 - 1, context.temp_allocator)

    to_flatten := make([dynamic][]vec2, context.temp_allocator)
    free_pool  := make([dynamic][]vec2, context.temp_allocator)
    append(&to_flatten, slice.clone(control, context.temp_allocator))

    for len(to_flatten) > 0 {
        parent := pop(&to_flatten)

        if bezier_is_flat_enough(parent) {
            bezier_approximate(parent, out, midpoints, flat_out, count)
            append(&free_pool, parent)
            continue
        }

        right := len(free_pool) > 0 ? pop(&free_pool) : make([]vec2, count, context.temp_allocator)
        bezier_subdivide(parent, flat_out, right, midpoints, count)
        for i in 0 ..< count {
            parent[i] = flat_out[i]
        }
        append(&to_flatten, right)
        append(&to_flatten, parent)
    }

    append(out, control[count - 1])
}

// circular arc through 3 points, tessellated by angular tolerance.
// https://github.com/ppy/osu-framework/blob/ca40f0a4d314b2acbad09f63e63824ae2670aa29/osu.Framework/Utils/PathApproximator.cs#L175
flatten_arc_into :: proc(out: ^[dynamic]vec2, control: []vec2) {
    pr := circular_arc_properties_from_triangle(control)
    if !pr.is_valid {
        // collinear / degenerate: fall back to a straight bezier
        flatten_bezier_into(out, control)
        return
    }

    point_count := 2
    if 2 * pr.radius > SLIDER_CIRCULAR_ARC_TOLERANCE {
        point_count = max(2, int(math.ceil(f32(pr.theta_range) / (2 * math.acos_f32(1 - SLIDER_CIRCULAR_ARC_TOLERANCE / pr.radius)))))
    }

    for i in 0 ..< point_count {
        fract := f64(i) / f64(point_count - 1)
        theta := pr.theta_start + pr.direction * fract * pr.theta_range
        append(out, pr.center + vec2{math.cos(f32(theta)), math.sin(f32(theta))} * pr.radius)
    }
}

//////////////////////////////////////////////////////
// pass 2: equidistant resampling

// marches the piecewise-linear polyline by arc length, emitting a point every base_dist into
// instance_buf up to target_distance. when target_distance overruns the polyline, the remainder is
// extended straight along the end tangent. the true polyline end informs that tangent but is never
// emitted itself: its uneven distance to the previous point would briefly slow the sliderball there.
write_equidistant_resampling :: proc(instance_buf: ^Buffer(vec2), raw: []vec2, target_distance: f64) {
    if len(raw) == 0 do return

    step    := f64(clamp(SLIDER_POINT_DIST_OSUPX, 1.0, 100.0))
    samples := max(i32(target_distance / step), 1)

    seg       := 0   // index of the polyline vertex we've consumed up to
    dist_at   := 0.0 // arc length at raw[seg]
    prev_dist := 0.0 // arc length at raw[seg - 1] (start of the segment straddling the target)

    extrapolating := false
    end_point   : vec2
    end_dist    : f64
    end_tangent : vec2

    for i in 0 ..= samples {
        target := f64(i) / f64(samples) * target_distance

        if !extrapolating {
            // advance as many segments as needed; flattened segments are often shorter than one step,
            // so stopping after one would let the lerp below extrapolate past its segment and kink.
            for dist_at < target {
                prev_dist = dist_at
                seg += 1
                if seg >= len(raw) {
                    seg = len(raw) - 1
                    end_point   = raw[seg]
                    end_dist    = dist_at
                    end_tangent = polyline_end_tangent(raw)
                    extrapolating = true
                    break
                }
                dist_at += f64(linalg.length(raw[seg] - raw[seg - 1]))
            }
        }

        if extrapolating {
            buffer_push(instance_buf, end_point + end_tangent * f32(target - end_dist))
        } else {
            a := raw[max(seg - 1, 0)]
            b := raw[seg]
            span := dist_at - prev_dist
            t := span > 0 ? f32((target - prev_dist) / span) : 0
            buffer_push(instance_buf, a + (b - a) * t)
        }
    }
}

// direction of the polyline's final segment, skipping any duplicated tail vertices.
polyline_end_tangent :: proc(raw: []vec2) -> vec2 {
    last := raw[len(raw) - 1]
    for i := len(raw) - 2; i >= 0; i -= 1 {
        if raw[i] != last {
            return linalg.normalize(last - raw[i])
        }
    }
    return {0, 0}
}


//////////////////////////////////////////////////////
// bezier subdivision primitives (ported from osu!framework PathApproximator)

bezier_is_flat_enough :: proc(curve: []vec2) -> bool {
    for i in 1 ..< len(curve) - 1 {
        deviation := linalg.vector_length2(curve[i - 1] - 2 * curve[i] + curve[i + 1])
        if deviation > SLIDER_BEZIER_TOLERANCE * SLIDER_BEZIER_TOLERANCE * 4 {
            return false
        }
    }
    return true
}

bezier_approximate :: proc(curve: []vec2, out: ^[dynamic]vec2, midpoints: []vec2, flat_out: []vec2, count: int) {
    l := flat_out
    r := midpoints

    bezier_subdivide(curve, l, r, midpoints, count)

    for i in 0 ..< count - 1 {
        l[count + i] = r[i + 1]
    }

    append(out, curve[0])
    for i in 1 ..< count - 1 {
        index := 2 * i
        append(out, 0.25 * (l[index - 1] + 2 * l[index] + l[index + 1]))
    }
}

bezier_subdivide :: proc(curve: []vec2, l: []vec2, r: []vec2, scratch: []vec2, count: int) {
    midpoints := scratch
    for i in 0 ..< count {
        midpoints[i] = curve[i]
    }
    for i in 0 ..< count {
        l[i] = midpoints[0]
        r[count - i - 1] = midpoints[count - i - 1]
        for j in 0 ..< count - i - 1 {
            midpoints[j] = (midpoints[j] + midpoints[j + 1]) / 2
        }
    }
}


//////////////////////////////////////////////////////
// circular arc geometry

Circular_Arc_Properties :: struct {
    is_valid: bool,
    theta_start, theta_range, theta_end: f64,
    direction: f64,
    radius: f32,
    center: vec2,
}

circular_arc_properties_from_triangle :: proc(curve: []vec2) -> (result: Circular_Arc_Properties) {
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


//////////////////////////////////////////////////////
// sliderball position lookup. takes slider repeats into account

path_calculate_position_at :: proc(hobj: ^Hitobject, time_at: f64, path: ^Slider_Path) -> (pos_at: vec2) {
    if hobj.type != .SLIDER {
        return hobj.pos
    }

    if path.type == .BEZIER {
        pos_at = curve_calculate_position_at(hobj, time_at, path)
    } else if path.type == .ARC {
        pos_at = curve_calculate_position_at(hobj, time_at, path)
    } else if path.type == .LINEAR {
        pos_at = straight_calculate_position_at(hobj, time_at, path)
    }
    return pos_at
}

curve_calculate_position_at :: proc(hobj: ^Hitobject, time_at: f64, path: ^Slider_Path) -> (point: vec2) {
    path_instances := window.renderer.slider_instances.data[path.first_instance_at:path.first_instance_at + path.instance_count]

    if len(path_instances) < 1 {
        return vec2({0, 0})
    }

    curve_m_i := i64(len(path_instances) - 1)

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

straight_calculate_position_at :: proc(hobj: ^Hitobject, time_at: f64, path: ^Slider_Path) -> (point: vec2) {
    duration := hobj.end_time_ms - hobj.start_time_ms
    elapsed  := clamp(time_at - hobj.start_time_ms, 0, duration)

    repeat_count := hobj.slider_state.path_travel_count
    t_passes  := (elapsed / duration) * f64(repeat_count)
    pass_idx  := min(int(t_passes), repeat_count - 1)
    pass_frac := t_passes - f64(pass_idx)

    // even passes go forward (0->1), odd passes go backward (1->0)
    t_on_path := pass_frac if pass_idx % 2 == 0 else 1.0 - pass_frac

    return linalg.lerp(path.pos, path.end_pos, vec2{f32(t_on_path), f32(t_on_path)})
}
