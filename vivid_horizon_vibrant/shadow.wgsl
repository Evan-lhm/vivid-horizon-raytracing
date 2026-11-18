// Soft shadows: one shadow ray per pixel, aimed at a random point of a cone around the light, then
// blended with last frame's answer for this surface point. Writes `vis_a` (r: light reaching the
// point, g: its distance, b: 256 times which block face it is (1 to 6, 0 for the sky) plus its age in frames). A pack target's
// alpha is always 1, so nothing is kept there.
// `vis_b` is last frame's copy of `vis_a`.
//
// History is kept the way PTGI's SVGF does: only from a pixel on the same face at about the same
// distance, and the newer the pixel, the more of this frame's answer it takes (1 / age), so a
// freshly uncovered pixel fills in at once instead of fading in slowly.
const REACH: f32 = 512.0;
// The light's apparent size, in radians: the penumbra's width over distance. The real sun is 0.0047.
const SOFTNESS: f32 = 0.0046;
// The least of each frame's answer that enters the average, once a pixel is old.
const BLEND: f32 = 0.08;
const MAX_AGE: f32 = 255.0;

// Which of the six block faces a normal is: 1 to 6, 0 is kept for "no surface". Two faces meeting
// at an edge have nearly the same depth, so depth alone lets one's light slide onto the other
// when the camera moves.
fn face_id(n: vec3<f32>) -> f32 {
    let a = abs(n);
    var i = 0.0;
    if a.y >= a.x && a.y >= a.z { i = select(2.0, 3.0, n.y < 0.0); }
    else if a.x >= a.z { i = select(0.0, 1.0, n.x < 0.0); }
    else { i = select(4.0, 5.0, n.z < 0.0); }
    return i + 1.0;
}

// How much of the sun's light gets through to `origin` along `dir`: 0 behind terrain, and a share behind
// water, glass and ice (a fluid keeps 35 %, other layers what their alpha lets through), three layers deep.
fn sun_through(origin: vec3<f32>, dir: vec3<f32>, reach: f32) -> f32 {
    var o = origin;
    var t = 1.0;
    for (var i = 0; i < 3; i++) {
        let hit = trace_layers(o, dir, reach, RAY_SOLID | RAY_TRANSLUCENT);
        if hit.distance < 0.0 { return t; }
        if !hit.translucent { return 0.0; }
        t *= 1.0 - select(hit.albedo.a, 0.65, hit.fluid == 1u);
        o = hit.position + dir * 0.02;
    }
    return t;
}

fn ign(p: vec2<f32>, frame_index: u32) -> f32 {
    let q = p + 5.588238 * f32(frame_index % 64u);
    return fract(52.9829189 * fract(dot(q, vec2<f32>(0.06711056, 0.00583715))));
}

fn post(input: PostInput) -> vec4<f32> {
    let texel = vec2<i32>(input.pixel);
    if input.depth == 0.0 { return vec4<f32>(1.0, 0.0, 0.0, 1.0); }
    let s = surface_at(texel);
    if !s.present { return vec4<f32>(1.0, 0.0, 0.0, 1.0); }
    let n = s.normal;
    let face = face_id(n);
    let to_light = frame.light_direction;
    let position = view_position(input.uv, input.depth);
    let dist = length(position);
    var v = 1.0;
    if frame.has_ray_tracing == 1u && frame.dimension == 0 && dot(n, to_light) > 0.0
        && max(abs(position.x), abs(position.z)) < frame.ray_distance {
        let t = normalize(cross(to_light, select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(to_light.y) > 0.9)));
        let bt = cross(to_light, t);
        let origin = position + n * (0.01 + 0.002 * dist);
        var lit = 0.0;
        // Two cone rays, the second a half turn on: a smoother penumbra from the same history.
        for (var k = 0u; k < 2u; k++) {
            let a = ign(input.pixel + f32(k) * 11.0, frame.frame_index);
            let b = ign(input.pixel + vec2<f32>(37.0, 17.0) + f32(k) * 7.0, frame.frame_index);
            let r = sqrt(a) * SOFTNESS;
            let phi = 6.2831853 * b;
            let dir = normalize(to_light + t * (r * cos(phi)) + bt * (r * sin(phi)));
            lit += 0.5 * sun_through(origin, dir, REACH);
        }
        v = lit;
    }
    // Last frame's value for this point.
    let clip = frame.previous_view_projection * vec4<f32>(position + frame.camera_motion, 1.0);
    var out_v = v;
    var age = 1.0;
    if clip.w > 0.0 && frame.delta_time > 0.0 {
        let ndc = clip.xy / clip.w;
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if all(uv > vec2<f32>(0.0)) && all(uv < vec2<f32>(1.0)) {
            // PTGI (composite8) tries the neighbours of the reprojected texel when the first one
            // fails the face and distance tests, so an edge keeps its history while the view moves.
            var taps = array<vec2<i32>, 5>(vec2<i32>(0, 0), vec2<i32>(1, 0), vec2<i32>(-1, 0), vec2<i32>(0, 1), vec2<i32>(0, -1));
            let base = vec2<i32>(uv * frame.resolution);
            var found = false;
            for (var i = 0; i < 5; i++) {
                if found { continue; }
                let q = clamp(base + taps[i], vec2<i32>(0), vec2<i32>(frame.resolution) - vec2<i32>(1));
                let h = textureLoad(vis_b, q, 0);
                let hface = floor(h.b / 256.0);
                if hface == face && abs(h.g - dist) < 0.05 * dist + 0.1 {
                    age = min(h.b - hface * 256.0 + 1.0, MAX_AGE);
                    out_v = mix(h.r, v, max(1.0 / age, BLEND));
                    found = true;
                }
            }
        }
    }
    return vec4<f32>(out_v, dist, face * 256.0 + age, 1.0);
}
