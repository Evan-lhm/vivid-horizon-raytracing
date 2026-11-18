// Vibrant's atmosphere, shared by the sky and the post pass (so the far terrain's haze is the sky's own colour at
// the horizon). Single scattering of sunlight by the air (Rayleigh) and its haze (Mie), Kasten-Young air mass.

// Rayleigh optical depth at the zenith by channel, in the ratio of the molecules' cross-sections (lambda^-4 over
// 680, 550, 440 nm), and Mie's (grey). Style: the Rayleigh depths are scaled so the noon sky reads a clear blue;
// the real ones are about a third lower in red.
const ATM_R: vec3<f32> = vec3<f32>(0.10, 0.235, 0.58);
const ATM_M: f32 = 0.07;
// Ozone's Chappuis band, absorbing green and orange high in the air: why the sky above a sunset is blue-violet and
// not olive. Zenith depths about (0.02, 0.04, 0.002); style: doubled, for a deeper twilight.
const ATM_O: vec3<f32> = vec3<f32>(0.04, 0.08, 0.004);
// The sky's brightness at the zenith with a high sun, in the frame's linear units. Style: a free scale.
const ATM_SKY_LUM: f32 = 0.42;

fn atm_air_mass(h: f32) -> f32 {
    let e = clamp(h, 0.0, 1.0);
    let zenith = degrees(acos(e));
    return 1.0 / (e + 0.15 * pow(max(93.885 - zenith, 0.01), -1.253));
}
fn atm_hg(c: f32, g: f32) -> f32 {
    let d = 1.0 + g * g - 2.0 * g * c;
    return (1.0 - g * g) / (12.566 * pow(d, 1.5));
}
// The sun's light after the air its ray crosses to the ground (the terrain's own sun colour uses NVIDIA's depths).
fn atm_sun(height: f32) -> vec3<f32> {
    if height <= 0.0 { return vec3<f32>(0.0); }
    return exp(-(vec3<f32>(0.145, 0.340, 0.580) + 0.080) * atm_air_mass(height)) / 0.677;
}
// The light scattered toward the eye along `d` by the air lit by a sun toward `s`, unscaled: the phases (Rayleigh
// 1 + cos^2, Mie Henyey-Greenstein g = 0.76) weighted by each one's depth, summed along the view ray as
// 1 - exp(-depth), times the sun's light where it scatters. Looking low, the light scatters low in the air, after
// most of the sun's own path (a reddened sun); looking up, it scatters high, after a sixth of it (a bluer sky above
// a sunset).
fn atm_raw(d: vec3<f32>, s: vec3<f32>) -> vec3<f32> {
    let mu = dot(d, s);
    let od = ATM_R + ATM_M;
    let mv = atm_air_mass(max(d.y, 0.0));
    let ms = atm_air_mass(max(s.y, 0.0));
    let phase = (ATM_R * 0.0597 * (1.0 + mu * mu) + ATM_M * atm_hg(mu, 0.76)) * 12.566 / od;
    let sun = exp(-od * ms * mix(0.55, 0.1, clamp(d.y, 0.0, 1.0)) - ATM_O * ms) * smoothstep(-0.06, 0.02, s.y);
    return phase * (1.0 - exp(-od * mv)) * sun;
}
fn atm_scale() -> f32 {
    let z = atm_raw(vec3<f32>(0.0, 1.0, 0.0), normalize(vec3<f32>(0.5, 0.85, 0.2)));
    return ATM_SKY_LUM / dot(z, vec3<f32>(0.2126, 0.7152, 0.0722));
}
// The sky toward `d`: the atmosphere by day, vanilla's `vanilla` at night (blended through twilight) and, darker,
// in rain. Below the horizon, the horizon's own colour (the far haze).
fn atm_colour(d: vec3<f32>, vanilla: vec3<f32>) -> vec3<f32> {
    let s = frame.sun_direction;
    let day = smoothstep(-0.1, 0.05, s.y);
    let dd = normalize(vec3<f32>(d.x, max(d.y, 0.002), d.z));
    // Style: the horizon a little darker and bluer than single scattering gives (it saturates to near white there):
    // the multiple scattering and the ground's shadow the model leaves out.
    let low = 1.0 - sqrt(clamp(dd.y, 0.0, 1.0));
    let clear = atm_raw(dd, s) * atm_scale() * mix(vec3<f32>(1.0), vec3<f32>(0.58, 0.7, 0.93), low);
    // Style: rain's sky darker than vanilla's (a thick deck overhead lets through a fraction of the light).
    return mix(vanilla, mix(clear, vanilla * 0.55, frame.rain), day);
}

// The sky's light on a surface open to the whole sky, without the sun's aureole: the air's scattering at right
// angles to the sun (Rayleigh's phase at cos = 0 and Mie's mean), over about one and a half air masses.
fn atm_ambient() -> vec3<f32> {
    let s = frame.sun_direction;
    let od = ATM_R + ATM_M;
    let ms = atm_air_mass(max(s.y, 0.0));
    let raw = (ATM_R * 0.0597 * 12.566 + ATM_M) / od * (1.0 - exp(-od * 1.5)) * exp(-od * ms * 0.3) * smoothstep(-0.06, 0.02, s.y);
    let day = smoothstep(-0.1, 0.05, s.y);
    // At night the sky's light is starlight and airglow, far below vanilla's night sky colour (a display choice).
    // Style: a moonlit night sky a readable deep blue.
    let moon_up = smoothstep(-0.05, 0.2, frame.moon_direction.y);
    return mix(frame.sky_color * mix(0.08, 0.2, moon_up), mix(raw * atm_scale(), frame.sky_color * 0.3, frame.rain), day);
}

// Rain rings on puddles and still water: each half-block cell gets a drop at a random spot every 1.1 s, whose
// ring runs out and dies away. Returns the surface's slope (x, z), 0 without rain; the caller scales it by how
// open to the sky the point is. Style: real rings are smaller and denser, these are sized to read on screen.
fn rain_ring_layer(p: vec2<f32>, t: f32, seed: f32) -> vec2<f32> {
    let cell = floor(p);
    let h = fract(sin(dot(cell + seed, vec2<f32>(127.1, 311.7))) * 43758.5453);
    let h2 = fract(h * 91.7 + 0.31);
    let d = p - (cell + 0.3 + 0.4 * vec2<f32>(h, h2));
    let r = max(length(d), 1.0e-4);
    let age = fract(t * 0.9 + h * 7.0);
    let x = (r - age * 0.45) * 30.0;
    let fade = (1.0 - age) * (1.0 - age);
    return d / r * cos(x) * exp(-x * x * 0.08) * fade * 0.45;
}
fn rain_ripple(p: vec2<f32>) -> vec2<f32> {
    if frame.rain < 0.01 || frame.precipitation != 1u { return vec2<f32>(0.0); }
    let q = p * 2.0;
    return (rain_ring_layer(q, frame.time, 0.0) + rain_ring_layer(q + 0.5, frame.time + 0.37, 17.0)) * frame.rain;
}

// The block light (0..1) from a surface's second float (material.wgsl): bits 16 to 23, or, for snow and ice (negative
// values), the bits above the kind.
fn surf_block(v: f32) -> f32 {
    return select(f32(u32(max(v, 0.0)) >> 16u), f32((u32(-v + 0.5) >> 2u) & 255u), v < 0.0) / 255.0;
}
