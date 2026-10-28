#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A page under construction (Warp.swift): the screen's border glows while Dream works, and at
// each step of the work a burst of stars flies from the centre out to the border and into it.
// One pass for both, so a star always has the border's color where it's heading. Each pixel
// does a few sums: no blurs, no textures.

/// A random number in 0...1 from an integer (PCG), far cheaper on a GPU than sin.
static float random(uint n) {
    n = n * 747796405u + 2891336453u;
    uint w = ((n >> ((n >> 28u) + 4u)) ^ n) * 277803737u;
    return float((w >> 22u) ^ w) / 4294967295.0;
}

/// The border's color at an angle from the centre: four colors going round as `turn` grows.
static half3 hueAt(float angle, float turn, half4 c0, half4 c1, half4 c2, half4 c3) {
    float around = fract(angle / (2.0 * M_PI_F) + 0.5 + turn) * 4.0;
    uint index = uint(around) % 4u;
    half4 colors[4] = { c0, c1, c2, c3 };
    return mix(colors[index], colors[(index + 1u) % 4u], half(smoothstep(0.0, 1.0, fract(around)))).rgb;
}

// `border`: how strongly the border glows, 0...1. `stars`: how visible the burst is, 0...1.
// `travel`: how far the stars have flown, added up on the CPU so a change of speed never makes
// them jump. `stretch`: how far back in depth each streak's tail reaches. `dark`: 1 on a dark
// screen, where the stars' heads burn white.
[[ stitchable ]] half4 construction(float2 position, half4 color, float2 size, float radius, float turn, float border, float stars,
                                    float travel, float stretch, float dark, half4 c0, half4 c1, half4 c2, half4 c3) {
    float2 middle = size * 0.5;
    float2 p = position - middle;
    float angle = atan2(p.y, p.x);
    half3 hue = hueAt(angle, turn, c0, c1, c2, c3);

    // The border: distance in from the edge of a rounded rectangle the size of the screen
    // decides the glow, so it looks blurred without blurring.
    float2 q = abs(p) - (middle - radius);
    float inside = -(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius);
    float edge = 0.0;
    if (border > 0.0 && inside < 90.0) {
        edge = min(1.0, (0.95 * exp(-inside / 2.5) + 0.5 * exp(-inside / 11.0) + 0.28 * exp(-inside / 30.0)) * border);
    }

    // The stars. The sky is cut into thin wedges from the centre; each holds up to three stars,
    // each at its own depth. A star's distance from the centre is 1 / depth, so far ones crawl
    // near the middle and near ones race out to the border.
    float star = 0.0;
    half3 starLight = half3(0.0);
    if (stars > 0.001) {
        float reach = length(middle);
        float r = length(p) / reach;
        const float wedges = 200.0;
        float u = (angle / (2.0 * M_PI_F) + 0.5) * wedges;
        uint wedge = uint(u) % 200u;
        float across = 2.0 * M_PI_F * r * reach / wedges;
        for (uint layer = 0u; layer < 3u; layer++) {
            uint seed = wedge * 8u + layer * 4099u;
            if (random(seed) > 0.6) continue;
            // Where across its wedge the star flies, so stars don't line up into spokes.
            float lane = 0.15 + 0.7 * random(seed + 1u);
            float off = abs(fract(u) - lane) * across;
            float rate = 0.5 + 0.5 * random(seed + 2u);
            float progress = fract(random(seed + 3u) + travel * rate);
            float depth = 1.0 - 0.96 * progress;
            float width = mix(0.6, 2.6, 1.0 - depth);
            float head = 0.05 / depth;
            // At least as long as it is wide.
            float tail = min(0.05 / min(1.0, depth + stretch), head - width / reach);
            if (r > head || r < tail) continue;
            float along = (r - tail) / max(head - tail, 0.0001);
            float core = smoothstep(width, 0.0, off);
            float brightness = core * (0.2 + 0.8 * along) * smoothstep(0.0, 0.25, progress) * mix(0.35, 1.0, 1.0 - depth);
            if (brightness > star) {
                star = brightness;
                starLight = mix(hue, half3(1.0), half(dark * 0.6 * along));
            }
        }
        star *= stars;
    }

    // The border over the stars, as light adds up.
    float alpha = min(1.0, edge + star * (1.0 - edge));
    half3 light = hue * half(edge) + starLight * half(star * (1.0 - edge));
    return half4(light, half(alpha));
}
