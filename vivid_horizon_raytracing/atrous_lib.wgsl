// One step of an edge-stopping a-trous filter over the indirect light, after PTGI's SVGF
// spatial filter (svgf.glsl spatialFilter, Unlicense): a 3x3 whose taps are `step` pixels apart,
// kernel 1, 2/3, 4/9, a neighbour counting only on the same surface (normal, distance) and about
// as bright. Three passes with steps 1, 2, 4 reach 7 pixels each way. The chain's picture is the
// scratch buffer: the passes hand the light on through `previous`, and the last pass reads the
// world's picture from `scene_color`.
const GI_RANGE_F: f32 = 192.0;
fn atrous_lum(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)); }
fn atrous_ok(dist: f32) -> bool {
    return frame.has_ray_tracing == 1u && frame.dimension >= -1 && frame.dimension <= 1 && dist > 0.0 && dist < min(GI_RANGE_F, frame.ray_distance);
}
fn atrous(src: texture_2d<f32>, p: vec2<i32>, step: i32, scale: i32) -> vec3<f32> {
    let c = textureLoad(src, p / scale, 0).rgb;
    let v0 = textureLoad(vis_a, p, 0);
    let d0 = v0.g;
    // The top-left pixel of `gi_a` holds the eye adaptation, not light.
    // The top-left texel of the half-size `gi_a` holds the eye adaptation: full pixel (0, 0) passes it on,
    // the other pixels it covers hold no light.
    if p.x == 0 && p.y == 0 { return c; }
    if (p / scale).x == 0 && (p / scale).y == 0 { return vec3<f32>(0.0); }
    if !atrous_ok(d0) { return c; }
    let s0 = surface_at(p);
    if !s0.present { return c; }
    let age = v0.b - floor(v0.b / 256.0) * 256.0;
    let l0 = atrous_lum(c);
    // A pixel that read black (its half-size texel fell on sky, an entity or water) takes what its
    // neighbours on the same surface hold, whatever their brightness.
    let phi = select(select(0.25, 0.6, age < 8.0) * (l0 + 0.05), 1000.0, l0 < 0.002);
    var sum = c;
    var weight = 1.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            if x == 0 && y == 0 { continue; }
            let q = p + vec2<i32>(x, y) * step;
            if (q / scale).x == 0 && (q / scale).y == 0 { continue; }
            let d = textureLoad(vis_a, q, 0).g;
            if !atrous_ok(d) { continue; }
            let s = surface_at(q);
            if !s.present { continue; }
            let g = textureLoad(src, q / scale, 0).rgb;
            let k = select(2.0 / 3.0, 4.0 / 9.0, x != 0 && y != 0);
            let w = k * pow(max(dot(s0.normal, s.normal), 0.0), 32.0)
                * exp(-abs(d - d0) / (0.04 * d0 + 0.1) - abs(atrous_lum(g) - l0) / phi);
            sum += g * w;
            weight += w;
        }
    }
    return sum / weight;
}
