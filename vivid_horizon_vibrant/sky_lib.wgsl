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
// A grid of columns, 16 x 16 blocks, as vanilla's grid but larger. A full column is a box from a flat base at
// y = 192 up to a top that steps by 4 blocks (8 to 20 blocks thick), so the clouds are thick blocks with sharp edges.
// Inside, they are a uniform medium: the light is the sun's, dimmed by the cloud it crosses to reach each point
// (a few steps toward the sun through the same grid), scattered toward the eye (Henyey-Greenstein, a forward and a
// back lobe), plus the sky's light from above and the ground's and the low sun's from below.
// Style: real clouds are not boxes, and their tops are not flat steps; the light inside follows the same laws.
const BASE: f32 = 192.0;
const TOP_MAX: f32 = 212.0;
const CELL: f32 = 16.0;
// Vanilla's clouds move 0.6 block a second.
// shortcut: frame.time wraps every hour, so the clouds jump once an hour; use a day counter if the API gets one.
const DRIFT: f32 = 0.6;
// Extinction a block: 4 blocks of cloud keep 30 %, 12 blocks 3 %. Style: real cumulus is far denser (about 0.05 a
// metre), which would show only a hard surface; this lets light into the edges, as small clouds look.
const SIGMA: f32 = 0.3;
const MAX_CELLS: i32 = 40;
const MAX_SAMPLES: i32 = 24;
const FAR: f32 = 2600.0;

fn drift() -> vec2<f32> { return vec2<f32>(frame.time * DRIFT, 0.0); }

// The column's top (BASE when it holds no cloud), for the cell at grid coordinates `cell`.
fn column_top(cell: vec2<f32>) -> f32 {
    // Mostly the large-scale noise: the fine one alone made lone single cells (small floating hexagons from below).
    let n = sk_vnoise(cell * 0.17) * 0.88 + sk_vnoise(cell * 0.45 + 17.0) * 0.12;
    let thr = mix(0.55, 0.4, frame.rain);
    if n <= thr { return BASE; }
    let k = (n - thr) / (1.0 - thr);
    return BASE + 8.0 + 4.0 * floor(min(k * 4.0, 3.0));
}
fn top_at(p: vec3<f32>) -> f32 {
    return column_top(floor((p.xz - drift()) / CELL));
}
fn inside(p: vec3<f32>) -> bool {
    return p.y >= BASE && p.y <= top_at(p);
}

// How much of the sun reaches a point of the cloud: optical depth along four steps toward the sun.
fn sun_depth(p: vec3<f32>, s: vec3<f32>) -> f32 {
    var od = 0.0;
    var prev = 0.0;
    for (var i = 0; i < 4; i++) {
        let l = 1.5 * pow(2.2, f32(i));
        let q = p + s * l;
        if q.y > TOP_MAX || q.y < BASE - 1.0 { break; }
        if inside(q) { od += SIGMA * (l - prev); }
        prev = l;
    }
    return od;
}

// Clouds are columns of 16 blocks (column_top) cut into voxels of 2 blocks. Style, "cottony but square": a voxel
// near a face of the column that looks onto open sky may be missing, lower or raised (a hash per voxel, more the
// nearer the edge), every voxel's top may sit a step lower, and the rim's voxels are thinner (less dense), so
// the silhouette is ragged sub-blocks with soft, see-through edges and the tops are no longer flat slabs. Each
// voxel is uniform inside, and the ray's length through it is exact: no samples to streak.
const SUB: f32 = 2.0;

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

    // Walk the grid's cells (2D DDA); inside a cell, the part of the ray within the column's box is sampled.
    let start = (cam.xz + d.xz * t_in - drift()) / CELL;
    var cell = floor(start);
    let dir = d.xz;
    let step = vec2<f32>(select(-1.0, 1.0, dir.x >= 0.0), select(-1.0, 1.0, dir.y >= 0.0));
    let inv = vec2<f32>(CELL / max(abs(dir.x), 1e-6), CELL / max(abs(dir.y), 1e-6));
    var next = vec2<f32>(
        select(start.x - cell.x, cell.x + 1.0 - start.x, dir.x >= 0.0) * inv.x,
        select(start.y - cell.y, cell.y + 1.0 - start.y, dir.y >= 0.0) * inv.y) + t_in;
    var t = t_in;
    var trans = 1.0;
    var lit = vec3<f32>(0.0);
    var samples = 0;
    var src_e = array<vec3<f32>, 2>(vec3<f32>(0.0), vec3<f32>(0.0));
    var first = -1.0;
    for (var i = 0; i < MAX_CELLS; i++) {
        let t_exit = min(min(next.x, next.y), t_out);
        let top = column_top(cell);
        if top > BASE {
            // Which faces look onto open sky (no cloud in the neighbouring column).
            let open = vec4<bool>(column_top(cell - vec2<f32>(1.0, 0.0)) <= BASE, column_top(cell + vec2<f32>(1.0, 0.0)) <= BASE,
                column_top(cell - vec2<f32>(0.0, 1.0)) <= BASE, column_top(cell + vec2<f32>(0.0, 1.0)) <= BASE);
            // Walk the 2-block voxels of this column along the ray (a second 2D DDA, inside the cell).
            let sstart = (cam.xz + d.xz * t - drift()) / SUB;
            var sc = floor(sstart + dir * 1e-4);
            let sinv = vec2<f32>(SUB / max(abs(dir.x), 1e-6), SUB / max(abs(dir.y), 1e-6));
            var snext = vec2<f32>(
                select(sstart.x - sc.x, sc.x + 1.0 - sstart.x, dir.x >= 0.0) * sinv.x,
                select(sstart.y - sc.y, sc.y + 1.0 - sstart.y, dir.y >= 0.0) * sinv.y) + t;
            var ts = t;
            for (var j = 0; j < 20; j++) {
                let ts_exit = min(min(snext.x, snext.y), t_exit);
                let lc = clamp(sc - cell * 8.0, vec2<f32>(0.0), vec2<f32>(7.0));
                var edge = 9.0;
                if open.x { edge = min(edge, lc.x); }
                if open.y { edge = min(edge, 7.0 - lc.x); }
                if open.z { edge = min(edge, lc.y); }
                if open.w { edge = min(edge, 7.0 - lc.y); }
                let rim = clamp(1.0 - edge / 3.0, 0.0, 1.0);
                let h = vec4<f32>(hash3(vec3<f32>(sc, 1.0)), hash3(vec3<f32>(sc, 2.0)), hash3(vec3<f32>(sc, 3.0)), hash3(vec3<f32>(sc, 4.0)));
                if h.x >= rim * 0.55 {
                    let vtop = top - SUB * floor(rim * (h.y * 0.6 + h.z * 2.4));
                    // Flat bases: a cumulus' base is the level where rising air condenses, the same across the
                    // cloud. Raised rim bases showed from below as a grid of voxels of every thickness.
                    let vbot = BASE;
                    if vtop > vbot {
                        let ya = (vbot - cam.y) / d.y;
                        let yb = (vtop - cam.y) / d.y;
                        let a = max(ts, min(ya, yb));
                        let b = min(ts_exit, max(ya, yb));
                        if b > a {
                            // The light inside the cloud, taken at two points that move smoothly with the pixel: where
                            // the ray enters the cloud and 8 blocks further on, and blended by depth along the ray.
                            // Lit once per voxel instead, each voxel got its own flat shade: a grid seen from below.
                            if first < 0.0 {
                                first = a;
                                for (var e = 0; e < 2; e++) {
                                    let pe = cam + d * (first + f32(e) * 8.0);
                                    let od = sun_depth(pe, s);
                                    // Multiple scattering, after Wrenninge's octaves: a second, weaker and less
                                    // attenuated term keeps the inside of a thick cloud from going black.
                                    let he = clamp((pe.y - BASE) / (TOP_MAX - BASE), 0.0, 1.0);
                                    src_e[e] = light * (exp(-od) + 0.3 * exp(-od * 0.25)) * phase + mix(below_w, sky_up, he * he * 0.6 + he * 0.4);
                                }
                            }
                            let dens = mix(1.0, 0.45, rim);
                            let src = mix(src_e[0], src_e[1], clamp((0.5 * (a + b) - first) / 8.0, 0.0, 1.0));
                            let step_t = exp(-SIGMA * dens * (b - a));
                            lit += trans * src * (1.0 - step_t);
                            trans *= step_t;
                        }
                    }
                }
                if ts_exit >= t_exit || trans < 0.02 { break; }
                if snext.x < snext.y {
                    ts = snext.x; snext.x += sinv.x; sc.x += step.x;
                } else {
                    ts = snext.y; snext.y += sinv.y; sc.y += step.y;
                }
            }
            if trans < 0.02 { break; }
        }
        if t_exit >= t_out { break; }
        if next.x < next.y {
            t = next.x; next.x += inv.x; cell.x += step.x;
        } else {
            t = next.y; next.y += inv.y; cell.y += step.y;
        }
    }
    if first < 0.0 { return behind; }
    // The air between the eye and the cloud: far clouds fade into the horizon's haze (Beer-Lambert over the
    // distance, 1 - exp(-d / 1800)), and past FAR / 2 into the sky, so the grid doesn't alias at the horizon.
    let haze = 1.0 - exp(-first / 1800.0);
    let fade = 1.0 - smoothstep(FAR * 0.5, FAR, first);
    let horizon = sky_colour(normalize(vec3<f32>(d.x, 0.03, d.z)), frame.fog_color);
    // Style: a rain deck's clouds as dark as the grey between them (a thick deck lets little light through), not
    // brighter, so a storm sky reads as one low ceiling.
    let seen = mix(lit * mix(1.0, 0.45, frame.rain), horizon * (1.0 - trans), haze);
    return mix(behind, behind * trans + seen, fade);
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
