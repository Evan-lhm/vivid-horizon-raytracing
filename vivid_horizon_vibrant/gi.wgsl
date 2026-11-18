// Indirect light: for each pixel, rays in a cosine-weighted hemisphere around the surface. A ray
// that leaves the scene sees the open sky; one that hits terrain brings back that terrain's colour
// under the sun and sky (no second ray: its own sky light stands in for the shadow). That gives
// sky occlusion and colour bleeding in one. Averaged with last frame's answer for the same point.
// Writes `gi_a` (rgb: the light arriving, black where it holds nothing). The surface's distance, face
// and age live in `vis_a`: a pack target's alpha is always 1, so nothing is kept in it.
// The pass runs at half the world's size (scale 0.5): `input.pixel` and `input.uv` are the half-size
// target's; the full-size texel of the same point is `full`. Two samples a texel, a half of the rays of
// one sample a pixel at full size.
const SAMPLES: u32 = 4u;
const BOUNCE_REACH: f32 = 64.0;
// Past this many blocks the post pass keeps the plain ambient: far terrain has no light data to bounce.
const GI_RANGE: f32 = 192.0;
// Under water the indirect light stops at 24 blocks (fading out from 18): past that the water's own scattered
// light covers most of what a bounce would add. A cost cut, not physics.
fn gi_range() -> f32 { return select(GI_RANGE, 24.0, frame.eye_in == 1u && frame.dimension == 0); }
// How strongly emitters light their surroundings through the indirect rays.
const EMISSION: f32 = 22.0;
const SKY: f32 = 0.96;
// Vibrant: as post.wgsl (0.5).
const SKY_TINT: f32 = 0.5;
const SUN: f32 = 0.55;
// Style (Vibrant): the moon twice the base pack's, so a moonlit night reads (a real full moon is about 1/400000 of
// the sun, far darker than this); caves, which the moon doesn't reach, are unchanged.
const MOON: vec3<f32> = vec3<f32>(0.036, 0.072, 0.17);
const NIGHT_AMBIENT: vec3<f32> = vec3<f32>(0.01, 0.015, 0.03);
// PTGI keeps 60 frames (HISTORY_SAMPLE_COUNT); RTX Remix's ReSTIR GI keeps 500 ms, 60 frames at 120 fps.
const BLEND: f32 = 0.0167;
const FIREFLY: f32 = 16.0;
const FIREFLY_FLOOR: f32 = 1.0;
// One sample's most light (luminance): a ray that finds a lamp is worth 20 or more, which at four samples a
// pixel shows as a bright dot that slides over the wall as the view moves.
const SAMPLE_CAP: f32 = 12.0;

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

// Two random numbers for a pixel from the blue-noise texture, shifted each frame and each use by the R2
// sequence (a golden-ratio step), so successive frames add up to a blue distribution over time: the error
// of a sample is spread into fine grain the filters remove, not into blotches.
fn blue2(pixel: vec2<f32>, step: f32) -> vec2<f32> {
    let c = textureLoad(blue, vec2<i32>(pixel) & vec2<i32>(63), 0).rg;
    return fract(c + vec2<f32>(0.7548776662, 0.5698402910) * step);
}

fn ign(p: vec2<f32>, k: f32) -> f32 {
    return fract(52.9829189 * fract(dot(p + k, vec2<f32>(0.06711056, 0.00583715))));
}

// The sky's light arriving from direction `d`.
fn sky_light(d: vec3<f32>) -> vec3<f32> {
    // The Nether and the End have no sky: what a ray that leaves the scene sees is their own ambient, the
    // Nether's fog colour (the red haze of the lava and the netherrack) and the End's purple void
    // (NVIDIA SkyRenderer's constant End radiance, scaled up to the pack's units).
    if frame.dimension == -1 { return max(frame.fog_color, vec3<f32>(0.04, 0.012, 0.004)) * 1.4; }
    if frame.dimension == 1 { return vec3<f32>(0.17, 0.12, 0.24); }
    let sky = sky_tint();
    return sky * SKY * (0.75 + 0.25 * d.y) + NIGHT_AMBIENT;
}

// Rain and thunder dim the sun and moon, after NVIDIA's rtx-remix-minecraft (LightManager:
// sun 30 -> 0.075 in rain, 0.03 in thunder; moon 0.06 -> 0.0225, 0.0375), by vanilla's gradients.
fn weather_sun() -> f32 { return mix(1.0, mix(0.075, 0.03, frame.thunder) / 30.0, frame.rain); }
fn weather_moon() -> f32 { return mix(1.0, mix(0.0225, 0.0375, frame.thunder) / 0.06, frame.rain); }
fn light_of_day() -> vec3<f32> {
    let up = frame.sun_direction.y > 0.0;
    return select(MOON * weather_moon(), sun_colour(max(frame.sun_direction.y, 0.0)) * SUN * weather_sun(), up);
}

// A light path, as in PTGI's bounce loop: from the surface, a ray in a cosine-weighted direction;
// at what it hits, add the hit's own glow and the sun that reaches it (a shadow ray: PTGI's next
// event estimation), then go on in a new direction with the hit's colour carried along. A ray
// that leaves the scene brings the sky. The last bounce has no ray left to send, so the hit's own
// sky light stands in for what it would have seen.
// Two traced bounces: the third (1.9 ms) changed no view of the test lot beyond the run-to-run noise; the
// last bounce still adds its hit's own sky light for what it would have seen.
const BOUNCES: u32 = 2u;

fn cosine_dir(n: vec3<f32>, u1: f32, u2: f32) -> vec3<f32> {
    let t = normalize(cross(n, select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(n.y) > 0.9)));
    let bt = cross(n, t);
    let r = sqrt(u1);
    let phi = 6.2831853 * u2;
    return normalize(t * (r * cos(phi)) + bt * (r * sin(phi)) + n * sqrt(1.0 - u1));
}

// How much of the sun's light gets through to `origin` along `dir`: 0 behind terrain, and a share behind
// water, glass and ice (a fluid keeps 35 %, other layers what their alpha lets through), three layers deep.
fn sun_through(origin: vec3<f32>, dir: vec3<f32>, reach: f32) -> f32 {
    var o = origin;
    var t = 1.0;
    for (var i = 0; i < 3; i++) {
        let hit = trace_layers(o, dir, reach, RAY_SOLID | RAY_TRANSLUCENT);
        if hit.distance < 0.0 { return t; }
        if !hit.translucent { return 0.0; }
        t *= 1.0 - select(hit.albedo.a, 0.65, hit.fluid == 1u);
        o = hit.position + dir * 0.02;
    }
    return t;
}

// The sun at a bounce hit, from the engine's shadow map: the same visibility the ray finds (solid terrain and
// cut-outs in `shadow_map`; water, glass and ice in `shadow_map_translucent`, which let through what
// `sun_through` lets through, 35 % for a fluid and 1 - alpha for the rest, one layer instead of three),
// at the map's resolution (2048 texels over the map's 128-block reach), which the indirect light, averaged and
// smoothed, does not show. -1 where the hit lies outside the map: the caller traces the ray then.
fn sun_map(p: vec3<f32>, n: vec3<f32>) -> f32 {
    if frame.has_shadow == 0u { return -1.0; }
    // About one texel along the normal, so a face doesn't shadow itself.
    let sp = shadow_position(p + n * 0.15);
    if any(sp.xy <= vec2<f32>(0.001)) || any(sp.xy >= vec2<f32>(0.999)) || sp.z <= 0.0 || sp.z >= 1.0 { return -1.0; }
    let solid = textureSampleCompareLevel(shadow_map, shadow_sampler, sp.xy, sp.z);
    if solid <= 0.0 { return 0.0; }
    let clear = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, sp.xy, sp.z);
    let c = textureLoad(shadow_color, vec2<i32>(sp.xy * vec2<f32>(textureDimensions(shadow_color))), 0);
    let cover = select(c.a, 0.65, c.a > 0.995);
    return solid * mix(1.0 - cover, 1.0, clear);
}

fn path(start: vec3<f32>, first: vec3<f32>, day: vec3<f32>, pixel: vec2<f32>, k: f32) -> vec3<f32> {
    var o = start;
    var d = first;
    var weight = vec3<f32>(1.0);
    var light = vec3<f32>(0.0);
    // One written trace call (each written call to a trace costs about 0.13 ms a frame, Ducky's measure): a ray
    // that meets water, glass or ice adds that layer's share and goes on through it, on the solid layer only, in
    // the same loop; then the bounce goes on as before.
    var layers = RAY_SOLID | RAY_TRANSLUCENT;
    var b = 0u;
    for (var s = 0u; s < BOUNCES * 2u; s++) {
        let hit = trace_layers(o, d, BOUNCE_REACH, layers);
        // Water, glass and ice take some of the light and let the rest through.
        if hit.distance >= 0.0 && hit.translucent {
            let cover = select(hit.albedo.a, 0.65, hit.fluid == 1u);
            let sky = hit.light.y;
            light += weight * cover * hit.albedo.rgb * min(hit.shaded_tint.rgb, vec3<f32>(1.0)) * sky_light(hit.normal) * pow(sky, 1.5);
            weight *= (1.0 - cover);
            o = hit.position + d * 0.02;
            layers = RAY_SOLID;
            continue;
        }
        layers = RAY_SOLID | RAY_TRANSLUCENT;
        if hit.distance < 0.0 {
            light += weight * sky_light(d);
            break;
        }
        let sky = hit.light.y;
        let albedo = hit.albedo.rgb * min(hit.shaded_tint.rgb, vec3<f32>(1.0));
        // A block that shines lights what sees it, in its own colour (PTGI's emitters).
        light += weight * hit.albedo.rgb * hit.emission * EMISSION;
        let spot = hit.position + hit.normal * 0.02;
        // The sun, through a shadow ray where this hit has sky light to receive it.
        let facing = max(dot(hit.normal, frame.light_direction), 0.0);
        if facing > 0.0 && sky > 0.0 && frame.dimension == 0 {
            var through = sun_map(hit.position, hit.normal);
            if through < 0.0 { through = sun_through(spot, frame.light_direction, 512.0); }
            light += weight * albedo * day * through * facing * smoothstep(0.0, 0.5, sky);
        }
        if b + 1u < BOUNCES {
            weight *= albedo;
            let u = blue2(pixel, k + f32(b + 1u) * 29.0);
            d = cosine_dir(hit.normal, u.x, u.y);
            o = spot;
            b++;
        } else {
            light += weight * albedo * sky_light(hit.normal) * pow(sky, 1.5);
            break;
        }
    }
    return light;
}

// Which of the six block faces a normal is: 1 to 6, 0 is kept for "no surface". Two faces meeting
// at an edge have nearly the same depth, so depth alone lets one's light slide onto the other
// when the camera moves.
fn face_id(n: vec3<f32>) -> f32 {
    let a = abs(n);
    var i = 0.0;
    if a.y >= a.x && a.y >= a.z { i = select(2.0, 3.0, n.y < 0.0); }
    else if a.x >= a.z { i = select(0.0, 1.0, n.x < 0.0); }
    else { i = select(4.0, 5.0, n.z < 0.0); }
    return i + 1.0;
}

// Eye adaptation, after PTGI's `getMaxBrightness` (eyeBrightnessSmooth) and NVIDIA's auto-exposure:
// how bright the light is where the player looks, 0 (a cave) to 1 (open sky or a torch's room),
// smoothed over time so stepping into the dark dims the picture and the eye then adapts. The pack has
// no eye position, so it takes the block and sky light of a grid of the surfaces on screen. It lives
// in the top-left pixel of `gi_a` (a target's alpha is always 1), stored as 1 + brightness so a zero
// means "nothing yet"; last frame's value comes from `gi_b`, and the post pass reads this one.
// NVIDIA's rtx.autoExposure.autoExposureSpeed for Minecraft (rtx.conf), in units a second.
const ADAPT_SPEED: f32 = 10.0;
// rtx.autoExposure.centerMeteringSize: how far from the centre a surface still counts.
const METER_SIZE: f32 = 0.75;
fn eye_brightness() -> f32 {
    var sum = 0.0;
    var count = 0.0;
    for (var y = 0; y < 6; y++) {
        for (var x = 0; x < 8; x++) {
            let q = vec2<i32>((vec2<f32>(f32(x), f32(y)) + 0.5) / vec2<f32>(8.0, 6.0) * frame.resolution);
            let s = surface_at(q);
            if !s.present { continue; }
            let packed = u32(s.data);
            // Centre metering, as auto_exposure_histogram.comp.slang's centerMeteringWeight.
            let uv = (vec2<f32>(f32(x), f32(y)) + 0.5) / vec2<f32>(8.0, 6.0);
            let aspect = frame.resolution.x / frame.resolution.y;
            let w = 1.0 - clamp(length((uv - 0.5) / vec2<f32>(1.0, aspect)) / METER_SIZE, 0.0, 1.0);
            sum += w * max(surf_block(s.smoothness), f32(packed & 255u) / 255.0);
            count += w;
        }
    }
    // Only sky in view: outdoors.
    return select(1.0, sum / count, count > 0.0);
}

fn post(input: PostInput) -> vec4<f32> {
    let texel = vec2<i32>(input.pixel);
    if texel.x == 0 && texel.y == 0 {
        let now = eye_brightness();
        let before = textureLoad(gi_b, texel, 0).r - 1.0;
        return vec4<f32>(1.0 + select(mix(before, now, 1.0 - exp2(-ADAPT_SPEED * frame.delta_time)), now, before < 0.0), 0.0, 0.0, 1.0);
    }
    let full = vec2<i32>(input.uv * frame.resolution);
    if input.depth == 0.0 { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    let s = surface_at(full);
    if !s.present { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    let n = s.normal;
    let position = view_position(input.uv, input.depth);
    let dist = length(position);
    if frame.has_ray_tracing == 0u || frame.dimension > 1 || frame.dimension < -1 || max(abs(position.x), abs(position.z)) >= frame.ray_distance || dist >= gi_range() {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let t = normalize(cross(n, select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(n.y) > 0.9)));
    let bt = cross(n, t);
    let origin = position + n * (0.01 + 0.002 * dist);
    let day = light_of_day();
    // A pixel whose history is old already holds the average of many frames: half the samples are enough
    // there, and a young one (just uncovered, or moving) gets all of them.
    let age_now = textureLoad(vis_a, full, 0).b;
    let count = select(SAMPLES, SAMPLES / 2u, age_now - floor(age_now / 256.0) * 256.0 > 16.0);
    var sum = vec3<f32>(0.0);
    for (var i = 0u; i < count; i++) {
        let k = f32(frame.frame_index % 64u) * 5.588 + f32(i) * 19.7;
        let u0 = blue2(input.pixel, k);
        let d = cosine_dir(n, u0.x, u0.y);
        let one = path(origin, d, day, input.pixel, k);
        sum += one * min(1.0, SAMPLE_CAP / max(dot(one, vec3<f32>(0.2126, 0.7152, 0.0722)), 0.0001));
    }
    let now = sum / f32(count);
    var out_v = now;
    // This frame's age for the pixel comes from the shadow pass; last frame's face and distance
    // from `vis_b`, which this pass sees before the shadow's keep pass has overwritten it.
    let packed = textureLoad(vis_a, full, 0).b;
    let age = max(packed - floor(packed / 256.0) * 256.0, 1.0);
    let clip = frame.previous_view_projection * vec4<f32>(position + frame.camera_motion, 1.0);
    if clip.w > 0.0 && frame.delta_time > 0.0 {
        let ndc = clip.xy / clip.w;
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        if all(uv > vec2<f32>(0.0)) && all(uv < vec2<f32>(1.0)) {
            let at = vec2<i32>(uv * frame.resolution);
            let hv = textureLoad(vis_b, at, 0);
            if floor(hv.b / 256.0) == face_id(n) && hv.g < gi_range() && abs(hv.g - dist) < 0.05 * dist + 0.1 {
                // A lone bright sample (a ray that found a lamp) is held to a multiple of what
                // the pixel has gathered, so it spreads over frames instead of flashing.
                // Last frame's light at the exact point, interpolated between the four half-size texels around
                // it. Taking the nearest texel moved the light by up to two pixels a frame, and over the ~60
                // frames the history spans those roundings added up: lamp and lava light slid over the ground
                // as the camera moved.
                let hs = vec2<f32>(textureDimensions(gi_b));
                let hp = uv * hs - 0.5;
                let h0 = vec2<i32>(floor(hp));
                let hf = hp - floor(hp);
                let hm = vec2<i32>(hs) - vec2<i32>(1);
                let hist = mix(
                    mix(textureLoad(gi_b, clamp(h0, vec2<i32>(0), hm), 0).rgb, textureLoad(gi_b, clamp(h0 + vec2<i32>(1, 0), vec2<i32>(0), hm), 0).rgb, hf.x),
                    mix(textureLoad(gi_b, clamp(h0 + vec2<i32>(0, 1), vec2<i32>(0), hm), 0).rgb, textureLoad(gi_b, clamp(h0 + vec2<i32>(1, 1), vec2<i32>(0), hm), 0).rgb, hf.x),
                    hf.y);
                let w = vec3<f32>(0.2126, 0.7152, 0.0722);
                let cap = FIREFLY * dot(hist, w) + FIREFLY_FLOOR;
                let held = now * min(1.0, cap / max(dot(now, w), 0.0001));
                out_v = mix(hist, select(now, held, age > 4.0), max(1.0 / age, BLEND));
            }
        }
    }
    return vec4<f32>(out_v, 1.0);
}
