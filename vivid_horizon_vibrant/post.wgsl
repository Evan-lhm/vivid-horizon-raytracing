// The light of every solid surface, in one model: the sun or moon with a ray for its shadow, the
// sky's ambient scaled by the sky light, and block light. Where the game doesn't trace (no
// ray-query GPU, past the scene, `HORIZON_RAY_TRACING` unset) the same light comes without the
// shadow ray. Sky, water, glass, particles and entities keep the picture as it is.

// The sun's light on a surface facing it, and the sky's on one facing up under open sky.
const SUN: f32 = 0.75;
// Colour pop, after the references (PTGI by day, RTX underwater): 1 is neutral.
// Style: 1.2 in Vibrant (the base keeps 1.15); real light doesn't saturate colours, this is a grade. 1.35 made
// savanna grass yellow-olive against vanilla.
const SATURATION: f32 = 1.2;
const SKY: f32 = 0.96;
// How much of the sky's blue the ambient keeps; the rest is white, so sand stays sand.
// Vibrant keeps more of the sky's blue in the shade (0.5, the base 0.3): closer to a real blue sky, not a departure.
const SKY_TINT: f32 = 0.5;
// The moon: a fraction of the sun's, bluer.
// Style (Vibrant): the moon twice the base pack's, so a moonlit night reads (a real full moon is about 1/400000 of
// the sun, far darker than this); caves, which the moon doesn't reach, are unchanged.
const MOON: vec3<f32> = vec3<f32>(0.036, 0.072, 0.17);
// Block light's colour and strength at level 15.
const TORCH: vec3<f32> = vec3<f32>(1.0, 0.62, 0.30);
const TORCH_POWER: f32 = 1.3;
// A block light's fall-off. Vanilla's level drops one a block from the source (15 at a glowing block, 14 at a
// torch), so 15 (1 - level) is the distance r in blocks (along the grid: the Manhattan distance, longer than the
// straight line on a diagonal). Light from a small source falls as 1 / r^2; 1 / (1 + r^2) keeps it finite at the
// source, and a window (1 - (r/15)^4)^2 takes it to zero at level 0, where vanilla's light ends. Scaled so a face
// two blocks from a torch is lit as before (the old curve was level^2, which fell far too slowly).
fn block_falloff(b: f32) -> f32 {
    let r = 15.0 * (1.0 - b);
    let w = 1.0 - pow(r / 15.0, 4.0);
    return 3.75 / (1.0 + r * r) * w * w;
}
// The least light any surface keeps, so a cave away from torches is dim but never black (vanilla keeps
// a floor too). Cool, like the ambient of a place the sun never reaches. Like PTGI's ambient floor
// (0.04 by day, 0.005 at night), it follows the time of day: a third of it at night.
const CAVE_LIGHT: vec3<f32> = vec3<f32>(0.02, 0.022, 0.026);
// Eye adaptation (PTGI's exposure, NVIDIA's auto-exposure): the whole picture is scaled up to this
// much when the light around the player is nil, and back to 1 in open light. The light pass keeps the
// smoothed brightness in the top-left pixel of `gi_a`.
const EXPOSURE_MAX: f32 = 1.6;
fn exposure() -> f32 {
    if frame.has_ray_tracing == 0u || frame.dimension != 0 { return 1.0; }
    let b = clamp(textureLoad(gi_a, vec2<i32>(0, 0), 0).r - 1.0, 0.0, 1.0);
    return mix(EXPOSURE_MAX, 1.0, b);
}
// What the ambient keeps in a cave at night, so it is dark but not black.
const NIGHT_AMBIENT: vec3<f32> = vec3<f32>(0.01, 0.015, 0.03);

// The sun's colour: white at noon, warmer as it nears the horizon.
// The sky's colour, desaturated toward grey of the same brightness (so a night sky stays dark).
fn sky_tint() -> vec3<f32> {
    let c = mix(frame.sky_color, frame.fog_color, 0.3);
    let grey = min(dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)) * 1.6, 1.2);
    return mix(vec3<f32>(grey), c, SKY_TINT);
}

// The sun's colour through the air it crosses, after NVIDIA's rtx-remix-minecraft
// (LightManager.directAtmosphereTransmittance, Apache-2.0): Kasten-Young air mass, Rayleigh
// (0.145, 0.340, 0.580) and Mie 0.080 optical depths. Divided by its luminance at the zenith
// (0.677), so SUN stays the noon brightness.
fn sun_colour(height: f32) -> vec3<f32> {
    if height <= 0.0 { return vec3<f32>(0.0); }
    let zenith = degrees(acos(clamp(height, 0.0, 1.0)));
    let air_mass = 1.0 / (height + 0.15 * pow(93.885 - zenith, -1.253));
    return exp(-(vec3<f32>(0.145, 0.340, 0.580) + 0.080) * air_mass) / 0.677;
}

// The indirect light with its noise smoothed, after PTGI's SVGF spatial filter: a weighted average
// where a neighbour counts only on the same surface (close normal, close distance) and about as
// bright as this pixel (so a bright spot isn't smeared, and shadows keep their edge). A young pixel
// has little history, so it averages the 5x5 around it; an old one only a sparse 3x3 (taps two
// pixels apart). The history the next frame blends with stays unfiltered, so the blur doesn't compound.
// Rain and thunder dim the sun and moon, after NVIDIA's rtx-remix-minecraft (LightManager:
// sun 30 -> 0.075 in rain, 0.03 in thunder; moon 0.06 -> 0.0225, 0.0375), by vanilla's gradients.
fn weather_sun() -> f32 { return mix(1.0, mix(0.075, 0.03, frame.thunder) / 30.0, frame.rain); }
fn weather_moon() -> f32 { return mix(1.0, mix(0.0225, 0.0375, frame.thunder) / 0.06, frame.rain); }
fn lum(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)); }

// Where the indirect light holds a value: ray tracing on, in the overworld, within the range the
// light pass traces (the pass leaves black elsewhere and the final colour keeps the plain ambient).
const GI_RANGE: f32 = 192.0;
// Under water the indirect light stops at 24 blocks (fading out from 18): past that the water's own scattered
// light covers most of what a bounce would add. A cost cut, not physics.
fn gi_range() -> f32 { return select(GI_RANGE, 24.0, frame.eye_in == 1u && frame.dimension == 0); }
fn gi_ok(dist: f32) -> bool {
    return frame.has_ray_tracing == 1u && frame.dimension >= -1 && frame.dimension <= 1 && dist > 0.0 && dist < min(gi_range(), frame.ray_distance);
}

fn smooth_gi(p: vec2<i32>, n0: vec3<f32>, age: f32) -> vec3<f32> {
    let c = textureLoad(gi_a, p, 0).rgb;
    let d0 = textureLoad(vis_a, p, 0).g;
    if !gi_ok(d0) { return c; }
    let l0 = lum(c);
    let young = age < 8.0;
    let radius = select(1, 2, young);
    let step = select(2, 1, young);
    // How different in brightness still counts as the same light: wider while the pixel is young.
    let phi = (select(0.25, 0.6, young)) * (l0 + 0.05);
    var sum = c;
    var weight = 1.0;
    for (var y = -radius; y <= radius; y++) {
        for (var x = -radius; x <= radius; x++) {
            if x == 0 && y == 0 { continue; }
            let q = p + vec2<i32>(x, y) * step;
            let d = textureLoad(vis_a, q, 0).g;
            if !gi_ok(d) || (q.x == 0 && q.y == 0) { continue; }
            let s = surface_at(q);
            if !s.present { continue; }
            let g = textureLoad(gi_a, q, 0).rgb;
            let w = pow(max(dot(n0, s.normal), 0.0), 24.0)
                * exp(-abs(d - d0) / (0.04 * d0 + 0.1))
                * exp(-abs(lum(g) - l0) / phi);
            sum += g * w;
            weight += w;
        }
    }
    return sum / weight;
}

// Light shafts, screen space (the classic radial march, no history, so nothing swims when the view
// moves): from a pixel toward the sun on screen, the share of the taps that land on open sky, nearer
// taps counting more, strongest close to the sun. The pack's first shafts kept a history and smeared;
// this has none.
const SHAFT: f32 = 0.16;
fn shafts(uv: vec2<f32>, pixel: vec2<f32>) -> f32 {
    if frame.sun_direction.y <= 0.02 { return 0.0; }
    let sv = (vec4<f32>(frame.sun_direction, 0.0) * frame.view_inverse).xyz;
    let clip = frame.projection * vec4<f32>(sv * 100.0, 1.0);
    if clip.w <= 0.0 { return 0.0; }
    let ndc = clip.xy / clip.w;
    let sun_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let to_sun = sun_uv - uv;
    let near = 1.0 - clamp(length(to_sun * vec2<f32>(frame.resolution.x / frame.resolution.y, 1.0)) / 1.4, 0.0, 1.0);
    if near <= 0.0 { return 0.0; }
    let jitter = fract(52.9829189 * fract(dot(pixel, vec2<f32>(0.06711056, 0.00583715))));
    var sky = 0.0;
    var decay = 1.0;
    var total = 0.0;
    for (var i = 0; i < 16; i++) {
        let p = clamp(uv + to_sun * ((f32(i) + jitter) / 16.0), vec2<f32>(0.0), vec2<f32>(0.9999));
        sky += select(0.0, decay, textureLoad(scene_depth, vec2<i32>(p * frame.resolution), 0) == 0.0);
        total += decay;
        decay *= 0.94;
    }
    return sky / total * near * near;
}

// Light shafts through the engine's shadow map: from the camera to the pixel, a dozen dithered steps, each
// asking the map whether the sun reaches that point; the lit share, weighted by how much the view looks
// toward the sun (a forward-scattering lobe) and by the length marched, is the light in the air.
// Light shafts through the engine's shadow map, as a thin uniform dust in the air: from the camera to the
// pixel, 32 dithered steps, each asking the map whether the sun reaches that point of air. A lit point
// scatters toward the eye in proportion to the dust's density, less the dust between it and the eye
// (Beer-Lambert, EXTINCTION a block), and mostly forward, toward the sun (the phase). So a beam through a
// canopy shows against the shade, far air counts for little, and open sky adds only a faint glow near the sun.
const SHAFT_MAP: f32 = 1.0;
const DUST: f32 = 0.025;
const EXTINCTION: f32 = 0.03;
// The dust's density by the day, the weather and the place: thicker with a low sun (dew, a longer path),
// after rain, and where it is humid; thinner in the cold dry air of snow and the day's brightest hours.
fn dust_density() -> f32 {
    let low_sun = 1.0 + 1.2 * (1.0 - smoothstep(0.0, 0.5, frame.sun_direction.y));
    let humid = 0.6 + 0.9 * frame.downfall + 1.2 * frame.wetness;
    let warmth = mix(0.5, 1.3, smoothstep(0.0, 1.5, frame.temperature));
    return DUST * low_sun * humid * warmth;
}
// The colour sunlight takes through stained glass (or ice) between a point and the light, from the shadow maps: lit
// past the solid terrain but not past the translucent one means a pane is in the way, and `shadow_color` holds that
// pane's colour. A filter passes light by wavelength (Beer-Lambert over the pane's thickness): its colour is the
// spectrum it lets through. How much light the pane passes in all is already in the shadow pass (its alpha), so only
// the hue is taken here, brightest channel 1. Water is left to the caustics. One layer: the map keeps the nearest pane.
fn glass_filter(sp: vec3<f32>) -> vec3<f32> {
    if any(sp.xy <= vec2<f32>(0.001)) || any(sp.xy >= vec2<f32>(0.999)) || sp.z <= 0.0 || sp.z >= 1.0 { return vec3<f32>(1.0); }
    let clear = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, sp.xy, sp.z);
    if clear >= 1.0 { return vec3<f32>(1.0); }
    let c = textureLoad(shadow_color, vec2<i32>(sp.xy * vec2<f32>(textureDimensions(shadow_color))), 0);
    if c.a >= 1.0 { return vec3<f32>(1.0); }
    let hue = c.rgb / max(max(c.r, max(c.g, c.b)), 0.001);
    return mix(vec3<f32>(1.0), hue, 1.0 - clear);
}

fn shafts_map(position: vec3<f32>, pixel: vec2<f32>) -> vec3<f32> {
    if frame.has_shadow == 0u || frame.sun_direction.y <= 0.02 || frame.dimension != 0 { return vec3<f32>(0.0); }
    let len = length(position);
    let dir = position / max(len, 0.001);
    let reach = min(len, 96.0);
    // The dither shifts by the golden ratio each frame, so its grain averages out in the eye instead of
    // staying put on the screen and sliding over the scene as the view moves.
    let jitter = fract(fract(52.9829189 * fract(dot(pixel, vec2<f32>(0.06711056, 0.00583715)))) + f32(frame.frame_index % 64u) * 0.61803398);
    var scattered = vec3<f32>(0.0);
    var pane = vec3<f32>(1.0);
    for (var i = 0; i < 32; i++) {
        let t = reach * (f32(i) + jitter) / 32.0;
        let sp = shadow_position(dir * t);
        let s = textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z) * exp(-EXTINCTION * t);
        // A beam past a stained-glass window takes the window's colour, read every fourth step (a pane's colour
        // changes little along a beam; each read costs a shadow-map compare).
        if (i & 3) == 0 { pane = glass_filter(sp); }
        scattered += s * pane;
    }
    let phase = 0.04 + 0.96 * pow(clamp(dot(dir, frame.light_direction), 0.0, 1.0), 4.0);
    return scattered * (reach / 32.0) * dust_density() * phase;
}

// Wet ground in rain: surfaces open to the sky darken as they soak, and puddles (a value noise on the
// world's horizontal position, on upward faces) mirror what a ray off them hits, by Fresnel. After the
// wet-surface look of RTX packs; `frame.wetness` rises over 30 seconds of rain and dries over 10.
fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}
fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + vec2<f32>(1.0, 0.0)), u.x), mix(hash2(i + vec2<f32>(0.0, 1.0)), hash2(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}

// The same waves as material.wgsl (keep the two in step): the slope of the surface, a sum of travelling sines.
fn wave_slope(p: vec2<f32>, t: f32) -> vec2<f32> {
    // Fourteen travelling sines: directions spread by the golden angle so none lines up with another,
    // wavelengths in a geometric ladder, slope shrinking with the wavenumber and the speed following
    // deep water's dispersion (w grows as the square root of k). The directions are the wind's, not the
    // sun's or the moon's: waves do not follow the light.
    var slope = vec2<f32>(0.0);
    for (var i = 0; i < 14; i++) {
        let fi = f32(i);
        let angle = fi * 2.39996 + 0.7;
        let d = vec2<f32>(cos(angle), sin(angle));
        let k = 0.8 * pow(1.28, fi);
        slope += d * 0.03 * pow(k, -0.55) * cos(dot(p, d) * k + t * 1.1 * sqrt(k) + fi * 1.7);
    }
    return slope;
}

// Light bunching under the waves: -1 where no water lies between the point and the sun. The surface
// above is a height field whose slope is `wave_slope`; a sun ray crossing it leaves bent by about a
// quarter of the slope (water's index 1.33), so a patch of surface lands on the point's patch scaled
// by the determinant of (I + c * Hessian), c = that bend times the depth. The light there goes as
// 1 / |det|: bright lines where the rays cross, dim between. After the usual caustic maths of
// refracted height fields; the Hessian comes from finite differences of the slope.
// How far the ray to the sun looks for water, in blocks: a low sun's ray crosses a long way of water's
// surface (depth over the sine of its height) before it leaves the water, so a short reach cut those off.
const CAUSTIC_REACH: f32 = 160.0;
// Whether water, glass or ice may lie between `p` and the sun: lit in the solid shadow map but not in the one
// with the translucent terrain drawn in. Where the maps don't reach (or there is no map), assume it may.
fn water_above(p: vec3<f32>, n: vec3<f32>) -> bool {
    if frame.has_shadow == 0u { return true; }
    let sp = shadow_position(p + n * 0.15);
    if any(sp.xy <= vec2<f32>(0.001)) || any(sp.xy >= vec2<f32>(0.999)) || sp.z <= 0.0 || sp.z >= 1.0 { return true; }
    let solid = textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
    let clear = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, sp.xy, sp.z);
    return solid > 0.0 && clear < 1.0;
}

fn caustic_gain(pos: vec3<f32>, to_light: vec3<f32>) -> vec2<f32> {
    let hit = trace_layers(pos, to_light, CAUSTIC_REACH, RAY_SOLID | RAY_TRANSLUCENT);
    if hit.distance < 0.0 || !hit.translucent || hit.fluid != 1u { return vec2<f32>(-1.0, 0.0); }
    let p = frame.camera_position.xz + hit.position.xz;
    let e = 0.15;
    let s0 = wave_slope(p, frame.time);
    let sx = (wave_slope(p + vec2<f32>(e, 0.0), frame.time) - s0) / e;
    let sz = (wave_slope(p + vec2<f32>(0.0, e), frame.time) - s0) / e;
    let c = 0.8 * hit.distance * to_light.y;
    let det = (1.0 + c * sx.x) * (1.0 + c * sz.y) - c * c * sz.x * sx.y;
    return vec2<f32>(min(1.0 / max(abs(det), 0.15), 5.0), hit.distance);
}

// Fog the pack owns (`[frame] fog = "pack"`). Light crossing a distance d of a medium keeps the share
// T = exp(-sigma * d) (Beer-Lambert) and the rest is the medium's own scattered light, here the fog's colour,
// mixed in linear light (as light scatters, not in vanilla's gamma). Three terms, multiplied:
// - a thin medium (open air, where vanilla's environment fog reaches past 300 blocks): the air's own haze,
//   sigma 0.00035 a block (about 1 % lost over 30 blocks, 16 % over 500), after NVIDIA's rain.conf scale;
// - a thick medium (water, lava, powder snow, the Nether, blindness: the environment fog ends within 300
//   blocks): sigma set so the range vanilla gives it is kept (clear up to its start, 2 % left at its end).
//   Under water red is absorbed about five times faster than green and blue (water.conf extinction
//   0.0255, 0.0053, 0.0058 a block), so the same distance leaves a teal light;
// - the render distance's fog, vanilla's linear ramp: not physics but the edge of the loaded world, which
//   has to fade out. Departure: vanilla's start and end are kept for the thick medium and the edge.
const FOG_LN_END: f32 = 3.912;
// Under water (the Overworld), after SEUS PTGI's look: a murky blue-green medium instead of vanilla's fog.
// Style: extinction four times clear sea water's (water.conf 0.0255, 0.0053, 0.0058 a block), as coastal water with
// some plankton: red is gone within 30 blocks, the view closes in a blue-green haze past about 60.
const SEA_SIGMA: vec3<f32> = vec3<f32>(0.102, 0.0212, 0.0232);
// The colour the water scatters back (its albedo), the light it scatters from the beams, a block.
const SEA_SCATTER: vec3<f32> = vec3<f32>(0.05, 0.34, 0.38);
const SEA_BEAM: f32 = 0.06;
fn sea_hash3(p: vec3<f32>) -> vec3<f32> {
    return fract(sin(vec3<f32>(dot(p, vec3<f32>(127.1, 311.7, 74.7)), dot(p, vec3<f32>(269.5, 183.3, 246.1)), dot(p, vec3<f32>(113.5, 271.9, 124.6)))) * 43758.5453);
}
fn underwater(colour: vec3<f32>, position: vec3<f32>, pixel: vec2<f32>) -> vec3<f32> {
    let d = length(position);
    let dir = position / max(d, 0.001);
    let sun_up = frame.sun_direction.y > 0.0;
    let day = smoothstep(-0.1, 0.25, frame.sun_direction.y);
    // The light the water holds: the sky's through the surface, less the deeper (darker) the camera's sky light.
    let held = mix(0.03, 1.0, day) * mix(0.25, 1.0, frame.eye_light_smooth.y) * (1.0 - 0.6 * frame.rain);
    // The depth under the surface, from the camera's sky light (water takes one level a block): the light that
    // reaches that deep has lost its red and some green on the way down, so deeper water scatters a deeper blue.
    let depth = (1.0 - frame.eye_light_smooth.y) * 15.0;
    // Swamp and mangrove water: vanilla's water fog colour there is a dark olive (swamp #232317) where the sea's is
    // blue; its greenness over blue says how much dissolved organic matter and silt the water holds. Murky water
    // absorbs blue most (CDOM) and scatters strongly, so it is brown-green and visibility drops to a few blocks.
    let murk = smoothstep(-0.1, 0.04, frame.fog_color.g - frame.fog_color.b);
    let sigma = mix(SEA_SIGMA, vec3<f32>(0.32, 0.26, 0.42), murk);
    let scatter = mix(SEA_SCATTER, vec3<f32>(0.16, 0.17, 0.08), murk) * exp(-sigma * depth * 1.5);
    let t_all = exp(-sigma * d);
    var out = colour * t_all + scatter * held * (vec3<f32>(1.0) - t_all);
    // Beams: the sun's light down through the waves, shadowed by the solid terrain (shadow map), bunched into
    // moving streaks by the surface (a ridged noise on the point taken back along the light to a level plane),
    // seen mostly toward the sun. 8 steps over the first 24 blocks, offset by blue noise (fine grain, no banding).
    if frame.has_shadow == 1u && sun_up && frame.dimension == 0 {
        let reach = min(d, 24.0);
        let l = frame.light_direction;
        let jitter = fract(textureLoad(blue, vec2<i32>(pixel) & vec2<i32>(63), 0).b + f32(frame.frame_index % 64u) * 0.61803398);
        var beam = vec3<f32>(0.0);
        for (var i = 0; i < 8; i++) {
            let t = reach * (f32(i) + jitter) / 8.0;
            let p = dir * t;
            let sp = shadow_position(p);
            // Outside the map's box (above its near plane, past its edge) nothing is known to block the light.
            let inside = all(sp.xy > vec2<f32>(0.0)) && all(sp.xy < vec2<f32>(1.0)) && sp.z > 0.0 && sp.z < 1.0;
            let lit = select(1.0, textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z), inside);
            let w = frame.camera_position + p;
            let q = w.xz - l.xz / max(l.y, 0.2) * w.y;
            let ridge = 1.0 - abs(vnoise(q * 0.35 + vec2<f32>(frame.time * 0.25, frame.time * 0.17)) * 2.0 - 1.0);
            beam += lit * pow(ridge, 6.0) * exp(-sigma * (t + 4.0));
        }
        let phase = 0.3 + 0.7 * pow(clamp(dot(dir, l), 0.0, 1.0), 3.0);
        let light_colour = sun_colour(frame.sun_direction.y) * SUN * weather_sun();
        out += light_colour * scatter * beam * (reach / 8.0) * SEA_BEAM * phase * 8.0;
    }
    // Motes: specks of matter afloat near the eye, three layers out to 6 blocks, drifting slowly, lit by the water.
    for (var k = 1; k <= 3; k++) {
        let t = f32(k) * 1.8;
        if t > d { break; }
        let drift = vec3<f32>(0.0, frame.time * 0.05, frame.time * 0.03);
        let at = (frame.camera_position + dir * t + drift) * 2.0;
        let cell = floor(at);
        let centre = (cell + 0.2 + 0.6 * sea_hash3(cell)) * 0.5 - drift - frame.camera_position;
        let along = dot(centre, dir);
        let off = length(centre - dir * along);
        let size = 0.006 * along;
        let speck = smoothstep(size, size * 0.3, off) * select(0.0, 1.0, sea_hash3(cell + 7.0).x < 0.07);
        out += scatter * held * speck * 0.8;
    }
    return out;
}
const AIR_SIGMA: f32 = 0.00035;
fn apply_fog(colour: vec3<f32>, position: vec3<f32>, pixel: vec2<f32>) -> vec3<f32> {
    if frame.eye_in == 1u && frame.dimension == 0 { return underwater(colour, position, pixel); }
    let d = length(position);
    let env = frame.fog_environment;
    let thick = env.y < 300.0;
    let thick_t = exp(-FOG_LN_END * max(d - env.x, 0.0) / max(env.y - env.x, 1.0));
    // Style: in a snowy biome the air holds ice crystals: a thicker, paler blue haze.
    let cold = 1.0 - smoothstep(-0.1, 0.25, frame.temperature);
    let medium = select(exp(-AIR_SIGMA * (1.0 + 5.0 * cold) * d), thick_t, thick);
    let per_channel = select(vec3<f32>(1.0), vec3<f32>(1.0, 0.208, 0.227), frame.eye_in == 1u && thick);
    let edge_d = max(length(position.xz), abs(position.y));
    let edge = 1.0 - clamp((edge_d - frame.fog_render.x) / max(frame.fog_render.y - frame.fog_render.x, 1.0), 0.0, 1.0);
    // Vibrant: in open air the haze is the sky's own colour toward the pixel (atmos.wgsl), so far terrain melts into
    // the horizon behind it; a thick medium and the other dimensions keep vanilla's fog colour.
    let air_c = atm_colour(normalize(position), frame.fog_color);
    let fog_c = select(mix(air_c, vec3<f32>(0.78, 0.88, 1.0) * lum(air_c) * 1.3, cold * 0.5), frame.fog_color, thick || frame.dimension != 0);
    return mix(fog_c, colour, pow(vec3<f32>(medium), per_channel) * edge);
}


fn post(input: PostInput) -> vec4<f32> {
    // The passes before this one carry the smoothed indirect light in the chain, so the world's
    // picture comes from `scene_color`.
    let world = textureLoad(scene_color, vec2<i32>(input.pixel), 0);
    if input.depth == 0.0 {
        // Under water the open view ends in the water's own colour, not vanilla's fog colour.
        if frame.eye_in == 1u && frame.dimension == 0 { return vec4<f32>(underwater(world.rgb, normalize(view_position(input.uv, 0.5)) * 1000.0, input.pixel), world.a); }
        return world;
    }
    let s = surface_at(vec2<i32>(input.pixel));
    if !s.present {
        // Water, glass, entities and particles carry no unlit surface here, but still lie in the fog.
        return vec4<f32>(apply_fog(world.rgb, view_position(input.uv, input.depth), input.pixel), world.a);
    }
    let n = s.normal;
    // The data float holds an exact integer below 2^24: adding 0.5 would tie-round odd values up from 2^23.
    let packed = u32(s.data);
    let block = surf_block(s.smoothness);
    let foliage = ((packed >> 8u) & 1u) == 1u;
    let held = vec3<f32>(f32((packed >> 9u) & 31u), f32((packed >> 14u) & 31u), f32((packed >> 19u) & 31u)) / 31.0;
    let sky = f32(packed & 255u) / 255.0;
    let colour = world.rgb;

    // Whichever of sun and moon is up lights the world.
    let to_light = frame.light_direction;
    let sun_up = frame.sun_direction.y > 0.0;
    let height = select(0.0, frame.sun_direction.y, sun_up);
    let light_colour = select(MOON * weather_moon(), sun_colour(height) * SUN * weather_sun(), sun_up);
    let facing = max(dot(n, to_light), 0.0);
    let visible = textureLoad(vis_a, vec2<i32>(input.pixel), 0).r;
    // Sky light lets the sun in; a cave's sun is vanilla's own guess.
    // Only the Overworld has a sun: the Nether and the End are lit by their emitters and their ambient.
    // Caustics under water: where the sun's ray crosses the water above, the waves bend it, and how much
    // they bend it from one spot to the next sets how the light bunches up or thins out below.
    var caustic = vec3<f32>(1.0);
    var sun_sky = smoothstep(0.0, 0.5, sky);
    if frame.dimension == 0 && facing > 0.0 && !(frame.eye_in == 1u && length(view_position(input.uv, input.depth)) > 48.0) && water_above(view_position(input.uv, input.depth), n) {
        let g = caustic_gain(view_position(input.uv, input.depth) + n * 0.02, to_light);
        if g.x >= 0.0 {
            // The game's own sky light falls a level a block of water; the sun's light falls by the water's
            // absorption (NVIDIA's water.conf extinction a block: red goes first, then green and blue).
            caustic = g.x * exp(-vec3<f32>(0.0255, 0.0053, 0.0058) * g.y * 2.0);
            sun_sky = 1.0;
        }
    }
    let sea = select(vec3<f32>(1.0), vec3<f32>(0.55, 1.15, 1.05), frame.eye_in == 1u);
    // Sunlight through stained glass takes the glass's colour.
    var glass = vec3<f32>(1.0);
    if frame.has_shadow == 1u && frame.dimension == 0 && facing > 0.0 && visible > 0.0 {
        glass = glass_filter(shadow_position(view_position(input.uv, input.depth) + n * 0.15));
    }
    let direct = light_colour * glass * caustic * facing * visible * sun_sky * select(0.0, 1.0, frame.dimension == 0);
    let up = 0.8 + 0.2 * n.y;
    let fallback = (sky_tint() * SKY * up + NIGHT_AMBIENT) * pow(sky, 1.5);
    let packed_vis = textureLoad(vis_a, vec2<i32>(input.pixel), 0);
    let age = packed_vis.b - floor(packed_vis.b / 256.0) * 256.0;
    let g = input.color.rgb;
    let fade = select(0.0, 1.0 - smoothstep(0.75 * gi_range(), gi_range(), length(view_position(input.uv, input.depth))), gi_ok(packed_vis.g));
    // Occlusion may darken, but never below what leaves and shade vanilla would keep.
    let ambient = mix(1.0, 1.25, frame.rain) * max(max(mix(fallback, g, fade), fallback * 0.55), select(CAVE_LIGHT, vec3<f32>(0.06, 0.026, 0.016), frame.dimension == -1) * select(1.0, 0.35 + 0.65 * smoothstep(0.0, 0.3, height), frame.dimension == 0));
    let hp = u32(max(s.smoothness, 0.0));
    let kind = u32(max(-s.smoothness, 0.0) + 0.5) & 3u;
    let torch_colour = select(TORCH, vec3<f32>(f32((hp >> 10u) & 31u), f32((hp >> 5u) & 31u), f32(hp & 31u)) / 31.0, ((hp >> 15u) & 1u) == 1u);
    let torch = torch_colour * TORCH_POWER * block_falloff(block) + held * TORCH_POWER;
    // Light through thin leaves: from behind the surface, and forward when looking toward the sun.
    // After MCTrace's foliage subsurface scattering (MIT).
    var through = vec3<f32>(0.0);
    if foliage && sun_up {
        let view_dir = normalize(view_position(input.uv, input.depth));
        let back = max(-dot(n, to_light), 0.0);
        let forward = pow(clamp(dot(view_dir, to_light), 0.0, 1.0), 2.2);
        through = light_colour * vec3<f32>(0.55, 0.95, 0.35) * (back * 0.65 + 0.55 * forward) * 0.8 * smoothstep(0.0, 0.5, sky);
    }
    let rays = select(vec3<f32>(0.0), light_colour * select(vec3<f32>(shafts(input.uv, input.pixel) * SHAFT), shafts_map(view_position(input.uv, input.depth), input.pixel) * SHAFT_MAP, frame.has_shadow == 1u) * (1.0 - frame.rain) * select(1.0, 0.0, frame.eye_in == 1u), sun_up);
    // Wet surfaces: darker where the sky reaches, and puddles that mirror.
    var lit_extra = vec3<f32>(0.0);
    // Snow: tiny facets of its crystals catch the sun, each from its own angle, so glints come and go as the eye
    // moves (a hash of a 1/16-block cell and the view direction). Style: brighter and denser than real glints.
    if kind == 1u && n.y > 0.5 {
        let pos = view_position(input.uv, input.depth);
        let cell = floor((frame.camera_position + pos) * 16.0);
        let v = normalize(pos);
        // An integer hash: sin() of cells thousands of blocks out loses its precision in f32.
        let c = bitcast<vec3<u32>>(vec3<i32>(cell));
        let vb = bitcast<vec3<u32>>(vec3<i32>(floor(v * 60.0)));
        var x = (c.x * 73856093u) ^ (c.y * 19349663u) ^ (c.z * 83492791u) ^ ((vb.x + vb.y * 61u + vb.z * 3721u) * 2654435761u);
        x = (x ^ (x >> 15u)) * 0x2c1b3c6du;
        x = (x ^ (x >> 12u)) * 0x297a2d39u;
        x = x ^ (x >> 15u);
        let h = f32(x & 0xffffu) / 65535.0;
        lit_extra += direct * step(0.993, h) * smoothstep(48.0, 6.0, length(pos)) * 5.0;
    }
    let wet = frame.wetness * smoothstep(0.3, 0.8, sky) * select(0.0, 1.0, frame.dimension == 0 && frame.precipitation == 1u);
    var puddle = 0.0;
    var wet_dark = 1.0 - 0.35 * wet;
    if wet > 0.01 && n.y > 0.9 {
        let world_xz = frame.camera_position.xz + view_position(input.uv, input.depth).xz;
        puddle = smoothstep(0.44, 0.56, vnoise(world_xz * 0.45) * 0.7 + vnoise(world_xz * 1.7) * 0.3) * wet;
        wet_dark = 1.0 - (0.35 + 0.3 * puddle) * wet;
    }
    // Fresh snow reflects about 80 % of the light; vanilla's texture is near 95 %, which clips to flat white in the sun.
    // Snow scatters forward, so it looks a little darker face-on (0.74) than at a grazing angle (0.84), and its
    // grain and age vary slowly across a field (a value noise, +-5 %). In shade it is lit by the sky alone, so the
    // light it gets there is the sky's blue: the ambient takes the sky's hue in proportion to how open the sky is.
    var snow_albedo = 1.0;
    var shade_light = ambient;
    if kind == 1u {
        let sp = view_position(input.uv, input.depth);
        let face = clamp(dot(-normalize(sp), n), 0.0, 1.0);
        let wxz = frame.camera_position.xz + sp.xz;
        snow_albedo = mix(0.84, 0.74, face) * (0.95 + 0.1 * vnoise(wxz * 0.21));
        let up = atm_colour(vec3<f32>(0.0, 1.0, 0.0), frame.sky_color.rgb);
        let hue = up / max(max(up.r, max(up.g, up.b)), 0.001);
        shade_light = ambient * mix(vec3<f32>(1.0), hue, 0.7 * sky * select(0.0, 1.0, frame.dimension == 0));
    }
    var lit = colour * snow_albedo * wet_dark * (direct + shade_light + torch + through) * sea * exposure() + rays + lit_extra * exposure();
    // Packed and blue ice: a smooth face, Fresnel's mirror of the sky (no ray) and the sun's highlight.
    if kind == 2u {
        let v = normalize(view_position(input.uv, input.depth));
        let r = reflect(v, n);
        let c = clamp(dot(-v, n), 0.0, 1.0);
        let fres = 0.02 + 0.98 * pow(1.0 - c, 5.0);
        // Depth: light seen in packed ice went into it and back out, along the path bent by its index (1.31);
        // the slanter the view, the longer that path, and the more red it loses (Beer-Lambert, about one block
        // of ice at normal view). So the ice turns deeper blue toward the edges of a field.
        let cos_t = sqrt(1.0 - (1.0 - c * c) / (1.31 * 1.31));
        lit *= exp(-vec3<f32>(0.30, 0.06, 0.02) * 2.0 / cos_t);
        lit = mix(lit, atm_colour(r, frame.sky_color.rgb) * ambient * 2.0, clamp(fres + 0.05, 0.0, 0.6));
        lit += direct * pow(max(dot(r, to_light), 0.0), 120.0) * 3.0 * exposure();
    }
    if puddle > 0.02 {
        let pos = view_position(input.uv, input.depth);
        let view_dir = normalize(pos);
        // Rain rings stir the puddle's mirror.
        let ring = rain_ripple(frame.camera_position.xz + pos.xz) * wet;
        let away = reflect(view_dir, normalize(n + vec3<f32>(-ring.x, 0.0, -ring.y)));
        let hit = trace(pos + n * 0.02, away, 64.0);
        var seen = frame.sky_color.rgb;
        if hit.distance >= 0.0 {
            let sk = hit.light.y;
            seen = hit.albedo.rgb * hit.shaded_tint.rgb * (0.15 + 0.85 * sk * sk) * 0.8;
        }
        let c = clamp(dot(-view_dir, n), 0.0, 1.0);
        let fres = 0.02 + 0.98 * pow(1.0 - c, 5.0);
        lit = mix(lit, seen * ambient * 2.0, clamp(fres + 0.25, 0.0, 0.8) * puddle);
    }
    // Wet surfaces outside the puddles: a water film's Fresnel reflection of the rain sky, no ray (the film
    // is rough, so only the sky's broad light shows). Style: stronger than a real film, so wet ground gleams.
    if wet > 0.01 && puddle < 0.98 {
        let view_dir = normalize(view_position(input.uv, input.depth));
        let c = clamp(dot(-view_dir, n), 0.0, 1.0);
        let fres = 0.02 + 0.98 * pow(1.0 - c, 5.0);
        let film = atm_colour(reflect(view_dir, n), frame.sky_color.rgb) * ambient * 2.0;
        lit = mix(lit, film, clamp(fres + 0.03, 0.0, 0.35) * wet * (1.0 - puddle) * select(0.5, 1.0, n.y > 0.9));
    }
    // Rain and thunder haze, after NVIDIA's rain.conf and thunder.conf (transmittance 0.996 and 0.97
    // over 10 blocks: 0.000401 and 0.003046 a block). Vanilla's own fog stays the engine's.
    let reach = length(view_position(input.uv, input.depth));
    let haze = exp(-reach * frame.rain * mix(0.000401, 0.003046, frame.thunder));
    let pop = mix(vec3<f32>(lum(lit)), lit, SATURATION);
    return vec4<f32>(apply_fog(mix(frame.fog_color, pop, haze), view_position(input.uv, input.depth), input.pixel), input.color.a);
}
