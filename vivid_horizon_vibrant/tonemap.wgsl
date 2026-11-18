// The picture onto the display: a vignette (RTX Remix's default: intensity 0.6, radius 0.8, softness 0.2), and
// Vibrant's grade.
// Style: a gentle S curve (a little more contrast in the mid-tones, a soft shoulder that brings highlights above 1
// back under white instead of clipping them) and a vibrance that saturates dull colours more than bright ones.
// Neither is how a camera or an eye answers light; they are a colourist's choices. The base pack has neither
// (ACES was tried there and left out: too dark, colours crushed); this curve keeps mid-grey where it is.
const VIGNETTE: f32 = 0.6;
const CONTRAST: f32 = 0.08;
const VIBRANCE: f32 = 0.22;
fn lum(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)); }
fn tonemap(input: TonemapInput) -> vec3<f32> {
    let d = length((input.uv - 0.5) * 2.0);
    var c = input.color * (1.0 - VIGNETTE * smoothstep(0.8, 1.4, d));
    // Vibrance: the less saturated a colour is, the more it gains.
    let l = lum(c);
    let sat = (max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b)) / max(max(max(c.r, c.g), c.b), 1e-4);
    c = max(mix(vec3<f32>(l), c, 1.0 + VIBRANCE * (1.0 - sat)), vec3<f32>(0.0));
    // S curve on luminance around mid-grey 0.18, then a soft shoulder from 0.8 that reaches 1 at infinity.
    let l2 = lum(c);
    var t = l2 * (1.0 + CONTRAST * (l2 - 0.18) / (l2 + 0.18));
    if t > 0.8 { t = 0.8 + 0.2 * (1.0 - exp(-(t - 0.8) / 0.2)); }
    return c * (t / max(l2, 1e-5));
}
