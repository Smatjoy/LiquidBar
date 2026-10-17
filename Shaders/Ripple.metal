#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Radial ripple for SwiftUI's `layerEffect`. A damped sine wave leaves
/// `origin` at `speed` points per second; each pixel samples the layer pushed
/// along the line from the origin by the wave's height where it is now.
[[ stitchable ]]
half4 ripple(float2 position, SwiftUI::Layer layer, float2 origin, float time,
             float amplitude, float frequency, float decay, float speed) {
  float2 delta = position - origin;
  float distance = length(delta);
  float t = max(0.0, time - distance / speed);
  float wave = amplitude * sin(frequency * t) * exp(-decay * t);
  float2 direction = distance > 0.0 ? delta / distance : float2(0.0);
  half4 color = layer.sample(position + wave * direction);
  // Crests catch a little light.
  color.rgb += half(0.3 * wave / amplitude) * color.a;
  return color;
}
