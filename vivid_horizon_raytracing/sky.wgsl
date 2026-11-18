// The sky of "Vibrant": an atmosphere of single scattering (Rayleigh and Mie), the pack's own round sun, and
// volumetric clouds built on a grid of blocks (`[sky] clouds = false`, `sun = false`). The moon and the stars stay
// the game's.

// The functions are in sky_lib.wgsl (shared with the post pass).

fn sky(input: SkyInput) -> vec4<f32> {
    let d = normalize(input.direction);
    var c = input.color.rgb;
    if frame.dimension == 0 {
        c = sky_colour(d, input.color.rgb) + sun_disc(d) + night_sky(d) + moon_disc(d);
        c = clouds(d, c);
    }
    // Under `[frame] fog = "pack"` the engine fogs no sky: the pack does. In a thick medium (water, lava, powder
    // snow, blindness) the sky is the medium's colour as vanilla has it.
    let thick = frame.fog_environment.y < 300.0;
    c = mix(c, frame.fog_color, select(0.0, vanilla_fog(d * 1000.0), thick));
    return vec4<f32>(c, input.color.a);
}
