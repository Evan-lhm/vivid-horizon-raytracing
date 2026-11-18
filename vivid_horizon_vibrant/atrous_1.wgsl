fn post(input: PostInput) -> vec4<f32> {
    return vec4<f32>(atrous(gi_a, vec2<i32>(input.pixel), 1, 2), 1.0);
}
