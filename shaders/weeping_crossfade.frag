#include <flutter/runtime_effect.glsl>

// One band of the demo page's weeping cherry while the weeks fall: its
// unthinned canopy mixed linearly into the thinned one, in a single pass.
// Mixing the two premultiplied bakes per pixel is the same blend as
// compositing both into an offscreen layer and adding them, without the
// layers — which were most of the GPU's work during the fall.

uniform vec4 u_rect;  // Where the band's bakes go: left, top, width, height
uniform float u_thinned;  // 0 = all unthinned, 1 = all thinned
uniform sampler2D u_full;
uniform sampler2D u_thin;

out vec4 fragColor;

void main() {
  vec2 uv = (FlutterFragCoord().xy - u_rect.xy) / u_rect.zw;
  fragColor = mix(texture(u_full, uv), texture(u_thin, uv), u_thinned);
}
