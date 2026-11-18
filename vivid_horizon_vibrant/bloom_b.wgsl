// Glare, second stage: the half-size picture again at a quarter size (see bloom_lib.wgsl).
fn post(input: PostInput) -> vec4<f32> {
    let size = vec2<i32>(textureDimensions(bloom_a));
    let corner = vec2<i32>(input.uv * vec2<f32>(size)) - vec2<i32>(2);
    return vec4<f32>(tent(bloom_a, corner, size), 1.0);
}
