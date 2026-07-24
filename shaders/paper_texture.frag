#include <flutter/runtime_effect.glsl>

// Warm cream paper: a flat matte field speckled with fine, evenly distributed
// grain.
//
// Deliberately static and stateless — no time uniform, no animation. The whole
// point of the light theme's background is that it reads as a physical sheet of
// paper the UI sits on, so the only thing that moves in front of it is the
// petal field painted on top. A still shader also means this layer paints once
// and is then cached by the compositor for as long as the window size and the
// user's colors hold.
//
// The grain is built from three octaves of value noise at very different
// frequencies rather than one, because a single frequency reads as a regular
// screen-door pattern at any dot size big enough to see. Layering a fine dot
// field over a mid tooth over a slow blotch gives the irregular, non-repeating
// look of real paper stock.

uniform vec2  u_resolution;
uniform vec4  u_base_color;   // Warm off-white / cream ground
uniform vec4  u_speck_color;  // Tone the specks are pulled toward (light gray)
uniform float u_grain_scale;  // Dots per screen width; higher = finer grain
uniform float u_grain_strength; // 0–1: how far a speck pulls toward u_speck_color
uniform float u_fiber_strength; // 0–1: strength of the slow, larger-scale blotch

out vec4 fragColor;

// Deterministic per-cell hash in [0,1). The large irrational-ish constants keep
// neighbouring cells from correlating, which is what makes the field read as
// evenly distributed rather than streaked.
float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise: hash the four corners of the cell and smoothstep between them.
float valueNoise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(cell);
    float b = hash21(cell + vec2(1.0, 0.0));
    float c = hash21(cell + vec2(0.0, 1.0));
    float d = hash21(cell + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;

    // Work in pixels scaled by grain size so the dot pitch stays constant
    // regardless of window dimensions — resizing the window must not resize
    // the paper's grain, or the texture visibly "zooms".
    vec2 uv = fragCoord / u_resolution.x;
    vec2 grainUv = uv * u_grain_scale;

    // Octave 1 — the speckle proper. Hashed per pixel-cell with no smoothing so
    // individual dots stay crisp rather than blurring into a haze.
    float speck = hash21(floor(grainUv));

    // Octave 2 — the paper's "tooth": a smooth mid-frequency variation that
    // stops the dots from sitting on a perfectly uniform ground.
    float tooth = valueNoise(grainUv * 0.25);

    // Octave 3 — very slow blotching, the uneven pulp density of real stock.
    float fiber = valueNoise(uv * 6.0);

    // Only the upper part of the speck distribution becomes a visible dot.
    // Without this cut every cell is tinted and the result is uniform noise
    // (visually just a duller cream) instead of discrete specks on a clean
    // ground.
    float dot_ = smoothstep(0.62, 1.0, speck);

    float grain = dot_ * u_grain_strength;
    grain += (tooth - 0.5) * u_grain_strength * 0.35;

    vec3 color = mix(u_base_color.rgb, u_speck_color.rgb, clamp(grain, 0.0, 1.0));

    // The blotch shifts luminance very slightly in both directions rather than
    // tinting toward the speck color, so it stays a density variation of the
    // paper itself.
    color *= 1.0 + (fiber - 0.5) * u_fiber_strength;

    fragColor = vec4(clamp(color, 0.0, 1.0), u_base_color.a);
}
