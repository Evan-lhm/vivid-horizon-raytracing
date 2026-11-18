fn post(input: PostInput) -> vec4<f32> {
    return vec4<f32>(atrous(previous, vec2<i32>(input.pixel), 2, 1), 1.0);
}
