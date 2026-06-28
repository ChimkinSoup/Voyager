#include <flutter/runtime_effect.glsl>

// Low-poly geometric background texture.
// Divides the screen into a jittered grid, splits each cell diagonally into
// two triangles, then applies flat random shading to simulate a 3D faceted
// surface entirely on the GPU.

uniform vec2 u_resolution;
uniform float u_scale;
uniform float u_intensity;
uniform float u_randomness;
uniform float u_shape_complexity;
uniform vec4 u_base_color;

out vec4 fragColor;

// Generates a random 2D offset based on grid coordinates.
vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

// Generates a single flat random float based on triangle vertex sum.
float hash1(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Perturbs a perfect grid coordinate to make triangles organic and irregular.
// 0.0 = perfect grid, 1.0+ = highly randomized chaotic triangle sizes.
vec2 getVertex(vec2 p) {
    return p + (hash2(p) - 0.5) * u_randomness;
}

// 2D cross product — determines which side of a diagonal a pixel lies on.
float cross2d(vec2 a, vec2 b) {
    return a.x * b.y - a.y * b.x;
}

void main() {
    // Normalize and maintain aspect ratio so triangles don't stretch.
    vec2 uv  = FlutterFragCoord().xy / u_resolution.xy;
    vec2 pos = vec2(uv.x * (u_resolution.x / u_resolution.y), uv.y) * u_scale;

    // Identify the current grid cell.
    vec2 cell = floor(pos);

    // Calculate the four jittered corners of this cell.
    vec2 v00 = getVertex(cell + vec2(0.0, 0.0));
    vec2 v10 = getVertex(cell + vec2(1.0, 0.0));
    vec2 v01 = getVertex(cell + vec2(0.0, 1.0));
    vec2 v11 = getVertex(cell + vec2(1.0, 1.0));

    // Generate a unique random profile for this specific cell.
    float cellType = hash1(cell + vec2(42.0, 73.0));

    float shadeHash = 0.0;

    if (cellType < (0.33 * u_shape_complexity)) {
        // SHAPE 1: Quadrilateral — entire cell is one flat-shaded polygon.
        shadeHash = hash1(v00 + v10 + v01 + v11);

    } else if (cellType < (0.66 * u_shape_complexity)) {
        // SHAPE 2: Reverse triangles — diagonal runs top-left to bottom-right.
        vec2 diag  = v10 - v01;
        vec2 toPos = pos  - v01;
        bool isTopRight = cross2d(diag, toPos) < 0.0;

        shadeHash = isTopRight
            ? hash1(v01 + v00 + v10)
            : hash1(v01 + v10 + v11);

    } else {
        // SHAPE 3: Standard triangles — diagonal runs bottom-left to top-right.
        vec2 diag  = v11 - v00;
        vec2 toPos = pos  - v00;
        bool isBottomRight = cross2d(diag, toPos) < 0.0;

        shadeHash = isBottomRight
            ? hash1(v00 + v10 + v11)
            : hash1(v00 + v11 + v01);
    }

    // Map the hash to an intensity range to simulate flat 3D lighting.
    // mix() shades from (1.0 - intensity) up to full brightness (1.0).
    float shade = mix(1.0 - u_intensity, 1.0, shadeHash);

    fragColor = vec4(u_base_color.rgb * shade, u_base_color.a);
}
