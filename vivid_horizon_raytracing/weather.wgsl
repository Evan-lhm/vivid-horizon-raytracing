// Rain and snow streaks. The streaks are drawn into the world's picture before the post pass relights it, so
// over terrain their colour is a surface colour the light then falls on; over the sky it is shown as is.
// Style: rain thinner and paler than vanilla's (a third of its opacity, a darker cool grey), so a storm reads as a veil
// rather than a wall of lines; it dims with the day and under cover. Snow keeps its flakes, whiter.
fn weather(input: WeatherInput) -> vec4<f32> {
    let day = mix(0.12, 1.0, smoothstep(-0.12, 0.2, frame.sun_direction.y));
    let open = mix(0.3, 1.0, input.light.y);
    let lamp = input.light.x * vec3<f32>(1.0, 0.75, 0.5) * 0.6;
    if input.snow {
        return vec4<f32>(vec3<f32>(0.95, 0.97, 1.0) * (day * open + lamp), input.color.a);
    }
    let grey = vec3<f32>(0.34, 0.37, 0.42) * (day * open + lamp);
    return vec4<f32>(grey, input.color.a * 0.35);
}
