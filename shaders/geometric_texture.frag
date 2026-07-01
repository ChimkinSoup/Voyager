#include <flutter/runtime_effect.glsl>

uniform vec2  u_resolution;
uniform float u_scale;
uniform float u_intensity;
uniform float u_focal_spread;
uniform vec2  u_focal_point;
uniform float u_variation_floor;
uniform vec4  u_base_color;
uniform vec4  u_accent_color;
uniform float u_time;
uniform float u_flash_brightness;
uniform float u_flash_density;
uniform float u_flash_speed;

out vec4 fragColor;

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

// Calculates the "flash" intensity (Z-height) of a specific triangle.
float getTriangleZ(float s0, float t0, bool isUp, float pulseWidth) {
    float triHash = getTriangleHash(s0, t0, isUp);
    
    // Randomize the flashing speed for each triangle, centered around u_flash_speed
    float speed = u_flash_speed * mix(0.5, 1.5, fract(triHash * 13.37));
    
    // The cycle time for this specific triangle
    float cycle = fract(u_time * speed + (triHash * 100.0));
    
    float d = abs(cycle - 0.5);
    
    return smoothstep(pulseWidth * 0.5, 0.0, d);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
    float aspect = u_resolution.x / u_resolution.y;

    vec2 uvA    = vec2(uv.x * aspect, uv.y);
    vec2 focalA = vec2(u_focal_point.x * aspect, u_focal_point.y);

    const float H = 0.8660254037844387; // sqrt(3) / 2
    vec2 pos = uvA * u_scale;

    float s = pos.x - pos.y / (2.0 * H);
    float t = pos.y / H;

    float s0 = floor(s);
    float t0 = floor(t);
    float ls = s - s0;
    float lt = t - t0;

    bool isUp = (ls + lt) < 1.0;

    float triHash = getTriangleHash(s0, t0, isUp);
    float variation = mix(u_variation_floor, 1.0, triHash);
    
    // Pre-calculate pulseWidth to avoid redundant computation
    float pulseWidth = mix(0.01, 0.8, u_flash_density);
    
    // Calculate the flash lift for this triangle
    float current_Z = getTriangleZ(s0, t0, isUp, pulseWidth);

    // -- Shadow Calculation --
    // OPTIMIZATION: Only evaluate neighbor Z-heights if the pixel is near an edge.
    // This skips up to 3 expensive getTriangleZ calls per pixel for the vast majority of the screen!
    float shadow = 0.0;
    float shadow_spread = 0.18;
    
    if (isUp) {
        if (lt < shadow_spread) {
            float n1_Z = getTriangleZ(s0, t0 - 1.0, false, pulseWidth);
            float diff1 = max(0.0, n1_Z - current_Z);
            shadow += diff1 * smoothstep(shadow_spread, 0.0, lt);
        }
        if (ls < shadow_spread) {
            float n2_Z = getTriangleZ(s0 - 1.0, t0, false, pulseWidth);
            float diff2 = max(0.0, n2_Z - current_Z);
            shadow += diff2 * smoothstep(shadow_spread, 0.0, ls);
        }
        if (1.0 - (ls + lt) < shadow_spread) {
            float n3_Z = getTriangleZ(s0, t0, false, pulseWidth);
            float diff3 = max(0.0, n3_Z - current_Z);
            shadow += diff3 * smoothstep(shadow_spread, 0.0, 1.0 - (ls + lt));
        }
    } else {
        if (1.0 - lt < shadow_spread) {
            float n1_Z = getTriangleZ(s0, t0 + 1.0, true, pulseWidth);
            float diff1 = max(0.0, n1_Z - current_Z);
            shadow += diff1 * smoothstep(shadow_spread, 0.0, 1.0 - lt);
        }
        if (1.0 - ls < shadow_spread) {
            float n2_Z = getTriangleZ(s0 + 1.0, t0, true, pulseWidth);
            float diff2 = max(0.0, n2_Z - current_Z);
            shadow += diff2 * smoothstep(shadow_spread, 0.0, 1.0 - ls);
        }
        if ((ls + lt) - 1.0 < shadow_spread) {
            float n3_Z = getTriangleZ(s0, t0, true, pulseWidth);
            float diff3 = max(0.0, n3_Z - current_Z);
            shadow += diff3 * smoothstep(shadow_spread, 0.0, (ls + lt) - 1.0);
        }
    }
    
    shadow = clamp(shadow, 0.0, 1.0);

    float dist     = distance(uvA, focalA);
    float gradient = smoothstep(u_focal_spread, 0.0, dist);

    float ambient = variation * 0.08;
    float burst = gradient * variation * u_intensity;

    // Use flash brightness parameter to boost intensity
    float brightness_boost = current_Z * u_flash_brightness * variation;
    
    float intensity = ambient + burst + brightness_boost - (shadow * 0.4);
    intensity = clamp(intensity, 0.0, 1.0);
    
    vec3 color = mix(u_base_color.rgb, u_accent_color.rgb, intensity);
    
    // Additive highlight proportional to variation and flash_brightness
    color += vec3(0.15) * current_Z * variation * u_flash_brightness;
    
    // Subtle shadow (darken base color slightly)
    color *= mix(1.0, 0.8, shadow);

    fragColor = vec4(color, 1.0);
}
