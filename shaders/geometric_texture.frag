#include <flutter/runtime_effect.glsl>

// Equilateral triangle grid with a radial accent-color gradient, plus an
// animated "wave" that periodically sweeps or expands across the grid and
// makes a noise-selected, clustered subset of triangles pop toward the
// viewer as it passes.
//
// Uses oblique (triangular lattice) coordinates so every triangle —
// both up (▲) and down (▽) — is painted with a single consistent color.
// Color is concentrated at u_focal_point and fades toward the edges.
//
// The popping triangles are modelled as physical tiles hinged to the grid:
// they pitch as they lift (never rising flat like an elevator), their mass
// lags behind the light that drives it, and they throw a shadow whose distance
// tracks their height.

uniform vec2  u_resolution;
uniform float u_scale;
uniform float u_intensity;    // Peak accent strength at the focal point (0–1)
uniform float u_focal_spread; // Gradient radius in aspect-corrected UV units
uniform vec2  u_focal_point;  // Focal point in normalized UV [0,1] for the accent gradient
uniform float u_variation_floor; // Minimum per-triangle shade (0–1); higher = fewer dark triangles
uniform vec4  u_base_color;   // Scaffold background color
uniform vec4  u_accent_color; // User accent color

// ── Wave animation ──────────────────────────────────────────────────────
uniform float u_time;              // Seconds, monotonically increasing
uniform float u_wave_enabled;      // 0 = off, 1 = on
uniform float u_wave_mode;         // 0 = linear sweep, 1 = radial expand
uniform vec2  u_wave_direction;    // Unit travel direction for linear sweep
uniform float u_wave_speed;        // Wavefront travel speed, UV units/sec
uniform float u_wave_width;        // Band thickness, UV units: how far apart
                                   // triangles' individual fire offsets spread
uniform float u_wave_period;       // Seconds between successive waves
uniform float u_pop_hold_time;     // Duration of one triangle's flash, seconds
                                   // (full width at half max)
uniform float u_pop_scale;         // Max apparent growth factor when popped
uniform float u_pop_brightness;    // Extra brightness burst when popped
uniform float u_mask_density;      // 0–1: fraction of eligible triangles that pop
uniform float u_mask_cluster_scale; // Noise frequency: lower = larger clusters
uniform float u_twinkle_sparsity;  // 0–1: fraction of eligible triangles that
                                   // actually fire on any one wavefront pass

// ── Lighting ────────────────────────────────────────────────────────────
uniform vec2  u_shadow_light_dir;  // Unit vector pointing *toward* the light
uniform float u_shadow_offset;     // How far a shadow is thrown per unit of
                                   // lift height, in triangle side lengths
uniform float u_shadow_softness;   // Silhouette edge falloff, in side lengths
uniform float u_shadow_strength;   // 0–1: how dark the shadow gets
uniform float u_pop_brightness_variance; // 0–1: how much a flash's peak
                                   // brightness is allowed to vary per pass

// ── Rotational lift (the hinge) ─────────────────────────────────────────
uniform float u_tilt_amount;       // 0–1: how far the tile pitches as it lifts.
                                   // 1 leaves the hinged edge flat on the grid
uniform float u_tilt_shading;      // 0–1: how strongly the pitch shows up as
                                   // brightness across the face

// ── Decoupled physics ───────────────────────────────────────────────────
uniform float u_mass_lag;          // Seconds the physical lift trails the flash
uniform float u_mass_spring;       // 0–1: overshoot/settle on the lift

// ── Scatter mode ────────────────────────────────────────────────────────
uniform float u_scatter_mode;      // 0 = travelling wave, 1 = even scatter
uniform float u_scatter_lit_amount; // 0–1: fraction of triangles lit at once

// ── Debug ─────────────────────────────────────────────────────────────────
uniform float u_debug_row_fade;    // 0 = off, 1 = row fade visualiser (dev only)

out vec4 fragColor;

// Row height for equilateral triangles with unit side length. Doubles as the
// conversion from barycentric depth to true distance from an edge — for a unit
// equilateral triangle the barycentric coordinate is the edge distance divided
// by the triangle's height, so multiplying by H converts back.
const float H = 0.8660254037844387; // sqrt(3) / 2
const float TAU = 6.283185307179586;
// A unit triangle's circumradius is 1/sqrt(3), so multiplying a centroid-
// relative distance by sqrt(3) puts the far corners at roughly ±1.
const float INV_CIRCUMRADIUS = 1.7320508075688772;

// One triangle of the lattice.
struct Tri {
    vec2  seed;    // hash seed — constant across the whole triangle
    vec2  centerA; // centroid, in aspect-corrected UV
    float depth;   // how far inside: 0 on an edge, 1/3 at the centroid
};

// Everything about one triangle's flash that both the light curve and the mass
// curve are derived from. Split out from the curves themselves so callers that
// only need one of the two don't pay for the other: the height field is
// evaluated twice per fragment by the shadow and wants mass, never light.
struct Wave {
    float phase;     // 0 = firing, 0.5 = fully dark. Runs *backwards* in time.
    float gate;      // fires * eligible * enabled — whether it flashes at all
    float brightVar; // per-pass peak brightness roll
    float holdFrac;  // flash duration as a fraction of the wave period
};

// Deterministic hash — unique float per triangle / noise lattice point
float hash1(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Smooth (Perlin-style) value noise built on the same hash — cheap, branchless,
// and continuous, which is what we need for organic clustered masking.
float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash1(i);
    float b = hash1(i + vec2(1.0, 0.0));
    float c = hash1(i + vec2(0.0, 1.0));
    float d = hash1(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// Slowly drifting per-triangle mode, in [0,1]: ~0 = dark, ~1 = regular.
//
// Each triangle has two modes — dark and regular. Every DRIFT_SECONDS it rolls a
// fresh binary target (a coin flip on a hash of the seed and the epoch index)
// and ramps linearly toward it over the first TRANSITION fraction of the epoch,
// then holds — a constant-velocity crossing that matches the debug row-fade
// visualiser. When two consecutive targets match, the triangle simply stays put;
// when they differ it crosses slowly, so a dark<->regular shift is always a
// gradual glide, never a snap. This is what keeps no triangle permanently dark
// while making every mode change slow.
//
// Consecutive epochs share their boundary value — the target of epoch k is the
// starting value of epoch k+1 — so the walk is continuous with no jumps. A
// per-triangle phase offset desyncs the grid so it never shifts in unison.
//
// Driven by u_time, which is frozen while the background isn't animating, so a
// static background keeps a static mode.
float driftingMode(vec2 seed) {
    const float DRIFT_SECONDS = 18.0;
    const float TRANSITION = 0.35; // fraction of an epoch spent crossing modes
    float phase = u_time / DRIFT_SECONDS + hash1(seed + 5.0);
    float k = floor(phase);
    float f = fract(phase);
    float prev = step(0.5, hash1(seed + vec2(k, k * 1.7) + 0.5));
    float curr = step(0.5, hash1(seed + vec2(k + 1.0, (k + 1.0) * 1.7) + 0.5));
    return mix(prev, curr, clamp(f / TRANSITION, 0.0, 1.0));
}

// Oblique (triangular lattice) coordinates → aspect-corrected UV.
// Lattice basis: e1 = (1, 0), e2 = (0.5, H) in Cartesian.
vec2 obliqueToUvA(vec2 st) {
    return vec2(st.x + 0.5 * st.y, H * st.y) / u_scale;
}

// Resolve the triangle containing lattice-space point `p`.
//
// Each oblique cell (s0, t0) contains exactly two equilateral triangles:
//   ls + lt < 1  →  up-triangle   (▲) with vertices at the three
//                    corners (s0,t0), (s0+1,t0), (s0,t0+1)
//   ls + lt > 1  →  down-triangle (▽) with vertices at (s0+1,t0),
//                    (s0,t0+1), (s0+1,t0+1)
//
// Because each triangle lies entirely within one oblique cell, every pixel in
// a given triangle maps to the same hash seed — eliminating the seam artifacts
// that appear when using staggered rectangular cells.
//
// `depth` is continuous across edges: every triangle's depth falls to 0 at its
// own boundary exactly where its neighbour's rises from 0. Everything built on
// top of this relies on that property to stay seam-free.
Tri resolveTriangle(vec2 p) {
    // Convert Cartesian to oblique coordinates.
    // Inverse transform: s = x − y / (2H), t = y / H.
    float s = p.x - p.y / (2.0 * H);
    float t = p.y / H;

    float s0 = floor(s);
    float t0 = floor(t);
    float ls = s - s0;  // local s in [0, 1)
    float lt = t - t0;  // local t in [0, 1)

    bool isUp = (ls + lt) < 1.0;

    Tri tri;
    tri.seed  = isUp ? vec2(s0, t0) : vec2(s0 + 0.5, t0 + 0.5);
    tri.depth = isUp ? min(ls, min(lt, 1.0 - ls - lt))
                     : min(1.0 - ls, min(1.0 - lt, ls + lt - 1.0));
    tri.centerA = obliqueToUvA(isUp ? vec2(s0 + 1.0 / 3.0, t0 + 1.0 / 3.0)
                                    : vec2(s0 + 2.0 / 3.0, t0 + 2.0 / 3.0));
    return tri;
}

// ── Traveling wave train ────────────────────────────────────────────────
// Per-triangle wave state, keyed on the triangle's hash seed and its centroid.
//
// Evaluated per *triangle*, not per fragment — the wave coordinate comes from
// the centroid, so every pixel of a triangle shares one flash. That also lets a
// fragment ask the same question about a *neighbouring* triangle, which is what
// makes the cast shadow possible at all.
//
// Wavefronts depart from a point just off-screen past the top-right corner and
// travel at u_wave_speed, either along u_wave_direction (linear sweep) or
// radially (expanding ring). This origin is intentionally independent of
// u_focal_point — the accent gradient's focal point can sit anywhere on screen
// (even dead center), and anchoring the wave to it would leave everything on
// the wave's "trailing" side permanently unreachable. Anchoring off-screen at a
// corner guarantees every on-screen triangle is out ahead of it.
//
// The train repeats every u_wave_speed * u_wave_period units, so at large
// periods there's effectively one front on screen at a time and at small
// periods several evenly-spaced fronts are visible at once.
Wave waveFor(vec2 seed, vec2 centerA) {
    float aspect = u_resolution.x / u_resolution.y;

    // ── Organic mask ─────────────────────────────────────────────────────
    // Overlay smooth noise on the wave so only a clustered, irregular subset
    // of triangles are ever eligible to pop — avoids a uniform, rigid look.
    // Scatter mode bypasses it: an even spread across the screen is the whole
    // point there, and this way the wave's clustering stays tuned independently.
    float maskNoise      = valueNoise(seed * max(u_mask_cluster_scale, 0.0001));
    float maskThreshold  = 1.0 - clamp(u_mask_density, 0.0, 1.0);
    float clustered      = smoothstep(maskThreshold - 0.12, maskThreshold + 0.12, maskNoise);
    float eligibility    = mix(clustered, 1.0, u_scatter_mode);

    vec2  dirN        = normalize(vec2(u_wave_direction.x * aspect, u_wave_direction.y));
    vec2  originA     = vec2(aspect + 0.25, -0.25);
    float coordLinear = dot(centerA - originA, dirN);
    float coordRadial = distance(centerA, originA);
    float coord       = mix(coordLinear, coordRadial, u_wave_mode);

    // ── Cycle length ─────────────────────────────────────────────────────
    // In wave mode this is the spacing between wavefronts. In scatter mode
    // there are no wavefronts, so it becomes how often one triangle comes back
    // around to fire — and it is *derived* rather than exposed, to keep two
    // knobs that would otherwise fight from fighting.
    //
    // At any instant,  lit fraction = P(fires) * hold / interval.
    //
    // Solving that for the interval makes the lit fraction exactly
    // u_scatter_lit_amount and, crucially, independent of u_pop_hold_time:
    // stretch the hold and the interval stretches with it, so flashes slow down
    // without any more of them being lit at once.
    //
    // P(fires) is fixed rather than exposed because it is doing one specific
    // job. Without it every triangle fires on every cycle at its own fixed
    // random phase, so the same constellation of triangles relights in the same
    // order every interval — a loop the eye eventually catches. Re-rolling half
    // of them per cycle breaks it. Half also caps the lit fraction at 0.5 of
    // the cycle, which is what keeps flashes distinct rather than smearing into
    // a constant glow.
    const float SCATTER_FIRE_P = 0.5;

    float wavePeriod    = max(u_wave_period, 0.0001);
    float scatterPeriod = max(SCATTER_FIRE_P * u_pop_hold_time
                              / max(u_scatter_lit_amount, 0.002), 0.0001);
    float periodSafe = mix(wavePeriod, scatterPeriod, u_scatter_mode);
    float wavelength = max(u_wave_speed * periodSafe, 0.0001);

    // Travel phase is measured in wavelengths — every whole number is a
    // wavefront. Two versions of the time term are needed. tFrac is reduced
    // modulo the period: the pulse below only ever needs the phase modulo 1,
    // and u_time grows without bound, so feeding it in raw would quantize the
    // animation into visible steps once the app had been open a while. tRaw is
    // the unreduced count, used only for the integer wavefront index — that
    // one has to keep counting up, because tFrac silently jumps by a whole
    // period every time it wraps.
    float tFrac = mod(u_time, periodSafe) / periodSafe;
    float tRaw  = u_time / periodSafe;

    // ── Per-triangle flash ───────────────────────────────────────────────
    // Each triangle fires at most once per passing wavefront, at its own
    // random offset within the band, rather than in lockstep with the front —
    // that lockstep is what reads as a solid traveling line instead of
    // individual triangles. The offsets span u_wave_width, so that slider
    // directly sets how thick the band of sparkles is.
    //
    // The offsets are drawn from a triangular (tent) distribution, not a
    // uniform one: uniform offsets spread the firings evenly right up to the
    // band's limits, giving it a flat top and hard edges. A tent concentrates
    // them at the wavefront and tapers off to nothing at the band's edges, so
    // the sparkle density falls away smoothly on both sides.
    float bandFrac   = clamp(u_wave_width / wavelength, 0.0, 2.0);
    float bell       = (hash1(seed + 3.7) + hash1(seed + 11.3) - 1.0) * 0.5;
    float waveOffset = coord / wavelength + bell * bandFrac;

    // Scatter mode: the phase is pure per-triangle randomness with no spatial
    // term at all. That single substitution is the whole mode — strip out the
    // "where am I along the wave" and triangles stop firing as a travelling
    // band and start firing independently, evenly, all over the screen.
    float scatterOffset = hash1(seed + 61.7);
    float offset = mix(waveOffset, scatterOffset, u_scatter_mode);

    float phase = fract(offset - tFrac);      // 0 = firing, 0.5 = fully dark
    float pass  = floor(offset - tRaw + 0.5); // index of the cycle it rides

    // Only a fraction of eligible triangles fire on any one pass, re-rolled
    // per pass so a different scatter lights up on each sweep. Without this
    // every eligible triangle in the band lights simultaneously and the wave
    // reads as one solid slab of light. The roll is keyed on `pass`, which
    // stays constant across a whole flash and only ever changes at phase = 0.5
    // where the pulse is exactly zero — so a re-roll can never pop mid-glow.
    float fireHash = hash1(seed * 1.37 + vec2(pass, pass * 0.61) + 4.9);
    float fireThreshold = mix(1.0 - clamp(u_twinkle_sparsity, 0.0, 1.0),
                              1.0 - SCATTER_FIRE_P, u_scatter_mode);
    float fires = step(fireThreshold, fireHash);

    // How hard this triangle flares, re-rolled every wavefront on the same
    // index as `fires`, so the same triangle flares hard on one wave and barely
    // glows on the next. A fixed per-triangle brightness instead reads as a
    // static pattern baked into the grid.
    float brightHash = hash1(seed * 2.11 + vec2(pass * 0.83, pass) + 17.3);

    Wave w;
    w.phase     = phase;
    w.gate      = fires * eligibility * u_wave_enabled;
    w.brightVar = mix(1.0 - clamp(u_pop_brightness_variance, 0.0, 1.0), 1.0, brightHash);
    w.holdFrac  = clamp(u_pop_hold_time / periodSafe, 0.004, 1.0);
    return w;
}

// Shapes one side of a pulse. pow(0.5 + 0.5*cos(TAU*f), k) falls to half its
// peak sqrt(ln2/k)/PI periods from the centre, so this inverts that to size a
// half-width. Clamped at the top for float precision (pow's log2 loses the peak
// past ~1e4) and at the bottom so an extreme hold can't invert the pulse into
// a spike.
float pulsePower(float halfWidth, float floorK) {
    const float LN2_OVER_PI_SQ = 0.0702305;
    return clamp(LN2_OVER_PI_SQ / (halfWidth * halfWidth), floorK, 8000.0);
}

// Evaluates the two-sided pulse at phase `f`. The two sides agree where they
// meet — at the peak the base is 1 and pow(1, k) == 1 for either power, at the
// trough the base is 0 and pow(0, k) == 0 for either — so the only
// discontinuity is the intended kink at the peak, which *is* the attack.
//
// Being periodic by construction, a triangle that fires late at the band's
// trailing edge always finishes its decay rather than being chopped off when
// the wavefront moves on.
//
// `f` runs *backwards* in time (it's fract of a term that time is subtracted
// from), so the wavefront is still approaching over f in (0, 0.5) and has
// already passed over f in (0.5, 1) — attack is the low half, decay the high
// half. step(f, 0.5) is 1 on the attack side.
float pulseAt(float f, float kRise, float kDecay) {
    float k = mix(kDecay, kRise, step(f, 0.5));
    // max() guards pow: the cosine can round a hair below -1, and pow() with a
    // negative base is undefined — it would spray NaN pixels at the trough.
    return pow(max(0.5 + 0.5 * cos(TAU * f), 0.0), k);
}

// ── Photons ─────────────────────────────────────────────────────────────
// Light is energy: it snaps on and eases off. The decay runs three times the
// attack, and the two half-widths sum to u_pop_hold_time. This asymmetry is
// most of what separates "this is lighting up" from "this is a UI fade".
float lightOf(Wave w) {
    float kRise  = pulsePower(w.holdFrac * 0.25, 0.75);
    float kDecay = pulsePower(w.holdFrac * 0.75, 0.12);
    return pulseAt(w.phase, kRise, kDecay) * w.gate * w.brightVar;
}

// ── Shade lead-in ─────────────────────────────────────────────────────────
// A dark triangle should not have its darkness overridden the instant its flash
// fires — that snap is the artifact. This is a much wider, gentler envelope on
// the *same* flash than the sharp light pulse above: a triangle eases its base
// shade up to the normal (undarkened) shade over a gradual lead-in as its flash
// approaches, then eases back to its drifting shade afterward.
//
// The half-widths are absolute phase fractions, not multiples of the flash
// hold, so the lead-in stays gradual regardless of how brief the flash itself
// is. The approach is wider than the settle, so the rise to normal is slow (the
// part that was snapping) while the return to the drift shade is a touch
// quicker. Multiplied by the same fire/eligibility gate as the flash, so only
// triangles that actually flash lift, and only around the moment they do —
// pulseAt is exactly 0 at phase 0.5 where the gate can re-roll, so no seam.
float shadeLiftOf(Wave w) {
    float kApproach = pulsePower(0.20, 0.05); // wide → slow dark→normal lead-in
    float kSettle   = pulsePower(0.12, 0.05); // narrower → quicker return after
    return pulseAt(w.phase, kApproach, kSettle) * w.gate;
}

// ── Matter ──────────────────────────────────────────────────────────────
// Mass is not light. It has inertia, so it cannot snap: the lift trails the
// flash by u_mass_lag, eases in over twice the light's attack, overshoots its
// target and settles back. Running the tile's movement on the same curve as its
// glow is what collapses the two into a single flat layer; separating them lets
// the eye read an energy wave passing through a physical object.
//
// Deliberately free of `brightVar` — how brightly a tile flares says nothing
// about how far it moves.
float massOf(Wave w) {
    float periodSafe = max(u_wave_period, 0.0001);

    // The lift peaks later in time than the flash. Phase runs backwards, so a
    // later peak is a *larger* phase — hence the addition.
    float lagFrac = clamp(u_mass_lag / periodSafe, 0.0, 0.5);
    float fm      = fract(w.phase + lagFrac);

    float kRise  = pulsePower(w.holdFrac * 0.5, 0.35);  // 2x the light's attack
    float kDecay = pulsePower(w.holdFrac * 0.75, 0.12); // same settle as light
    float pulse  = pulseAt(fm, kRise, kDecay);

    // Micro-spring: one damped wobble riding the decay so the tile settles
    // instead of gliding to a stop. `tp` is time since the lift peaked, in hold
    // widths, and is only meaningful past the peak — hence the decay-side gate.
    // Both ends stay continuous: sin(0) is 0 right at the peak, and the pulse
    // itself is exactly 0 at the trough where the gate switches.
    float tp     = (1.0 - fm) / max(w.holdFrac, 0.0001);
    float ripple = clamp(u_mass_spring, 0.0, 1.0) * step(0.5, fm)
                 * exp(-2.0 * tp) * sin(TAU * 0.75 * tp);

    // Allowed past 1: that overshoot is the whole point of the spring.
    return clamp(pulse * (1.0 + ripple), 0.0, 1.5) * w.gate;
}

// ── The hinge ───────────────────────────────────────────────────────────
// Each triangle's permanent uphill direction. Fixed per triangle and never
// re-rolled per pass, because a hinge is a property of the object, not of the
// event — a tile that pitches a new way on every wave isn't hinged to anything.
// The result is a fixed tilt "grain" baked into the grid.
vec2 hingeDir(vec2 seed) {
    float a = hash1(seed + 23.17) * TAU;
    return vec2(cos(a), sin(a));
}

// How far along the hinge's uphill direction `p` sits, as roughly ±1 across the
// face. Positive on the raised side, negative on the hinged side.
float tiltTermAt(vec2 p, Tri tri) {
    return dot(p - tri.centerA * u_scale, hingeDir(tri.seed)) * INV_CIRCUMRADIUS;
}

// Surface height at `p`, in lift units: 0 = flat on the grid, 1 = a fully
// popped tile's centre. The hinge redistributes height across the face — up on
// one side, down on the other — without changing the tile's average lift, so it
// pitches rather than riding an elevator straight up.
float liftAt(vec2 p, Tri tri, float mass) {
    float tilt = clamp(u_tilt_amount, 0.0, 1.0);
    return max(mass * (1.0 + tilt * tiltTermAt(p, tri)), 0.0);
}

// A tile's silhouette fades out at its own edges. This is what makes the height
// field continuous: each triangle's contribution falls to 0 exactly where its
// neighbour's begins, so the shadow's iteration below can never snap between
// triangles and etch a seam across the grid.
float taperOf(Tri tri) {
    return smoothstep(0.0, max(u_shadow_softness, 0.0001), tri.depth * H);
}

// The continuous height field over the whole grid — the surface everything
// physical is resolved against.
float heightFieldAt(vec2 p) {
    Tri tri = resolveTriangle(p);
    return liftAt(p, tri, massOf(waveFor(tri.seed, tri.centerA))) * taperOf(tri);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / u_resolution.xy;
    float aspect = u_resolution.x / u_resolution.y;

    // Aspect-correct both the triangle grid and the gradient so neither
    // stretches horizontally on wide screens.
    vec2 uvA    = vec2(uv.x * aspect, uv.y);
    vec2 focalA = vec2(u_focal_point.x * aspect, u_focal_point.y);

    // ── Equilateral triangle grid (oblique coordinates) ───────────────────
    // Lattice space: uvA scaled up so one triangle side is exactly 1 unit.
    // Because uvA is isotropic, so is this — a screen-space unit vector stays
    // a unit vector here, which is what lets the light direction below be used
    // as a lattice offset directly.
    vec2 pos = uvA * u_scale;

    Tri  self  = resolveTriangle(pos);

    // ── Debug: row fade visualiser ────────────────────────────────────────
    // Dev-only mode that clears the background and paints clean horizontal rows,
    // each one cycling dark -> regular -> dark so the exact transition is visible
    // in isolation — no gradient, flashes or shadows. It dwells on each shade
    // (HOLD) and ramps linearly between them, so the shade changes at a constant
    // rate across the whole transition rather than easing in and out at the
    // ends. Adjacent rows sit half a cycle apart, so one holds
    // dark while its neighbour holds regular. Rows are the lattice t-bands, so
    // both the up and down triangle in a band share one shade.
    if (u_debug_row_fade > 0.5) {
        float rowParity = mod(floor(self.seed.y), 2.0);
        const float FADE  = 3.0; // seconds to fade between the two shades
        const float HOLD  = 1.5; // seconds dwelling on each shade
        const float CYCLE = 2.0 * (FADE + HOLD);
        float t = mod(u_time + rowParity * (FADE + HOLD), CYCLE);
        float mode;
        if (t < HOLD) {
            mode = 0.0;                                     // hold dark
        } else if (t < HOLD + FADE) {
            mode = (t - HOLD) / FADE;                       // dark -> regular (linear)
        } else if (t < 2.0 * HOLD + FADE) {
            mode = 1.0;                                     // hold regular
        } else {
            mode = 1.0 - (t - 2.0 * HOLD - FADE) / FADE;    // regular -> dark (linear)
        }
        // Render the two shades exactly as the real grid does, so the visualiser
        // stays faithful: `mode` drives `variation` between the dark floor and
        // the regular shade, and the same 0.08 ambient factor maps it to screen.
        // A dark row shows the darkest shade a real triangle ever takes
        // (u_variation_floor); a regular row shows the default background shade
        // (variation 1.0). No focal burst here, so no accent wash.
        //
        // That real range spans only ~4 8-bit levels, so the fade would quantize
        // into visible steps ("clicks"). A triangular-PDF ordered dither of ±1
        // LSB, keyed on the fragment position, scatters the quantization across
        // neighbouring pixels so the smooth `mode` ramp reads as a smooth fade —
        // at the cost of very faint static grain. The curve being inspected still
        // lives entirely in `mode`; the dither only affects how it is displayed.
        float variation = mix(u_variation_floor, 1.0, mode);
        float intensity = variation * 0.08;
        vec3  shade  = mix(u_base_color.rgb, u_accent_color.rgb, intensity);
        vec2  dseed  = FlutterFragCoord().xy;
        float dither = (hash1(dseed) + hash1(dseed + 17.3) - 1.0) * (1.0 / 255.0);
        fragColor = vec4(shade + dither, 1.0);
        return;
    }

    Wave wave  = waveFor(self.seed, self.centerA);
    float light = lightOf(wave);
    float mass  = massOf(wave);

    // Each triangle sits in one of two modes — dark (u_variation_floor) or
    // regular (1.0) — that slowly drift between each other over time (see
    // driftingMode), so no triangle stays permanently dark and every shift is a
    // gradual glide. A small static per-triangle jitter keeps a little of the
    // speckle texture within each mode rather than one flat value.
    float mode   = driftingMode(self.seed);
    float jitter = (hash1(self.seed + 2.0) - 0.5) * 0.08;
    float variationBase = clamp(mix(u_variation_floor, 1.0, mode) + jitter,
                                u_variation_floor, 1.0);
    // Before a dark triangle flashes it must first ease all the way up to the
    // regular shade; shadeLiftOf is that gradual lead-in (and eases back after).
    // At the flash itself shadeLiftOf is 1, so the triangle is fully regular no
    // matter which mode it was in. Everything shade-dependent below (ambient,
    // burst) reads this lifted value.
    float variation = mix(variationBase, 1.0, shadeLiftOf(wave));

    // ── Radial gradient ───────────────────────────────────────────────────
    float dist     = distance(uvA, focalA);
    float gradient = smoothstep(u_focal_spread, 0.0, dist);

    // Subtle ambient shimmer: triangles are faintly visible everywhere. Kept in
    // scatter mode on purpose — it's what leaves a surface for the flashes to
    // happen *on*, rather than sparks appearing out of a void.
    float ambient = variation * 0.08;

    // Focal burst: full accent tint concentrated at the focal point. Scatter
    // mode drops it entirely, so the twinkles are the only accent on screen.
    // (This also makes the texture panel's intensity and focal sliders inert
    // while scatter is on — they only ever drove this term.)
    float burst = gradient * variation * u_intensity * (1.0 - u_scatter_mode);

    // ── Hinge shading ─────────────────────────────────────────────────────
    // Two separate things happen when a face pitches, and they are not the same
    // effect. It turns toward or away from the light, which shifts the *whole*
    // face by one amount; and its raised side ends up nearer the light than its
    // hinged side, which is a gradient *across* the face. A flat plane tilting
    // under a directional light only ever gets the first — its normal is
    // uniform, so Lambert shading alone can never produce a gradient. The
    // second term is what actually reads as a micro-gradient, so both are here.
    //
    // Scaled by mass, not light: while the flash is ahead of the lift, the face
    // is still flat and shades evenly. The gradient only develops as the tile
    // physically pitches, which is the decoupling made visible.
    vec2  toLight    = normalize(u_shadow_light_dir);
    float tiltFacing = dot(hingeDir(self.seed), toLight);
    float tiltShade  = clamp(u_tilt_shading, 0.0, 1.0) * clamp(u_tilt_amount, 0.0, 1.0)
                     * mass * (tiltFacing + tiltTermAt(pos, self)) * 0.5;

    // ── Cast shadow ───────────────────────────────────────────────────────
    // A shadow is thrown u_shadow_offset per unit of height, measured against
    // whatever it lands on — so the caster occluding this fragment satisfies
    //
    //     C = pos - shadowDir * offset * (height(C) - heightHere)
    //
    // which is implicit in C. Solve it by iteration: guess a full-height caster,
    // then correct once. Two evaluations suffice because the offset is small and
    // the field is smooth, and because every term is continuous the correction
    // can't snap between triangles.
    //
    // Using the height *difference* rather than the caster's height alone is
    // what keeps a tile from shading its own face at any pitch: on a plane the
    // difference resolves to zero, so the iteration collapses back to C = pos
    // and there is nothing to cast.
    vec2  shadowDir = -toLight;
    float heightHere = liftAt(pos, self, mass) * taperOf(self);

    float off = max(u_shadow_offset, 0.0);
    vec2  c0 = pos - shadowDir * off * (1.0 - heightHere);
    float h0 = heightFieldAt(c0);
    vec2  c1 = pos - shadowDir * off * clamp(h0 - heightHere, 0.0, 1.5);
    float h1 = heightFieldAt(c1);

    // Shadow lands only where the caster rides higher than the receiver. The
    // pitch falls out of this for free: the raised corner is higher, so it
    // throws further and darker, while the hinged corner sits on the grid and
    // throws almost nothing.
    float occlusion = clamp(h1 - heightHere, 0.0, 1.0);

    // ── Final color ───────────────────────────────────────────────────────
    // The flash itself is a full, uniform pop: by the time it fires the triangle
    // has already eased up to the normal shade (see shadeLiftOf), so there is no
    // residual darkness left for the flash to "catch up" over.
    float burstBoost = light * u_pop_brightness * (1.0 + tiltShade);
    float totalIntensity = clamp(ambient + burst + burstBoost, 0.0, 1.0);
    vec3  color = mix(u_base_color.rgb, u_accent_color.rgb, totalIntensity);
    // Faint highlight right at peak pop, reinforcing the "lift" cue without
    // flashing all the way to white.
    color = mix(color, vec3(1.0), burstBoost * 0.12);

    // Triangles tile edge-to-edge with no grout: adjacent faces meet exactly at
    // the lattice boundary where each triangle's depth falls to 0, so there is
    // no hairline gap between them at any pop state.
    //
    // u_pop_scale (the old "grow to fill the cell" factor) is intentionally left
    // unreferenced here. It stays a live, DB-backed parameter and its uniform
    // slot is still written by GeometricTexturePainter, so the layout Dart
    // addresses by index is unchanged — it simply no longer drives a seam.

    // Shadow darkens the low points between triangles — exactly where a lifted
    // tile's shadow should read most clearly.
    color *= 1.0 - clamp(u_shadow_strength, 0.0, 1.0) * occlusion;

    // Match the debug row-fade view: the drift between the dark and regular
    // shades spans only a few 8-bit levels, so without dither it bands into
    // visible steps as a triangle drifts. The same triangular-PDF ±1 LSB dither
    // the visualiser uses scatters the quantization so the whole background —
    // drift, accent gradient and shadows alike — renders smoothly.
    vec2  dseed  = FlutterFragCoord().xy;
    float dither = (hash1(dseed) + hash1(dseed + 17.3) - 1.0) * (1.0 / 255.0);
    fragColor = vec4(color + dither, 1.0);
}
