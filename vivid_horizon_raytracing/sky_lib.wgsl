// The pack's sky (atmosphere, sun disc, stars, Milky Way, clouds), shared by the sky stage and the post pass,
// which redraws it over vanilla's moon square.

fn sk_lum(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)); }

fn sk_hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}
fn sk_vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(sk_hash2(i), sk_hash2(i + vec2<f32>(1.0, 0.0)), u.x), mix(sk_hash2(i + vec2<f32>(0.0, 1.0)), sk_hash2(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}

// The atmosphere is in atmos.wgsl (shared with the post pass).
fn hg(c: f32, g: f32) -> f32 { return atm_hg(c, g); }
fn sk_sun_colour(height: f32) -> vec3<f32> { return atm_sun(height); }
fn sky_colour(d: vec3<f32>, vanilla: vec3<f32>) -> vec3<f32> { return atm_colour(d, vanilla); }

// The sun's disc: angular radius SUN_RADIUS, limb darkened (I = 1 - u (1 - cos), u = 0.6, the Sun's in visible
// light), its colour the light that reaches the eye through the air.
// Style: 5 times the real Sun's radius (0.0047 rad), so it reads at Minecraft's scale; round, not vanilla's square.
const SUN_RADIUS: f32 = 0.026;
// Bright enough to read as the sun after the tone map's shoulder, dim enough that the glare's quarter-size pass
// doesn't turn it into a large blurred blob. Style: the real disc is about 10^5 times the sky.
const SUN_BRIGHT: f32 = 4.0;
fn sun_disc(d: vec3<f32>) -> vec3<f32> {
    let s = frame.sun_direction;
    let c = dot(d, s);
    let r = acos(clamp(c, -1.0, 1.0)) / SUN_RADIUS;
    if r >= 1.0 || s.y < -0.05 { return vec3<f32>(0.0); }
    let limb = 1.0 - 0.6 * (1.0 - sqrt(max(1.0 - r * r, 0.0)));
    let edge = 1.0 - smoothstep(0.96, 1.0, r);
    return sk_sun_colour(max(s.y, 0.005)) * SUN_BRIGHT * limb * edge * (1.0 - frame.rain);
}

// ---------------------------------------------------------------- night
// The stars and the Milky Way turn with the sky: a direction is taken into the sky's own frame by undoing the
// sun's turn about the axis it moves around (the world's z), so at midnight the sky's frame is the world's.
fn celestial(d: vec3<f32>) -> vec3<f32> {
    let s = frame.sun_direction;
    let a = atan2(s.y, s.x) + 1.5707963;
    let c = cos(-a);
    let n = sin(-a);
    return vec3<f32>(d.x * c - d.y * n, d.x * n + d.y * c, d.z);
}
// An integer hash of a lattice point (pcg3d, Jarzynski and Olano 2020). The old fract(sin(x) * 43758) lost its
// precision once x passed a few thousand (fine noise octaves, far cloud voxels): neighbouring cells got related
// values, which showed as facets and plates in the Milky Way.
fn hash3(p: vec3<f32>) -> f32 {
    var v = bitcast<vec3<u32>>(vec3<i32>(floor(p))) * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> vec3<u32>(16u);
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return f32(v.x >> 8u) / 16777215.0;
}
// One layer of stars: the sky cut into cells of 1 / `scale` radian, a star in a share `density` of them, at a
// random point of its cell, with a random brightness (most faint, a few bright: a power law, as magnitudes go) and
// colour (cool red to hot blue-white). Each is a small Gaussian a pixel or two wide.
fn star_layer(c: vec3<f32>, scale: f32, density: f32, bright: f32) -> vec3<f32> {
    let p = c * scale;
    let cell = floor(p);
    let h = hash3(cell);
    if h > density { return vec3<f32>(0.0); }
    let k = h / density;
    let centre = cell + vec3<f32>(hash3(cell + 17.0), hash3(cell + 31.0), hash3(cell + 47.0)) * 0.7 + 0.15;
    let r = length(p - centre);
    let b = bright * pow(k, 5.0) * exp(-r * r / 0.02);
    // Blue-white, white, yellow and a few orange, as the spectral classes come.
    let t = hash3(cell + 59.0);
    let colour = select(select(select(vec3<f32>(1.0, 0.62, 0.38), vec3<f32>(1.0, 0.88, 0.6), t > 0.12), vec3<f32>(1.0, 0.98, 0.95), t > 0.4), vec3<f32>(0.72, 0.82, 1.0), t > 0.72);
    return colour * b;
}
// A smooth noise on a direction (3D value noise, quintic fade) summed over four octaves, each turned by a fixed
// rotation so no octave's lattice lines up with another's: no grid shows in the sum.
fn sk_noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = mix(hash3(i), hash3(i + vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(hash3(i + vec3<f32>(0.0, 1.0, 0.0)), hash3(i + vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(hash3(i + vec3<f32>(0.0, 0.0, 1.0)), hash3(i + vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(hash3(i + vec3<f32>(0.0, 1.0, 1.0)), hash3(i + vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}
// Gradient (Perlin) noise: a random slope at each lattice corner, blended with the quintic fade. Unlike value
// noise its level lines are smooth curves; value noise's follow the lattice and showed as facets in the sky.
fn sk_grad(i: vec3<f32>, f: vec3<f32>) -> f32 {
    let g = vec3<f32>(hash3(i), hash3(i + 41.0), hash3(i + 89.0)) * 2.0 - 1.0;
    return dot(g, f);
}
fn sk_gnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = mix(sk_grad(i, f), sk_grad(i + vec3<f32>(1.0, 0.0, 0.0), f - vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(sk_grad(i + vec3<f32>(0.0, 1.0, 0.0), f - vec3<f32>(0.0, 1.0, 0.0)), sk_grad(i + vec3<f32>(1.0, 1.0, 0.0), f - vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(sk_grad(i + vec3<f32>(0.0, 0.0, 1.0), f - vec3<f32>(0.0, 0.0, 1.0)), sk_grad(i + vec3<f32>(1.0, 0.0, 1.0), f - vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(sk_grad(i + vec3<f32>(0.0, 1.0, 1.0), f - vec3<f32>(0.0, 1.0, 1.0)), sk_grad(i + vec3<f32>(1.0, 1.0, 1.0), f - vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return 0.5 + 0.9 * mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}
fn sk_fbm3(p0: vec3<f32>) -> f32 {
    let r = mat3x3<f32>(vec3<f32>(0.0, 0.8, 0.6), vec3<f32>(-0.8, 0.36, -0.48), vec3<f32>(-0.6, -0.48, 0.64));
    var p = p0;
    var sum = 0.0;
    var w = 0.5;
    for (var i = 0; i < 4; i++) {
        sum += w * sk_gnoise3(p);
        p = r * p * 2.03 + vec3<f32>(1.7, 9.2, 4.1);
        w *= 0.5;
    }
    return sum / 0.9375;
}
// The Milky Way: a band about 0.25 rad wide around a great circle, patchy, cut by dark dust lanes along its
// middle, warmer toward its centre (old stars) and bluer away from it. Everything is a smooth noise of the
// direction itself, warped by another noise, so star clouds and lanes are organic, with nothing on a grid; its
// grain is a dense layer of faint stars, each a point, not a cell.
fn milky_way(c: vec3<f32>) -> vec3<f32> {
    let n = normalize(vec3<f32>(0.62, 0.25, 0.74));
    let along = normalize(cross(n, vec3<f32>(0.0, 1.0, 0.0)));
    let side = cross(n, along);
    if abs(dot(c, n)) > 0.75 { return vec3<f32>(0.0); }
    let warp = vec3<f32>(sk_gnoise3(c * 3.0), sk_gnoise3(c * 3.0 + 11.0), sk_gnoise3(c * 3.0 + 23.0)) - 0.5;
    let cw = normalize(c + warp * 0.12);
    let x = dot(cw, n);
    let band = exp(-x * x / 0.07);
    if band < 0.002 { return vec3<f32>(0.0); }
    let clouds = sk_fbm3(cw * 6.0);
    // Dust lanes: a lane winding about the band's middle, frayed by a finer noise.
    let lane_x = x + 0.05 * (sk_fbm3(cw * 4.0 + 31.0) - 0.5);
    // The dust in filaments: a ridged noise (1 - |2n - 1|) is high along thin winding lines.
    let ridge = 1.0 - abs(2.0 * sk_fbm3(cw * 7.0 + 9.0) - 1.0);
    let dust = (0.5 * smoothstep(0.55, 0.9, ridge) + 0.5 * smoothstep(0.5, 0.75, sk_fbm3(cw * 3.0 + 51.0)))
        * exp(-lane_x * lane_x / 0.006);
    // The galactic centre, 0.6 rad along the band.
    let centre = normalize(along * cos(0.6) + side * sin(0.6));
    let core = exp((dot(cw, centre) - 1.0) / 0.22);
    let colour = mix(vec3<f32>(0.5, 0.55, 1.0), vec3<f32>(1.0, 0.8, 0.62), core);
    let grain = star_layer(c.yzx, 1500.0, 0.35, 0.5) * band * 3.0;
    return colour * band * (0.35 + 1.0 * clouds * clouds * 1.6) * (1.0 - 0.85 * dust) * (0.6 + 1.0 * core) * 0.28 + grain;
}
fn night_sky(d: vec3<f32>) -> vec3<f32> {
    let dark = (1.0 - smoothstep(-0.18, 0.02, frame.sun_direction.y)) * (1.0 - frame.rain);
    if dark <= 0.0 || d.y < -0.05 { return vec3<f32>(0.0); }
    let c = celestial(d);
    // Extinction near the horizon (the air mass) and the twinkle (scintillation, stronger through more air).
    let air = smoothstep(-0.02, 0.25, d.y);
    let tw = 1.0 - (0.15 + 0.35 * (1.0 - air)) * (0.5 + 0.5 * sin(frame.time * (4.0 + 9.0 * hash3(floor(c * 700.0))) + hash3(floor(c * 700.0)) * 60.0));
    let stars = star_layer(c, 520.0, 0.14, 1.6) + star_layer(c, 200.0, 0.05, 9.0) + star_layer(c.zxy, 700.0, 0.05 * exp(-dot(c, normalize(vec3<f32>(0.62, 0.25, 0.74))) * dot(c, normalize(vec3<f32>(0.62, 0.25, 0.74))) / 0.07), 1.2);
    // The moon's aureole: forward scattering by the haze around it.
    let m = frame.moon_direction;
    let halo = vec3<f32>(0.75, 0.82, 1.0) * atm_hg(dot(d, m), 0.88) * 0.0035 * smoothstep(-0.05, 0.1, m.y);
    return (stars * tw + milky_way(c)) * dark * air + halo * dark;
}

// ---------------------------------------------------------------- clouds
// Style, "cottony but square" (Evan's reference): each cloud is a solid box with rounded edges, lit like a soft
// solid (bright top, sides by their angle to the sun, a darker underside lit by the ground and the low sun), with a
// soft rim about a block wide. Real clouds are neither solid nor boxes; this is a look, not a medium. One box at most
// in each 24-block cell of a layer from y = 192 to 212, its size, place and height from hashes of the cell, the
// cover from a slow noise (more and larger in rain). The ray walks the cells (2D DDA) and, in a cell with a box,
// steps along the box's signed distance (a rounded box: exact distance, exact normal): no samples, so no streaks
// and no grid.
const BASE: f32 = 192.0;
const TOP_MAX: f32 = 212.0;
const CELL: f32 = 24.0;
// Vanilla's clouds move 0.6 block a second.
// shortcut: frame.time wraps every hour, so the clouds jump once an hour; use a day counter if the API gets one.
const DRIFT: f32 = 0.6;
const MAX_CELLS: i32 = 64;
const FAR: f32 = 2600.0;
// How wide the soft rim is, in blocks.
const RIM: f32 = 0.9;

fn drift() -> vec2<f32> { return vec2<f32>(frame.time * DRIFT, 0.0); }

// The box of a cell: centre (in the drifted grid's frame) in xyz and rounding radius in w; half-size in the second
// vector, whose w is 0 when the cell is empty.
fn cloud_box(cell: vec2<f32>) -> array<vec4<f32>, 2> {
    let cover = sk_vnoise(cell * 0.21) * 0.7 + hash3(vec3<f32>(cell, 5.0)) * 0.3;
    let thr = mix(0.52, 0.32, frame.rain);
    if cover <= thr { return array<vec4<f32>, 2>(vec4<f32>(0.0), vec4<f32>(0.0)); }
    let h = vec4<f32>(hash3(vec3<f32>(cell, 11.0)), hash3(vec3<f32>(cell, 12.0)), hash3(vec3<f32>(cell, 13.0)), hash3(vec3<f32>(cell, 14.0)));
    let g = vec2<f32>(hash3(vec3<f32>(cell, 15.0)), hash3(vec3<f32>(cell, 16.0)));
    let big = 1.0 + 0.6 * smoothstep(thr, 1.0, cover) + 0.4 * frame.rain;
    let half_xz = min(vec2<f32>(2.5 + 5.0 * h.x, 2.5 + 5.0 * h.y) * big, vec2<f32>(CELL * 0.5 - 1.5));
    let half_y = 1.5 + 1.8 * h.z;
    let room = vec2<f32>(CELL * 0.5) - half_xz - 1.0;
    let centre = vec3<f32>((cell.x + 0.5) * CELL + (g.x - 0.5) * 2.0 * room.x, BASE + 3.0 + 12.0 * h.w,
        (cell.y + 0.5) * CELL + (g.y - 0.5) * 2.0 * room.y);
    let r = min(1.8, 0.8 * min(half_y, min(half_xz.x, half_xz.y)));
    return array<vec4<f32>, 2>(vec4<f32>(centre, r), vec4<f32>(half_xz.x, half_y, half_xz.y, 1.0));
}
fn round_box(p: vec3<f32>, b: vec3<f32>, r: f32) -> f32 {
    let q = abs(p) - (b - vec3<f32>(r));
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

// Clouds along the view ray from the camera, in front of the sky `behind`: what the eye sees.
fn clouds(d: vec3<f32>, behind: vec3<f32>) -> vec3<f32> {
    if frame.dimension != 0 { return behind; }
    let cam = frame.camera_position;
    if abs(d.y) < 0.0005 { return behind; }
    let ta = (BASE - cam.y) / d.y;
    let tb = (TOP_MAX - cam.y) / d.y;
    let t_in = max(min(ta, tb), 0.0);
    let t_out = min(max(ta, tb), FAR);
    if t_out <= t_in { return behind; }

    let s_up = frame.sun_direction.y > 0.0;
    let s = select(frame.moon_direction, frame.sun_direction, s_up);
    let weather = mix(1.0, 0.04, frame.rain);
    // The light that reaches the cloud layer: the sun through the air (orange when low), or the moon.
    let light = select(vec3<f32>(0.01, 0.016, 0.03), sk_sun_colour(max(frame.sun_direction.y, 0.0)) * 0.5, s_up) * weather;
    let mu = dot(d, s);
    // Two lobes: most light goes on forward (silver linings toward the sun), some comes back (lit faces).
    let phase = mix(hg(mu, -0.25), hg(mu, 0.7), 0.6) * 12.566;
    // Above, the sky's light (the atmosphere straight up); below, the ground's and the low sun's: a sun near the
    // horizon lights the bases with the horizon's orange.
    let sky_up = atm_ambient() * 0.9;
    // The horizon under the sun's azimuth (any azimuth when the sun is overhead), not the sun's aureole.
    let toward_sun = normalize(normalize(vec3<f32>(s.x + 0.001, 0.0, s.z)) + vec3<f32>(0.0, 0.03, 0.0));
    let below = sky_colour(toward_sun, frame.fog_color) * 0.5 * select(0.2, 1.0, s_up) + vec3<f32>(0.32, 0.36, 0.3) * sk_lum(light) * 0.15;
    // Under a rain deck the bases see no low sun: a grey, dimmer underside.
    let below_w = mix(below, vec3<f32>(sk_lum(below)), frame.rain) * mix(1.0, 0.4, frame.rain);

    // The camera in the drifted grid's frame.
    let eye = vec3<f32>(cam.x - drift().x, cam.y, cam.z - drift().y);
    let start = (eye.xz + d.xz * t_in) / CELL;
    var cell = floor(start);
    let dir = d.xz;
    let step = vec2<f32>(select(-1.0, 1.0, dir.x >= 0.0), select(-1.0, 1.0, dir.y >= 0.0));
    let inv = vec2<f32>(CELL / max(abs(dir.x), 1e-6), CELL / max(abs(dir.y), 1e-6));
    var next = vec2<f32>(
        select(start.x - cell.x, cell.x + 1.0 - start.x, dir.x >= 0.0) * inv.x,
        select(start.y - cell.y, cell.y + 1.0 - start.y, dir.y >= 0.0) * inv.y) + t_in;
    let id = 1.0 / select(d, vec3<f32>(1e-6), abs(d) < vec3<f32>(1e-6));
    var acc = vec3<f32>(0.0);
    var alpha = 0.0;
    var first = -1.0;
    for (var i = 0; i < MAX_CELLS; i++) {
        let t_exit = min(min(next.x, next.y), t_out);
        let bx = cloud_box(cell);
        if bx[1].w > 0.0 {
            let c = bx[0].xyz - eye;
            let hb = bx[1].xyz;
            let r = bx[0].w;
            // The ray's span inside the box grown by the rim (slab test).
            let t0 = (c - hb - vec3<f32>(RIM)) * id;
            let t1 = (c + hb + vec3<f32>(RIM)) * id;
            let tn = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), max(min(t0.z, t1.z), 0.0));
            let tf = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
            if tf > tn {
                var tt = tn;
                var closest = 1e9;
                var t_close = tn;
                var hit = false;
                for (var k = 0; k < 24; k++) {
                    let dist = round_box(d * tt - c, hb, r);
                    if dist < closest { closest = dist; t_close = tt; }
                    if dist < 0.02 { hit = true; break; }
                    tt += max(dist, 0.05);
                    if tt > tf { break; }
                }
                // The surface's normal (for the rim of a near miss, the closest point's), then its light.
                let pl = d * t_close - c;
                let q = abs(pl) - (hb - vec3<f32>(r));
                let n = normalize(sign(pl) * max(q, vec3<f32>(0.0)) + vec3<f32>(0.0, 1e-4, 0.0));
                let sun_side = max(dot(n, s), 0.0);
                let col = light * (0.3 + 0.7 * sun_side) * (1.1 + 0.4 * phase) + mix(below_w, sky_up, 0.5 + 0.5 * n.y);
                let a = select(1.0 - smoothstep(0.0, RIM, closest), 1.0, hit);
                if a > 0.001 {
                    if first < 0.0 { first = t_close; }
                    acc += (1.0 - alpha) * a * col;
                    alpha += (1.0 - alpha) * a;
                }
                if alpha > 0.98 { break; }
            }
        }
        if t_exit >= t_out { break; }
        if next.x < next.y {
            next.x += inv.x; cell.x += step.x;
        } else {
            next.y += inv.y; cell.y += step.y;
        }
    }
    if first < 0.0 { return behind; }
    // The air between the eye and the cloud: far clouds fade into the horizon's haze (Beer-Lambert over the
    // distance, 1 - exp(-d / 1800)), and past FAR / 2 into the sky, so the grid doesn't alias at the horizon.
    let haze = 1.0 - exp(-first / 1800.0);
    let fade = 1.0 - smoothstep(FAR * 0.5, FAR, first);
    let horizon = sky_colour(normalize(vec3<f32>(d.x, 0.03, d.z)), frame.fog_color);
    // Style: a rain deck's clouds darker (a thick deck lets little light through), so a storm sky reads as one
    // low ceiling.
    let seen = mix(acc * mix(1.0, 0.45, frame.rain), horizon * alpha, haze);
    return mix(behind, behind * (1.0 - alpha) + seen, fade);
}


// The moon, drawn by the sky stage (`[sky] moon = false` leaves Minecraft's square out), so the clouds pass in front
// of it like any other sky. A sphere lit by the sun: the phase (`frame.moon_phase`, 0 full to 4 new) sets the sun's
// angle behind it, and each point of the disc is lit as its sphere's normal faces that light (the terminator, soft
// over the lunar relief), with dark maria and craters from noise and a faint earthshine on the dark part.
// Style: the disc is about 7 times the real moon's (0.0045 rad).
const SK_MOON_R: f32 = 0.03;
fn moon_disc(d: vec3<f32>) -> vec3<f32> {
    let m = frame.moon_direction;
    if m.y < -0.1 { return vec3<f32>(0.0); }
    let e1 = normalize(cross(m, vec3<f32>(0.0, 0.0, 1.0)));
    let e2 = cross(e1, m);
    let cm = dot(d, m);
    if cm < 0.99 { return vec3<f32>(0.0); }
    let q = vec2<f32>(dot(d, e1), dot(d, e2)) / cm / SK_MOON_R;
    let r = length(q);
    if r >= 1.0 { return vec3<f32>(0.0); }
    let n = vec3<f32>(q, sqrt(max(1.0 - r * r, 0.0)));
    // Phase angle: 0 full (sun behind the eye) to pi new (sun behind the moon); waning lit on one side, waxing on
    // the other.
    let ph = f32(frame.moon_phase % 8u);
    let ang = select(ph, 8.0 - ph, ph > 4.0) * 0.7853982;
    let side = select(1.0, -1.0, ph > 4.0);
    let to_sun = vec3<f32>(side * sin(ang), 0.0, cos(ang));
    let lit = smoothstep(-0.04, 0.06, dot(n, to_sun));
    let maria = smoothstep(0.45, 0.7, sk_vnoise(q * 2.3 + 3.0) * 0.7 + sk_vnoise(q * 5.0) * 0.3);
    let cell = floor(q * 7.0);
    let f = fract(q * 7.0) - 0.5 - (vec2<f32>(sk_hash2(cell), sk_hash2(cell + 9.0)) - 0.5) * 0.4;
    let crater = select(0.0, smoothstep(0.32, 0.22, length(f)) - 0.6 * smoothstep(0.22, 0.12, length(f)), sk_hash2(cell + 4.0) > 0.7);
    let limb = 1.0 - 0.35 * (1.0 - n.z);
    let albedo = 0.95 - 0.38 * maria + 0.12 * crater;
    let edge = smoothstep(1.0, 0.96, r);
    let dark = (1.0 - smoothstep(-0.18, 0.02, frame.sun_direction.y));
    return vec3<f32>(0.92, 0.95, 1.0) * albedo * limb * (lit * 1.6 + 0.02) * edge * mix(1.0, 0.35, frame.rain) * mix(0.4, 1.0, dark);
}
