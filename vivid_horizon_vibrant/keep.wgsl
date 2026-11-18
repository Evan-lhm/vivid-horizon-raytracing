// Keeps this frame's shadow answer for the next frame's blend.
fn post(input: PostInput) -> vec4<f32> {
    return textureLoad(vis_a, vec2<i32>(input.pixel), 0);
}
