// Glare, first stage: the lit picture at half size (see bloom_lib.wgsl).
fn post(input: PostInput) -> vec4<f32> {
    let size = vec2<i32>(textureDimensions(previous));
    let corner = vec2<i32>(input.uv * vec2<f32>(size)) - vec2<i32>(2);
    return vec4<f32>(tent(previous, corner, size), 1.0);
}
