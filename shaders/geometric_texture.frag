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
uniform float u_animation_time; // 0.0 to 1.0 sweeping wave animation

out vec4 fragColor;

// Deterministic hash — unique float per triangle
float hash1(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float getTriangleHash(float s0, float t0, bool isUp) {
    return isUp
        ? hash1(vec2(s0, t0))
        : hash1(vec2(s0 + 0.5, t0 + 0.5));
}

// Calculates the Z-height (lift) of a specific triangle based on the animation wave.
float getTriangleZ(float s0, float t0, bool isUp, float wave_center, float aspect, float scale) {
    float tri_cartesian_x = isUp ? (s0 + t0 * 0.5 + 0.5) : (s0 + t0 * 0.5 + 1.0);
    float tri_uv_x = tri_cartesian_x / (scale * aspect);
    
    float triHash = getTriangleHash(s0, t0, isUp);
    
    // Add a random offset for each individual triangle.
    // Reduced to 0.04 so the wave is less sparse and fewer triangles appear "missed".
    float random_offset = (triHash - 0.5) * 0.04;
    
    float wave_dist = abs(tri_uv_x - wave_center + random_offset);
    
    // Keep the wave very thin (cut in half to 0.03)
    return smoothstep(0.03, 0.0, wave_dist);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
    float aspect = u_resolution.x / u_resolution.y;

    vec2 uvA    = vec2(uv.x * aspect, uv.y);
    vec2 focalA = vec2(u_focal_point.x * aspect, u_focal_point.y);

    // -- Animation Wave Warp --
    // u_animation_time sweeps from 0 to 1.
    // Map wave center to move from left edge (-0.2) to right edge (1.2)
    float wave_center = mix(-0.2, 1.2, u_animation_time);

    // ── Equilateral triangle grid (oblique coordinates) ───────────────────
    const float H = 0.8660254037844387; // sqrt(3) / 2

    vec2 pos = uvA * u_scale;

    float s = pos.x - pos.y / (2.0 * H);
    float t = pos.y / H;

    float s0 = floor(s);
    float t0 = floor(t);
    float ls = s - s0;  // local s in [0, 1)
    float lt = t - t0;  // local t in [0, 1)

    bool isUp = (ls + lt) < 1.0;

    float triHash = getTriangleHash(s0, t0, isUp);

    float variation = mix(u_variation_floor, 1.0, triHash);
    
    // Calculate the Z lift for this triangle
    float current_Z = getTriangleZ(s0, t0, isUp, wave_center, aspect, u_scale);

    // We check the 3 adjacent triangles. If an adjacent triangle is "higher" (Z is greater),
    // it casts a shadow onto this pixel. The shadow strength depends on distance to the edge.
    float shadow = 0.0;
    
    // Spread the shadow deeper into the triangle so it expands out more smoothly
    float shadow_spread = 0.18;
    
    if (isUp) {
        // Edge 1 (bottom): Neighbor is Down-triangle at (s0, t0 - 1)
        float n1_Z = getTriangleZ(s0, t0 - 1.0, false, wave_center, aspect, u_scale);
        float diff1 = max(0.0, n1_Z - current_Z);
        shadow += diff1 * smoothstep(shadow_spread, 0.0, lt);
        
        // Edge 2 (left): Neighbor is Down-triangle at (s0 - 1, t0)
        float n2_Z = getTriangleZ(s0 - 1.0, t0, false, wave_center, aspect, u_scale);
        float diff2 = max(0.0, n2_Z - current_Z);
        shadow += diff2 * smoothstep(shadow_spread, 0.0, ls);
        
        // Edge 3 (right): Neighbor is Down-triangle at (s0, t0)
        float n3_Z = getTriangleZ(s0, t0, false, wave_center, aspect, u_scale);
        float diff3 = max(0.0, n3_Z - current_Z);
        shadow += diff3 * smoothstep(shadow_spread, 0.0, 1.0 - (ls + lt));
    } else {
        // Edge 1 (top): Neighbor is Up-triangle at (s0, t0 + 1)
        float n1_Z = getTriangleZ(s0, t0 + 1.0, true, wave_center, aspect, u_scale);
        float diff1 = max(0.0, n1_Z - current_Z);
        shadow += diff1 * smoothstep(shadow_spread, 0.0, 1.0 - lt);
        
        // Edge 2 (right): Neighbor is Up-triangle at (s0 + 1, t0)
        float n2_Z = getTriangleZ(s0 + 1.0, t0, true, wave_center, aspect, u_scale);
        float diff2 = max(0.0, n2_Z - current_Z);
        shadow += diff2 * smoothstep(shadow_spread, 0.0, 1.0 - ls);
        
        // Edge 3 (left): Neighbor is Up-triangle at (s0, t0)
        float n3_Z = getTriangleZ(s0, t0, true, wave_center, aspect, u_scale);
        float diff3 = max(0.0, n3_Z - current_Z);
        shadow += diff3 * smoothstep(shadow_spread, 0.0, (ls + lt) - 1.0);
    }
    
    // Soften the shadow so it isn't extremely dark right near the edges
    shadow = clamp(shadow, 0.0, 1.0);

    // ── Radial gradient ───────────────────────────────────────────────────
    float dist     = distance(uvA, focalA);
    float gradient = smoothstep(u_focal_spread, 0.0, dist);

    // Subtle ambient shimmer: triangles are faintly visible everywhere.
    float ambient = variation * 0.08;

    // Focal burst: full accent tint concentrated at the focal point.
    float burst = gradient * variation * u_intensity;

    // ── Final color ───────────────────────────────────────────────────────
    // Combine base ambient, radial burst, wave brightness (Z), and the drop shadow.
    // We boost intensity slightly based on Z to simulate catching the light source.
    float brightness_boost = current_Z * 0.25 * variation;
    
    // Subtract a softened shadow amount from the intensity
    float intensity = ambient + burst + brightness_boost - (shadow * 0.4);
    intensity = clamp(intensity, 0.0, 1.0);
    
    vec3  color = mix(u_base_color.rgb, u_accent_color.rgb, intensity);
    
    // Additive highlight proportional to variation.
    // Darker triangles (low variation) light up less than lighter triangles,
    // preserving their relative darkness perfectly! Kept subtle (0.08).
    color += vec3(0.08) * current_Z * variation;
    
    // Gently darken the base color where shadows fall (at most 25% darker)
    color *= mix(1.0, 0.75, shadow);

    fragColor = vec4(color, 1.0);
}

