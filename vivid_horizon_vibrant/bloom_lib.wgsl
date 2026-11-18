// Glare: the light a lens and an eye scatter. Their point-spread function has a sharp core and wide tails,
// so every bright point leaves a faint halo and nothing is cut by a threshold. Two stages stand for the
// tails: the picture at half size, then at a quarter, each a tent filter over 4x4 texels (a Gaussian's
// shape, in linear light, so energy is kept). This is a departure from the real function (a sum of
// Gaussians, not the measured Moffat-like tail); the weights below are the tent's.

// A tent filter over the 4x4 texels from `corner`, weights (1 3 3 1) / 8 on each axis.
fn tent(tex: texture_2d<f32>, corner: vec2<i32>, size: vec2<i32>) -> vec3<f32> {
    var sum = vec3<f32>(0.0);
    for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
            let wx = select(3.0, 1.0, x == 0 || x == 3);
            let wy = select(3.0, 1.0, y == 0 || y == 3);
            let q = clamp(corner + vec2<i32>(x, y), vec2<i32>(0), size - vec2<i32>(1));
            // Half-float picture: a lamp seen straight on can hold far more than the format does.
            sum += min(textureLoad(tex, q, 0).rgb, vec3<f32>(64.0)) * wx * wy;
        }
    }
    return sum / 64.0;
}

// The texture at `uv` (0..1), bilinear, by four loads.
fn bilinear(tex: texture_2d<f32>, uv: vec2<f32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(tex));
    let top = size - vec2<i32>(1);
    let p = uv * vec2<f32>(size) - 0.5;
    let i = vec2<i32>(floor(p));
    let f = fract(p);
    let a = textureLoad(tex, clamp(i, vec2<i32>(0), top), 0).rgb;
    let b = textureLoad(tex, clamp(i + vec2<i32>(1, 0), vec2<i32>(0), top), 0).rgb;
    let c = textureLoad(tex, clamp(i + vec2<i32>(0, 1), vec2<i32>(0), top), 0).rgb;
    let d = textureLoad(tex, clamp(i + vec2<i32>(1, 1), vec2<i32>(0), top), 0).rgb;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
