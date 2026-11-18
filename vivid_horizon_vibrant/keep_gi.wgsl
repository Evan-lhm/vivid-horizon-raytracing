// Keeps the indirect light after its first smoothing pass for the next frame's blend, as PTGI
// feeds its first a-trous pass back as history (composite10). This target is half the world's size:
// each texel is the mean of the 2x2 full-size pixels of `previous` it covers. The top-left texel
// holds the eye adaptation and is copied as it is.
fn post(input: PostInput) -> vec4<f32> {
    let p = vec2<i32>(input.pixel);
    if p.x == 0 && p.y == 0 { return textureLoad(previous, p, 0); }
    let size = vec2<i32>(textureDimensions(previous));
    let f = p * 2;
    let sum = textureLoad(previous, min(f, size - vec2<i32>(1)), 0)
        + textureLoad(previous, min(f + vec2<i32>(1, 0), size - vec2<i32>(1)), 0)
        + textureLoad(previous, min(f + vec2<i32>(0, 1), size - vec2<i32>(1)), 0)
        + textureLoad(previous, min(f + vec2<i32>(1, 1), size - vec2<i32>(1)), 0);
    return sum * 0.25;
}
