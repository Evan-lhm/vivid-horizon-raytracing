// Hands the post pass the surface unlit: its colour without vanilla's light or face shade, its
// normal, and its block and sky light packed into the surface's one float. The light is the
// post pass's, so the whole frame follows one model.

// A block's own glow, in its own colour.
const GLOW: f32 = 1.5;

fn material(input: MaterialInput) -> Surface {
    if input.translucent { return translucent(input); }
    // The colour alone (biome tint) and vanilla's ambient occlusion; not vanilla's face shade: the sun's own angle
    // shades the face. (Before API 0.2's last batch the tint carried the shade, divided out here by vanilla's gamma
    // values, which left north and south faces at 76 % and east and west at 54 % of their colour.)
    let tint = min(input.tint.rgb * input.ao, vec3<f32>(1.0));
    let colour = input.albedo.rgb * tint;
    // Block and sky light, 8 bits each. Vanilla's levels are whole numbers per block, but smooth lighting blends
    // them across each face; rounding back to 16 levels cut those gradients into flat steps (polygons of light
    // around every torch), so the blend is kept at 256 levels.
    let levels = vec2<u32>(clamp(input.light, vec2<f32>(0.0), vec2<f32>(1.0)) * 255.0 + 0.5);
    // Foliage is the manifest's `[[tags]]` entry, bit 0: leaves, grass and plants let light through.
    let foliage = (input.tags & 1u) != 0u;
    // The surface's second float (exact: under 2^24): the block light (bits 16 to 23), a flag (bit 15) where a
    // coloured source reaches (the manifest's `[[lights]]`) and its colour, brightest channel 1, 5 bits a channel.
    let lc = block_light_color(input.position);
    let hue = vec3<u32>(clamp(lc.rgb / max(max(lc.r, max(lc.g, lc.b)), 0.001), vec3<f32>(0.0), vec3<f32>(1.0)) * 31.0 + 0.5);
    let packed_hue = f32(levels.x * 65536u + select(0u, 32768u + hue.x * 1024u + hue.y * 32u + hue.z, lc.a > 0.0));
    let plant = (input.tags & 2u) != 0u;
    // The frame's coloured lights here (a torch in the hand or on the ground, dynamic lights on):
    // 5 bits a channel above the levels (bits 9 to 23, exact in the float).
    let held = vec3<u32>(clamp(input.colored_light, vec3<f32>(0.0), vec3<f32>(1.0)) * 31.0 + 0.5);
    let held_bits = (held.x + held.y * 32u + held.z * 1024u) * 512u;
    // Snow (1) and packed ice (2) for the post pass, as the hue float's negative values (with the block light).
    // shortcut: a snow or ice face lit by a block light loses that light's colour (it takes the torch's); use a
    // free bit if one comes.
    let kind = select(select(0.0, 2.0, (input.tags & 16u) != 0u), 1.0, (input.tags & 4u) != 0u);
    set_surface(select(input.normal, vec3<f32>(0.0, 1.0, 0.0), plant), select(packed_hue, -(kind + 4.0 * f32(levels.x)), kind > 0.0), f32(levels.y + select(0u, 256u, foliage) + held_bits));
    // Only the bright texels of a glowing block glow (a torch's flame, not its stick).
    let glow = colour * input.emission * GLOW * smoothstep(0.35, 0.8, dot(colour, vec3<f32>(0.2126, 0.7152, 0.0722)));
    return Surface(vec4<f32>(colour + glow, input.albedo.a));
}

// How far a reflected ray looks, in blocks.
const REACH: f32 = 128.0;

// Water, glass and ice are blended over the picture and keep vanilla's light. Water also mirrors
// what a ray off its surface hits, more where the view is grazing (Schlick's Fresnel): the
// terrain's colour under its own sky light, or the sky's where the ray misses.
// Waves: four travelling sines in different directions and scales, summed as a slope. Small,
// so the surface ripples without breaking the block's look.
// `dist`: the distance to the eye. A wave much finer than a pixel there only shimmers, so each wave fades with
// k times the distance (a pixel spans about dist / 600 blocks): far water keeps its long swell, near water all of it.
fn wave_slope_at(p: vec2<f32>, t: f32, dist: f32) -> vec2<f32> {
    var slope = vec2<f32>(0.0);
    for (var i = 0; i < 14; i++) {
        let fi = f32(i);
        let angle = fi * 2.39996 + 0.7;
        let d = vec2<f32>(cos(angle), sin(angle));
        let k = 0.8 * pow(1.28, fi);
        slope += d * 0.03 * pow(k, -0.55) * cos(dot(p, d) * k + t * 1.1 * sqrt(k) + fi * 1.7) * exp(-k * dist * 0.004);
    }
    return slope;
}
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

fn translucent(input: MaterialInput) -> Surface {
    let lit = input.albedo * vec4<f32>(input.shaded_tint.rgb * input.lightmap, input.shaded_tint.a);
    if frame.has_ray_tracing == 0u || frame.dimension != 0 { return Surface(lit); }
    if input.fluid != 1u {
        // Glass, stained glass and ice mirror what a ray off them hits, by Schlick's Fresnel (F0 0.04),
        // over the colour vanilla gives them: a window shows the sky and the room across it.
        let view = normalize(input.position);
        if dot(view, input.normal) > 0.0 { return Surface(lit); }
        let away = reflect(view, input.normal);
        let hit = trace(input.position + input.normal * 0.01, away, 96.0);
        var seen = frame.sky_color.rgb;
        if hit.distance >= 0.0 {
            let sky = hit.light.y;
            seen = hit.albedo.rgb * hit.shaded_tint.rgb * (0.15 + 0.85 * sky * sky) * 0.8;
        }
        let c = clamp(dot(-view, input.normal), 0.0, 1.0);
        let fres = 0.04 + 0.96 * pow(1.0 - c, 5.0);
        if (input.tags & 8u) != 0u {
            // Clear ice: what lies behind, seen along the ray bent by ice's index (1.31). Over the thickness
            // crossed, ice absorbs red first (Beer-Lambert, per block: ice and water absorb alike, a little
            // stronger here) and scatters the blue it keeps back to the eye, so thin ice is clear and thick ice
            // deep blue. shortcut: the whole path to the hit counts as ice (and the water under a frozen lake).
            let bent = refract(view, input.normal, 1.0 / 1.31);
            let under = trace(input.position - input.normal * 0.01, bent, 32.0);
            let d = select(32.0, under.distance, under.distance >= 0.0);
            let kept = exp(-d * vec3<f32>(0.30, 0.06, 0.02));
            var behind = vec3<f32>(0.0);
            if under.distance >= 0.0 { behind = under.albedo.rgb * under.shaded_tint.rgb * input.lightmap * kept; }
            let deep = vec3<f32>(0.05, 0.22, 0.5) * input.lightmap * (1.0 - exp(-d * 0.08));
            let body = mix(behind + deep, vec3<f32>(0.35, 0.55, 0.8) * input.lightmap, 0.04);
            return Surface(vec4<f32>(mix(body, seen * input.lightmap, fres * 0.9), 1.0));
        }
        return Surface(vec4<f32>(mix(lit.rgb, seen * input.lightmap, fres * 0.9), lit.a + (1.0 - lit.a) * fres));
    }
    let view = normalize(input.position);
    // The surface seen from below (the camera under water). Light leaving water bends away from the normal
    // (n = 1.33 to 1), so the sky shows only inside a cone of 48.6 degrees around straight up (Snell's window),
    // bright and squeezed; outside it the surface is a perfect mirror of the water below (total internal
    // reflection). The waves wobble the window's edge. The sky through it is the sky's colour along the bent ray
    // (terrain above the water is not traced: shortcut, a tree over a pond shows sky).
    if frame.eye_in == 1u && input.normal.y < -0.9 {
        // Half the waves' slope: seen from below, the full slope broke the surface into hard facets.
        let ws = wave_slope(frame.camera_position.xz + input.position.xz, frame.time) * 0.5;
        let down = normalize(vec3<f32>(ws.x, -1.0, ws.y));
        let out_dir = refract(view, down, 1.33);
        let total = dot(out_dir, out_dir) < 0.5;
        // One ray: up through the window (trees and banks above the water), or back down where the surface mirrors.
        let ray = select(out_dir, reflect(view, down), total);
        let hit = trace(input.position + ray * 0.02, ray, 64.0);
        // The water's own colour where the mirrored ray finds no floor (post.wgsl fogs it further).
        let murk = vec3<f32>(0.03, 0.2, 0.22) * input.lightmap;
        if total {
            var mirrored = murk;
            if hit.distance >= 0.0 {
                mirrored = hit.albedo.rgb * hit.shaded_tint.rgb * input.lightmap * exp(-hit.distance * vec3<f32>(0.102, 0.0212, 0.0232));
            }
            return Surface(vec4<f32>(mirrored, 1.0));
        }
        // Style: the window a little brighter than the sky itself, as SEUS's surface seen from under water.
        var above = atm_colour(out_dir, frame.sky_color) * 1.4;
        if hit.distance >= 0.0 {
            let sky = hit.light.y;
            above = hit.albedo.rgb * hit.shaded_tint.rgb * (0.15 + 0.85 * sky * sky);
        }
        let c = clamp(dot(out_dir, vec3<f32>(0.0, 1.0, 0.0)), 0.0, 1.0);
        let fres = 0.02 + 0.98 * pow(1.0 - c, 5.0);
        return Surface(vec4<f32>(mix(above, murk, fres), 1.0));
    }
    var normal = input.normal;
    if normal.y > 0.9 {
        let at = frame.camera_position.xz + input.position.xz;
        // Rain rings where the water sees the sky.
        let w = wave_slope_at(at, frame.time, length(input.position)) + rain_ripple(at) * smoothstep(0.6, 0.95, input.light.y);
        normal = normalize(vec3<f32>(-w.x, 1.0, -w.y));
    }
    if dot(view, normal) > 0.0 { return Surface(lit); }
    let away = reflect(view, normal);
    let hit = trace(input.position + input.normal * 0.01, away, REACH);
    // Where the mirrored ray misses the terrain: the pack's own sky along it (air, stars, clouds), as the sky stage
    // draws it, not vanilla's flat sky colour.
    var seen = clouds(away, sky_colour(away, frame.sky_color.rgb) + night_sky(away));
    // The sun on the waves: its disc (the pack's, 0.026 rad), and around it the glitter of the many facets
    // that each tilt toward the sun (a lobe as wide as the waves' slopes, about 0.1 rad); not in rain.
    let cs = dot(away, frame.sun_direction);
    let sun_on = select(0.0, 1.0, frame.sun_direction.y > 0.0) * (1.0 - frame.rain) * sk_sun_colour(max(frame.sun_direction.y, 0.005));
    seen += sun_on * (smoothstep(cos(0.034), cos(0.022), cs) * 6.0 + pow(max(cs, 0.0), 300.0) * 1.2);
    if hit.distance >= 0.0 {
        let sky = hit.light.y;
        seen = hit.albedo.rgb * hit.shaded_tint.rgb * (0.15 + 0.85 * sky * sky) * 0.8;
    }
    // What the water lets through: the ray bends toward the normal (n = 1.33) and meets the floor. The floor
    // is lit by light that came down through the water (its vertical depth) and is seen back along the bent ray,
    // both losing light by Beer-Lambert: red first, then green, so shallow water shows the floor in its own colour
    // and deep water goes dark blue before the floor. The water also scatters light back to the eye along the way
    // (in-scattering, 1 - exp(-sigma_t d)).
    // Media, from the biome's water colour (vanilla's tint; the API gives no biome id): clear water (absorption a
    // block about 0.3, 0.05, 0.035: red goes in a few blocks) and murky swamp water, whose dissolved organic
    // matter (CDOM) absorbs blue most and whose particles scatter strongly: brown-green, short visibility.
    // Style: absorption about 0.6 times real clear water's red per metre is kept higher in green and blue
    // (Minecraft water reads blue-green), and the scattered colour takes the biome's tint.
    let bent = refract(view, normal, 1.0 / 1.33);
    let under = trace(input.position - input.normal * 0.01, bent, 64.0);
    let tint = input.tint.rgb;
    // A wide ramp on the biome's tint (the engine blends it between biomes per vertex), so the sea turns into
    // swamp water gradually: ocean tints sit at g - b = -0.25 to -0.5, swamp and mangrove at +0.07 to +0.09.
    let murk = smoothstep(-0.22, 0.08, tint.g - tint.b);
    var sigma_a = mix(vec3<f32>(0.30, 0.05, 0.035), vec3<f32>(0.40, 0.28, 0.55), murk);
    let sigma_s = mix(0.015, 0.35, murk);
    let d = select(48.0, under.distance, under.distance >= 0.0);
    let depth_v = d * max(-bent.y, 0.05);
    var floor_colour = vec3<f32>(0.0);
    if under.distance >= 0.0 {
        floor_colour = under.albedo.rgb * under.shaded_tint.rgb;
        // Seagrass and kelp on the floor: their chlorophyll in the water around absorbs red and blue and leaves
        // green, so a weedy floor greens the water over it.
        let algae = smoothstep(0.05, 0.2, floor_colour.g - max(floor_colour.r, floor_colour.b));
        sigma_a += vec3<f32>(0.05, 0.0, 0.08) * algae;
    }
    let sigma_t = sigma_a + vec3<f32>(sigma_s);
    // Sunlight focused by the waves on the floor (caustics): where the surface above curves inward the light
    // bunches. The divergence of the wave slope at the floor's point, times the depth, scales the light there.
    var caustic = 1.0;
    let sun_amount = select(0.0, 1.0, frame.sun_direction.y > 0.0) * (1.0 - frame.rain) * input.light.y * (1.0 - murk);
    if under.distance >= 0.0 && sun_amount > 0.01 {
        let fp = frame.camera_position.xz + input.position.xz + bent.xz * d;
        let e = 0.2;
        let sx = wave_slope(fp + vec2<f32>(e, 0.0), frame.time) - wave_slope(fp - vec2<f32>(e, 0.0), frame.time);
        let sy = wave_slope(fp + vec2<f32>(0.0, e), frame.time) - wave_slope(fp - vec2<f32>(0.0, e), frame.time);
        let div = (sx.x + sy.y) / (2.0 * e);
        // Faded in over the first half block of depth (the waves can't focus light over a film of water) and on
        // grazing views, where the bent ray's floor point jumps with each wave and the pattern breaks into noise.
        let settle = smoothstep(0.1, 0.6, depth_v) * smoothstep(0.15, 0.4, -bent.y);
        caustic = mix(1.0, clamp(1.0 - div * min(depth_v, 6.0) * 1.5, 0.5, 1.8), sun_amount * settle);
    }
    let reach_floor = exp(-sigma_t * (d + depth_v));
    let scatter_colour = mix(tint * vec3<f32>(0.3, 0.42, 0.5), vec3<f32>(0.22, 0.24, 0.13), murk) * (0.7 + 0.5 * sun_amount);
    var through = floor_colour * caustic * reach_floor * input.lightmap
        + scatter_colour * input.lightmap * vec3<f32>(sigma_s) / sigma_t * (vec3<f32>(1.0) - exp(-sigma_t * d));
    var cover = 1.0;
    // Foam: rare, thin and see-through, only right at the edge (the floor within a quarter block) where a drifting
    // noise peaks, mixed into the water's colour rather than painted over it.
    if under.distance >= 0.0 {
        let at = frame.camera_position.xz + input.position.xz;
        let froth = sk_vnoise(at * 2.2 + vec2<f32>(frame.time * 0.3, 0.0)) * 0.6 + sk_vnoise(at * 5.1 - frame.time * 0.2) * 0.4;
        let foam = smoothstep(0.25, 0.03, under.distance) * smoothstep(0.62, 0.8, froth) * smoothstep(0.6, 1.0, input.normal.y) * (1.0 - murk);
        through = mix(through, mix(through, vec3<f32>(0.8, 0.85, 0.88) * input.lightmap, 0.5), foam * 0.6);
    }
    let cos_theta = clamp(dot(-view, normal), 0.0, 1.0);
    let fresnel = 0.02 + 0.98 * pow(1.0 - cos_theta, 5.0);
    let mirror = clamp(fresnel * 1.0, 0.0, 0.85);
    // In the water's own light, so the mirror doesn't glow at night.
    return Surface(vec4<f32>(mix(through, seen * input.lightmap, mirror), cover + (1.0 - cover) * fresnel));
}
