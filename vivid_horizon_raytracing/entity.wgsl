// Entities and block entities lit by the same model as the terrain's (post.wgsl): the sun or moon with its
// shadow from the shadow map, the sky's ambient by the sky light, block light in its colour. The indirect
// light and the eye's adaptation live in the post chain and are not readable here, so an entity gets the
// terrain's sky fallback and no exposure. Constants and helpers copy post.wgsl's: keep the two in step.

const SUN: f32 = 0.75;
const SKY: f32 = 0.96;
const SKY_TINT: f32 = 0.3;
const MOON: vec3<f32> = vec3<f32>(0.018, 0.036, 0.09);
const TORCH: vec3<f32> = vec3<f32>(1.0, 0.62, 0.30);
const TORCH_POWER: f32 = 1.3;
const CAVE_LIGHT: vec3<f32> = vec3<f32>(0.02, 0.022, 0.026);
const NIGHT_AMBIENT: vec3<f32> = vec3<f32>(0.01, 0.015, 0.03);
// The shadow map's reach around a point, in its own 0..1 coordinates, for four taps.
const PCF: f32 = 0.0009;

fn sky_tint() -> vec3<f32> {
    let c = mix(frame.sky_color, frame.fog_color, 0.3);
    let grey = min(dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)) * 1.6, 1.2);
    return mix(vec3<f32>(grey), c, SKY_TINT);
}

fn sun_colour(height: f32) -> vec3<f32> {
    if height <= 0.0 { return vec3<f32>(0.0); }
    let zenith = degrees(acos(clamp(height, 0.0, 1.0)));
    let air_mass = 1.0 / (height + 0.15 * pow(93.885 - zenith, -1.253));
    return exp(-(vec3<f32>(0.145, 0.340, 0.580) + 0.080) * air_mass) / 0.677;
}

fn weather_sun() -> f32 { return mix(1.0, mix(0.075, 0.03, frame.thunder) / 30.0, frame.rain); }
fn weather_moon() -> f32 { return mix(1.0, mix(0.0225, 0.0375, frame.thunder) / 0.06, frame.rain); }

fn entity(input: EntityInput) -> Surface {
    // The hurt flash lies over the surface in gamma, before the light (vanilla's own order).
    let gamma = vec3<f32>(1.0 / 2.2);
    let base = input.albedo.rgb * input.tint.rgb;
    let flashed = pow(mix(pow(base, gamma), pow(input.overlay.rgb, gamma), input.overlay.a), vec3<f32>(2.2));
    let alpha = input.albedo.a * input.tint.a;
    // Eyes and glowing layers draw at full brightness.
    if input.full_light { return Surface(vec4<f32>(flashed * 1.5, alpha)); }

    let n = input.normal;
    let sky = input.light.y;
    let block = input.light.x;
    let sun_up = frame.sun_direction.y > 0.0;
    let height = select(0.0, frame.sun_direction.y, sun_up);
    let to_light = frame.light_direction;
    let light_colour = select(MOON * weather_moon(), sun_colour(height) * SUN * weather_sun(), sun_up);
    let facing = max(dot(n, to_light), 0.0);

    var visible = 1.0;
    if frame.has_shadow == 1u && facing > 0.0 {
        let sp = shadow_position(input.position + n * 0.04);
        visible = 0.25 * (
            textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy + vec2<f32>(PCF, 0.0), sp.z)
            + textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy - vec2<f32>(PCF, 0.0), sp.z)
            + textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy + vec2<f32>(0.0, PCF), sp.z)
            + textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy - vec2<f32>(0.0, PCF), sp.z));
    }
    let direct = light_colour * facing * visible * smoothstep(0.0, 0.5, sky) * select(0.0, 1.0, frame.dimension == 0);

    let up = 0.8 + 0.2 * n.y;
    let fallback = (sky_tint() * SKY * up + NIGHT_AMBIENT) * pow(sky, 1.5);
    let floor_light = select(CAVE_LIGHT, vec3<f32>(0.06, 0.026, 0.016), frame.dimension == -1)
        * select(1.0, 0.35 + 0.65 * smoothstep(0.0, 0.3, height), frame.dimension == 0);
    let ambient = max(fallback, floor_light);

    let lc = block_light_color(input.position);
    let torch_colour = select(TORCH, lc.rgb / max(max(lc.r, max(lc.g, lc.b)), 0.001), lc.a > 0.0);
    let torch = torch_colour * TORCH_POWER * block * block + input.colored_light * TORCH_POWER;

    // Particles (kind 4) are flat cards turned to the camera: their normal says nothing about the light, so they
    // take the light around them with no facing term (sun by its shadow alone, the sky, the lamps). Flames, sparks
    // and other bright particles in a lit spot glow at their own colour rather than being shaded.
    if input.kind == 4u {
        let around = light_colour * visible * smoothstep(0.0, 0.5, sky) * select(0.0, 0.6, frame.dimension == 0) + ambient + torch;
        let glow = smoothstep(0.75, 0.95, block) * smoothstep(0.5, 0.8, max(base.r, max(base.g, base.b)));
        return Surface(vec4<f32>(mix(flashed * around, flashed * 1.2, glow), alpha));
    }

    return Surface(vec4<f32>(flashed * (direct + ambient + torch), alpha));
}
