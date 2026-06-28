# Geomtric Texture Painter:
import 'dart:ui';
import 'package:flutter/material.dart';

/// A reusable widget that applies the low-poly geometric shader to its bounds.
class GeometricTexture extends StatelessWidget {
  final FragmentProgram program;
  final Widget? child;
  final Color baseColor;
  final double randomness;
  final double shapeComplexity;

  const GeometricTexture({
    super.key,
    required this.program,
    this.child,
    // Default to a blue accent if none is provided, easy to spot during dev
    this.baseColor = Colors.blueAccent, 
    // Controls how heavily the grid is distorted. 
    // 0.0 = perfect grid. > 1.0 = highly randomized shard sizes.
    this.randomness = 1.2, 
    // 0.0 = Only uniform triangles. 1.0 = Full mix of Quads and opposing Triangles.
    this.shapeComplexity = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: GeometricTexturePainter(
        shader: program.fragmentShader(),
        baseColor: baseColor,
        randomness: randomness,
        shapeComplexity: shapeComplexity,
      ),
      child: child,
    );
  }
}

class GeometricTexturePainter extends CustomPainter {
  final FragmentShader shader;
  final Color baseColor;
  final double randomness;
  final double shapeComplexity;

  GeometricTexturePainter({
    required this.shader,
    required this.baseColor,
    required this.randomness,
    required this.shapeComplexity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Pass uniforms to the GLSL shader in the exact order they are declared
    
    // u_resolution
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    
    // u_scale (Higher = smaller, more numerous triangles)
    shader.setFloat(2, 8.0); 
    
    // u_intensity (How dark the deepest "shadowed" triangle is)
    // 0.3 means the darkest triangle will be 70% brightness of the base color
    shader.setFloat(3, 0.3); 
    
    // u_randomness (How much the grid vertices are jittered)
    shader.setFloat(4, randomness);
    
    // u_shape_complexity (Mix of Quads vs Triangles)
    shader.setFloat(5, shapeComplexity);
    
    // u_base_color (RGBA format: 0.0 to 1.0)
    shader.setFloat(6, baseColor.red / 255.0);
    shader.setFloat(7, baseColor.green / 255.0);
    shader.setFloat(8, baseColor.blue / 255.0);
    shader.setFloat(9, baseColor.opacity);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant GeometricTexturePainter oldDelegate) {
    return oldDelegate.baseColor != baseColor || 
           oldDelegate.randomness != randomness ||
           oldDelegate.shapeComplexity != shapeComplexity;
  }
}

# Low-Poly Geomteric Shader
#include <flutter/runtime_effect.glsl>

uniform vec2 u_resolution;
uniform float u_scale;
uniform float u_intensity;
uniform float u_randomness;
uniform float u_shape_complexity; // NEW: Controls the mix of shapes
uniform vec4 u_base_color;

out vec4 fragColor;

// Generates a random 2D offset based on grid coordinates
vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

// Generates a single flat random float based on vertices
float hash1(vec2 p) {
    vec3 p3  = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Perturbs a perfect grid coordinate
vec2 getVertex(vec2 p) {
    return p + (hash2(p) - 0.5) * u_randomness; 
}

// 2D Cross product to determine pixel position relative to a diagonal
float cross2d(vec2 a, vec2 b) {
    return a.x * b.y - a.y * b.x;
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
    vec2 pos = vec2(uv.x * (u_resolution.x / u_resolution.y), uv.y) * u_scale;

    vec2 cell = floor(pos);

    // Calculate the 4 jittered corners of this specific cell
    vec2 v00 = getVertex(cell + vec2(0.0, 0.0));
    vec2 v10 = getVertex(cell + vec2(1.0, 0.0));
    vec2 v01 = getVertex(cell + vec2(0.0, 1.0));
    vec2 v11 = getVertex(cell + vec2(1.0, 1.0));

    // Generate a unique random profile for this specific cell
    float cellType = hash1(cell + vec2(42.0, 73.0));

    float shadeHash = 0.0;

    // Dynamically choose the polygon shape for this area
    if (cellType < (0.33 * u_shape_complexity)) {
        // SHAPE 1: Quadrilateral (No slice)
        shadeHash = hash1(v00 + v10 + v01 + v11);
        
    } else if (cellType < (0.66 * u_shape_complexity)) {
        // SHAPE 2: Reverse Triangles (Sliced Top-Left to Bottom-Right)
        vec2 diag = v10 - v01;
        vec2 toPos = pos - v01;
        bool isTopRight = cross2d(diag, toPos) < 0.0;
        
        if (isTopRight) {
            shadeHash = hash1(v01 + v00 + v10);
        } else {
            shadeHash = hash1(v01 + v10 + v11);
        }
        
    } else {
        // SHAPE 3: Standard Triangles (Sliced Bottom-Left to Top-Right)
        vec2 diag = v11 - v00;
        vec2 toPos = pos - v00;
        bool isBottomRight = cross2d(diag, toPos) < 0.0;
        
        if (isBottomRight) {
            shadeHash = hash1(v00 + v10 + v11);
        } else {
            shadeHash = hash1(v00 + v11 + v01);
        }
    }

    float shade = mix(1.0 - u_intensity, 1.0, shadeHash);
    fragColor = vec4(u_base_color.rgb * shade, u_base_color.a);
}