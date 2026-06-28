#include <flutter/runtime_effect.glsl>

// Equilateral triangle grid with a radial accent-color gradient.
// Uses oblique (triangular lattice) coordinates so every triangle —
// both up (▲) and down (▽) — is painted with a single consistent color.
// Color is concentrated at u_focal_point and fades toward the edges.

uniform vec2  u_resolution;
uniform float u_scale;
uniform float u_intensity;    // Peak accent strength at the focal point (0–1)
uniform float u_focal_spread; // Gradient radius in aspect-corrected UV units
uniform vec2  u_focal_point;  // Focal point in normalized UV [0,1]
uniform float u_variation_floor; // Minimum per-triangle shade (0–1); higher = fewer dark triangles
uniform vec4  u_base_color;   // Scaffold background color
uniform vec4  u_accent_color; // User accent color

out vec4 fragColor;

// Deterministic hash — unique float per triangle
float hash1(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
    float aspect = u_resolution.x / u_resolution.y;

    // Aspect-correct both the triangle grid and the gradient so neither
    // stretches horizontally on wide screens.
    vec2 uvA    = vec2(uv.x * aspect, uv.y);
    vec2 focalA = vec2(u_focal_point.x * aspect, u_focal_point.y);

    // ── Equilateral triangle grid (oblique coordinates) ───────────────────
    // Row height for equilateral triangles with unit side length.
    const float H = 0.8660254037844387; // sqrt(3) / 2

    vec2 pos = uvA * u_scale;

    // Convert Cartesian to oblique (triangular lattice) coordinates.
    // Lattice basis: e1 = (1, 0), e2 = (0.5, H) in Cartesian.
    // Inverse transform: s = x − y / (2H), t = y / H.
    //
    // Each oblique cell (s0, t0) contains exactly two equilateral triangles:
    //   ls + lt < 1  →  up-triangle   (▲) with vertices at the three
    //                    corners (s0,t0), (s0+1,t0), (s0,t0+1)
    //   ls + lt > 1  →  down-triangle (▽) with vertices at (s0+1,t0),
    //                    (s0,t0+1), (s0+1,t0+1)
    //
    // Because each triangle lies entirely within one oblique cell, every
    // pixel in a given triangle maps to the same hash seed — eliminating
    // the seam artifacts that appear when using staggered rectangular cells.
    float s = pos.x - pos.y / (2.0 * H);
    float t = pos.y / H;

    float s0 = floor(s);
    float t0 = floor(t);
    float ls = s - s0;  // local s in [0, 1)
    float lt = t - t0;  // local t in [0, 1)

    bool isUp = (ls + lt) < 1.0;

    float triHash = isUp
        ? hash1(vec2(s0, t0))
        : hash1(vec2(s0 + 0.5, t0 + 0.5));

    // Random per-triangle shade in [u_variation_floor, 1.0]
    float variation = mix(u_variation_floor, 1.0, triHash);

    // ── Radial gradient ───────────────────────────────────────────────────
    float dist     = distance(uvA, focalA);
    float gradient = smoothstep(u_focal_spread, 0.0, dist);

    // Subtle ambient shimmer: triangles are faintly visible everywhere.
    float ambient = variation * 0.08;

    // Focal burst: full accent tint concentrated at the focal point.
    float burst = gradient * variation * u_intensity;

    // ── Final color ───────────────────────────────────────────────────────
    float intensity = clamp(ambient + burst, 0.0, 1.0);
    vec3  color     = mix(u_base_color.rgb, u_accent_color.rgb, intensity);
    fragColor = vec4(color, 1.0);
}
