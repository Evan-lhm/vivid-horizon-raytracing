// Anti-aliasing on geometry edges. A pack's post chain switches Horizon's own TAA and FXAA off and
// never jitters the projection, so a temporal pass can't antialias here (see the API reference).
// This last pass blends a pixel with the neighbours that lie across a depth edge (a silhouette, a
// step in the terrain) and leaves texture detail alone, which FXAA would blur. It runs at the window's
// size while the depth is the world's (they differ below 100 % resolution), so the depth is read by uv.
const EDGE: f32 = 0.04;
const BLEND: f32 = 0.4;
// The share of the light the lens and eye scatter into the halo (a few percent), split evenly between the
// two scales. Energy is kept: the picture loses what the halo gains.
const GLARE: f32 = 0.06;

fn distance_at(uv: vec2<f32>) -> f32 {
    let d = depth_at(uv);
    // The sky counts as very far.
    return select(length(view_position(uv, d)), 1.0e4, d == 0.0);
}

fn post(input: PostInput) -> vec4<f32> {
    let size = vec2<i32>(textureDimensions(previous));
    // input.pixel is the window's, `previous` is the world's: they differ below 100 % resolution.
    let p = vec2<i32>(input.uv * vec2<f32>(size));
    let d0 = distance_at(input.uv);
    var sum = input.color;
    var weight = 1.0;
    for (var i = 0; i < 4; i++) {
        let o = select(select(vec2<i32>(0, 1), vec2<i32>(0, -1), i == 1), select(vec2<i32>(1, 0), vec2<i32>(-1, 0), i == 3), i >= 2);
        let q = clamp(p + o, vec2<i32>(0), size - vec2<i32>(1));
        let d = distance_at((vec2<f32>(q) + 0.5) / vec2<f32>(size));
        if abs(d - d0) > EDGE * min(d, d0) {
            sum += textureLoad(previous, q, 0) * BLEND;
            weight += BLEND;
        }
    }
    let halo = 0.5 * bilinear(bloom_a, input.uv) + 0.5 * bilinear(bloom_b, input.uv);
    var out = mix(sum.rgb / weight, halo, GLARE);
    // Style: raindrops on the lens while the camera stands in the rain, more of them looking up. Each drop is a
    // small lens: it shows the picture around it upside down and blurred (the half-size glare picture), with a
    // darker rim and a glint, then dries over five seconds while it slides down a little.
    let fwd = (frame.view_inverse * vec4<f32>(0.0, 0.0, -1.0, 0.0)).xyz;
    let wet = frame.rain * smoothstep(0.6, 0.95, frame.eye_light_smooth.y) * (1.0 - frame.in_water)
        * select(0.0, 1.0, frame.precipitation == 1u && frame.dimension == 0) * (0.35 + 0.65 * smoothstep(-0.3, 0.6, fwd.y));
    if wet > 0.01 {
        let aspect = f32(size.x) / f32(size.y);
        let q = vec2<f32>(input.uv.x * aspect, input.uv.y) * 7.0;
        let cell = floor(q);
        let h = fract(sin(dot(cell, vec2<f32>(12.9898, 78.233))) * 43758.5453);
        let h2 = fract(h * 57.3 + 0.17);
        let age = fract(frame.time * 0.2 + h * 13.0);
        let centre = cell + vec2<f32>(0.35 + 0.3 * h2, 0.3 + 0.2 * fract(h * 7.7) + 0.15 * age);
        let radius = 0.12 + 0.18 * h2;
        let d = (q - centre) / radius;
        let r = length(d);
        // A few drops that have run down leave a streak above them: a thin film that bends the picture a little.
        let trail = (q.y - (cell.y + 0.05)) / max(centre.y - cell.y - 0.05, 0.01);
        let tx = abs(q.x - centre.x) / (radius * 0.3);
        if h < 0.75 * wet && h2 > 0.6 && r >= 1.0 && trail > 0.0 && trail < 1.0 && tx < 1.0 {
            let film = (1.0 - age) * trail * (1.0 - tx * tx) * 0.8;
            let streak = bilinear(bloom_a, input.uv + vec2<f32>((q.x - centre.x) * 0.02, 0.0)) * 0.85;
            out = mix(out, streak, film);
        }
        if h < 0.75 * wet && r < 1.0 {
            let fade = (1.0 - age) * smoothstep(1.0, 0.85, r);
            let bend = -d * radius * (1.0 - r * r) * 1.4 / 7.0 / vec2<f32>(aspect, 1.0);
            var drop = bilinear(bloom_a, input.uv + bend) * (1.0 - 0.5 * smoothstep(0.6, 1.0, r));
            drop += dot(out, frame.luminance) * 0.4 * exp(-dot(d + vec2<f32>(0.35, 0.35), d + vec2<f32>(0.35, 0.35)) * 30.0);
            out = mix(out, drop, fade);
        }
    }
    return vec4<f32>(out, sum.a / weight);
}
