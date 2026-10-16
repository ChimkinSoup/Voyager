import 'dart:math' as math;
import 'dart:ui';

/// Weeping cherry (shidarezakura) for the Life Tracker — pure data in "tree
/// space", generated once and scaled at paint time.
///
/// Tree space is square: x runs from about -0.85 to 0.85 with the trunk at 0,
/// y from 0 at the top to [weepingGroundY] at the ground. The painter maps it
/// onto the canvas by height, so a wide window adds sky either side rather
/// than stretching the tree.

const weepingGroundY = 0.90;

/// How many vertical slices the blossom is baked into. Each slice sways on its
/// own phase, so a breeze reads as passing across the curtain rather than the
/// whole tree rocking as one sheet.
const weepingBandCount = 14;

const _bandMinX = -0.95;
const _bandMaxX = 0.95;

int weepingBandFor(double x) =>
    (((x - _bandMinX) / (_bandMaxX - _bandMinX)) * weepingBandCount)
        .floor()
        .clamp(0, weepingBandCount - 1);

/// A woody limb as a smoothed centre line with a width at every point — a
/// polyline rather than one bezier, because cherry wood kinks and zigzags at
/// every node instead of bending in one clean arc.
class CherryLimb {
  const CherryLimb(this.points, this.widths);

  final List<Offset> points;
  final List<double> widths;
}

/// One hanging branchlet: the thin whip that arches off a limb and falls
/// under its own weight.
class CherryStrand {
  const CherryStrand({
    required this.points,
    required this.width,
    required this.front,
    required this.band,
  });

  final List<Offset> points;
  final double width;

  /// Painted over the trunk rather than behind it.
  final bool front;
  final int band;
}

/// One pool of blossom pigment with a scatter of petals on top of it.
class BlossomCluster {
  const BlossomCluster({
    required this.center,
    required this.radius,
    required this.depth,
    required this.front,
    required this.band,
    required this.seed,
    required this.wet,
  });

  final Offset center;
  final double radius;

  /// 0 for the far side of the crown, 1 for the nearest. Far blossom sinks
  /// into dusky mauve, near blossom catches the light.
  final double depth;
  final bool front;
  final int band;
  final int seed;

  /// Laid wet-in-wet — a soft blurred bloom instead of a hard dried edge.
  final bool wet;
}

/// One of the 4160 weeks of an 80-year life, as a petal on the curtain. The
/// weeks already lived fall to the ground.
class WeekPetal {
  const WeekPetal({
    required this.position,
    required this.cluster,
    required this.size,
    required this.tone,
    required this.squash,
    required this.rotation,
    required this.groundSize,
    required this.phase,
  });

  /// Where it hangs on the tree, in tree space.
  final Offset position;

  /// Index into [WeepingCherryGeometry.clusters] — the pool of pigment it
  /// belongs to, which fades as its petals leave.
  final int cluster;
  final double size;
  final int tone;

  /// Which pre-squashed sprite it hangs as, so the curtain's petals face
  /// every which way.
  final int squash;
  final double rotation;

  /// Its size once off the tree and seen up close.
  final double groundSize;

  /// Seeds its flutter on the way down.
  final double phase;
}

class WeepingCherryGeometry {
  WeepingCherryGeometry({
    required this.limbs,
    required this.strands,
    required this.clusters,
    required this.bandPivots,
    required this.weekPetals,
    required this.petalsByAngle,
  });

  /// Trunk, root flares, scaffold limbs and twigs.
  final List<CherryLimb> limbs;
  final List<CherryStrand> strands;

  /// Back to front.
  final List<BlossomCluster> clusters;

  /// The y each band sways about — roughly where its strands leave the wood,
  /// so the attachment holds still and the tips swing.
  final List<double> bandPivots;

  final List<WeekPetal> weekPetals;

  /// [weekPetals] ordered by angle around the crown, so the weeks lived can
  /// be picked at an even stride and the canopy thins all over at once rather
  /// than from one side.
  final List<int> petalsByAngle;

  /// The petals for the first [weeks] weeks, evenly spread over the tree.
  List<int> livedPetals(int weeks) {
    final count = weeks.clamp(0, petalsByAngle.length);
    if (count == 0) return const [];
    final stride = petalsByAngle.length / count;
    return [
      for (var i = 0; i < count; i++) petalsByAngle[(i * stride).floor()],
    ];
  }
}

const weekPetalCount = 4160;

/// How many sprite squash levels a petal can be drawn at — see
/// [WeekPetal.squash].
const petalSquashLevels = 5;
const petalToneCount = 4;

const _seed = 20261011;

WeepingCherryGeometry generateWeepingCherryGeometry() {
  final rand = math.Random(_seed);
  final limbs = <CherryLimb>[];

  // Trunk: one gentle bow up to a low fork, flared at the foot, as old
  // weeping cherries are grafted high and carry their crown on a short,
  // heavy stem. A single curve — zigzagging the centre line reads as a kink.
  const fork = Offset(-0.012, 0.50);
  limbs.add(
    _smooth(
      const [
        Offset(0.024, 0.905),
        Offset(0.024, 0.800),
        Offset(0.017, 0.700),
        Offset(0.005, 0.600),
        fork,
      ],
      const [0.108, 0.072, 0.062, 0.056, 0.050],
    ),
  );

  // Root flares, splayed along the ground so the trunk sits in the earth.
  for (final flare in const [
    [Offset(0.000, 0.866), Offset(-0.070, 0.886), Offset(-0.150, 0.897)],
    [Offset(0.010, 0.874), Offset(-0.030, 0.890), Offset(-0.070, 0.899)],
    [Offset(0.040, 0.870), Offset(0.100, 0.888), Offset(0.180, 0.896)],
    [Offset(0.030, 0.878), Offset(0.065, 0.892), Offset(0.095, 0.899)],
  ]) {
    final heavy = (flare.last.dx).abs() > 0.12;
    limbs.add(
      _smooth(flare, [heavy ? 0.034 : 0.022, heavy ? 0.016 : 0.010, 0.002]),
    );
  }

  // Scaffold limbs. Each rises from the fork and arches outward into the
  // umbrella the strands hang from: (angle from vertical, length, width).
  const scaffolds = <(double, double, double)>[
    (-1.10, 0.44, 0.030),
    (-0.58, 0.52, 0.036),
    (-0.16, 0.50, 0.034),
    (0.14, 0.50, 0.034),
    (0.52, 0.52, 0.036),
    (1.02, 0.44, 0.030),
  ];

  // Points the strands can spring from, with the direction the wood was
  // growing in there.
  final sprouts = <(Offset, Offset)>[];

  // Each scaffold's raw centre line, for the twigs that fill the heart.
  final arms = <List<Offset>>[];

  void grow(
    Offset start,
    double angle,
    double length,
    double width,
    int depth,
  ) {
    const steps = 6;
    final points = <Offset>[start];
    final widths = <double>[width];
    var a = angle;
    var p = start;
    final side = angle == 0 ? 1.0 : angle.sign;
    for (var i = 1; i <= steps; i++) {
      // Bend outward as it goes, plus an alternating kink at each node.
      a +=
          side * (0.10 + depth * 0.05) +
          (i.isEven ? 1 : -1) * (0.10 + rand.nextDouble() * 0.16);
      // No further than just past level — the wood holds the umbrella up;
      // only the whips hang.
      a = a.clamp(-1.75, 1.75);
      p += Offset(math.sin(a), -math.cos(a)) * (length / steps);
      points.add(p);
      widths.add(width * (1 - 0.82 * i / steps));
    }
    limbs.add(_smooth(points, widths));
    if (depth == 0) arms.add(points);

    // Sprouts from the outer half onward — the whips come off the arch, not
    // the stout base of the limb.
    for (var i = 2; i < points.length; i++) {
      final dir = points[i] - points[i - 1];
      sprouts.add((points[i], dir / dir.distance));
    }

    if (depth >= 2) return;
    final children = depth == 0 ? 2 : 1 + rand.nextInt(2);
    for (var c = 0; c < children; c++) {
      final at = 2 + rand.nextInt(steps - 2);
      final dir = points[at] - points[at - 1];
      final baseAngle = math.atan2(dir.dx, -dir.dy);
      final turn = (c.isEven ? 1 : -1) * (0.45 + rand.nextDouble() * 0.35);
      grow(
        points[at],
        baseAngle + turn,
        length * (0.45 + rand.nextDouble() * 0.20),
        widths[at] * 0.85,
        depth + 1,
      );
    }
  }

  for (final (angle, length, width) in scaffolds) {
    grow(fork, angle + (rand.nextDouble() - 0.5) * 0.1, length, width, 0);
  }

  // Strands. Each leaves the wood heading the way the limb was growing, then
  // gravity takes over and it falls into a near-vertical whip — which is the
  // whole silhouette of a weeping cherry.
  final strands = <CherryStrand>[];
  final clusters = <BlossomCluster>[];
  const strandCount = 170;
  for (var i = 0; i < strandCount; i++) {
    final (origin, dir) = sprouts[rand.nextInt(sprouts.length)];
    // Outer strands hang longest; the ones near the trunk are short, so the
    // curtain opens into a skirt instead of a solid column.
    final reach = (origin.dx.abs() / 0.6).clamp(0.0, 1.0);
    final bottom =
        weepingGroundY - 0.03 - (1 - reach) * 0.28 - rand.nextDouble() * 0.16;
    // Jittered launch, so whips sharing a sprout fan apart instead of
    // stacking on one path.
    final spread = (rand.nextDouble() - 0.5) * 0.9;
    final kick = 0.9 + rand.nextDouble() * 0.9;
    var v = Offset(
      (dir.dx * math.cos(spread) - dir.dy * math.sin(spread)) * 1.4 * kick,
      math.min(dir.dx * math.sin(spread) + dir.dy * math.cos(spread), -0.2) *
          kick,
    );
    var p = origin;
    final points = <Offset>[p];
    const ds = 0.010;
    final wobble = rand.nextDouble() * math.pi * 2;
    while (p.dy < bottom && points.length < 120) {
      v = Offset(v.dx * 0.93, v.dy + 0.11);
      final n = v / v.distance;
      p += n * ds;
      points.add(
        p + Offset(math.sin(points.length * 0.22 + wobble) * 0.0012, 0),
      );
    }
    if (points.length < 4) continue;
    final front = rand.nextDouble() < 0.5;
    final band = weepingBandFor(origin.dx);
    strands.add(
      CherryStrand(
        points: points,
        width: 0.0016 + rand.nextDouble() * 0.0010,
        front: front,
        band: band,
      ),
    );

    // Blossom along the strand: full near the arch, thinning to sparse buds
    // at the tip.
    final depthBase = front
        ? 0.55 + rand.nextDouble() * 0.45
        : rand.nextDouble() * 0.5;
    var walk = rand.nextDouble() * 2;
    while (walk < points.length - 1) {
      final u = walk / (points.length - 1);
      final at = points[walk.floor()];
      if (rand.nextDouble() > u * u * 0.85) {
        clusters.add(
          BlossomCluster(
            center:
                at +
                Offset(
                  (rand.nextDouble() - 0.5) * 0.014,
                  (rand.nextDouble() - 0.5) * 0.006,
                ),
            radius:
                (0.010 + rand.nextDouble() * 0.010) *
                (1 - 0.55 * u) *
                (0.65 + 0.35 * reach),
            depth: (depthBase + (rand.nextDouble() - 0.5) * 0.15).clamp(
              0.0,
              1.0,
            ),
            front: front,
            band: band,
            seed: rand.nextInt(1 << 30),
            wet: rand.nextDouble() < 0.12,
          ),
        );
      }
      walk += 1.0 + rand.nextDouble() * 1.4;
    }
  }

  // The crown: heavier pools massed over the arches so the top reads as a
  // dome of bloom the curtain pours out of.
  for (final (origin, dir) in sprouts) {
    // Only the upper canopy. A sub-limb that droops low carries whips, not a
    // crown, and massing pools there reads as a hanging lump.
    if (origin.dy > 0.42) continue;
    final count = 2 + rand.nextInt(3);
    for (var c = 0; c < count; c++) {
      final front = rand.nextDouble() < 0.5;
      // Lifted above the wood and pushed outward along it, so the limbs show
      // as dark lines inside the bloom rather than being buried.
      final lift =
          Offset(dir.dy.abs() * dir.dx.sign * 0.3, -1) *
          (rand.nextDouble() * 0.035);
      final center =
          origin +
          lift +
          Offset(
            (rand.nextDouble() - 0.5) * 0.05,
            (rand.nextDouble() - 0.5) * 0.03,
          );
      clusters.add(
        BlossomCluster(
          center: center,
          radius: 0.016 + rand.nextDouble() * 0.020,
          depth: front
              ? 0.5 + rand.nextDouble() * 0.5
              : rand.nextDouble() * 0.5,
          front: front,
          band: weepingBandFor(center.dx),
          seed: rand.nextInt(1 << 30),
          wet: rand.nextDouble() < 0.35,
        ),
      );
    }
  }

  // Dome fill. The pools above only follow the wood, which leaves dark gaps
  // between the scaffold arches; this masses bloom along the crown's actual
  // top line so the umbrella reads as one roof of blossom.
  const binWidth = 0.05;
  final tops = <int, double>{};
  for (final (origin, _) in sprouts) {
    final bin = (origin.dx / binWidth).floor();
    tops[bin] = math.min(tops[bin] ?? double.infinity, origin.dy);
  }
  // Take the higher of each bin's neighbours too, so the line bridges the V
  // between two arches instead of dipping into it and leaving a notch.
  final bridged = {
    for (final b in tops.keys)
      b: [
        tops[b - 1],
        tops[b],
        tops[b + 1],
      ].whereType<double>().reduce(math.min),
  };
  tops
    ..clear()
    ..addAll(bridged);
  final bins = tops.keys.toList()..sort();
  double topAt(double x) {
    final f = x / binWidth - 0.5;
    final lo = f.floor().clamp(bins.first, bins.last);
    final hi = (lo + 1).clamp(bins.first, bins.last);
    // Bins with no sprout borrow their nearest neighbour's height.
    double at(int b) {
      for (var d = 0; d <= bins.length; d++) {
        if (tops[b - d] != null) return tops[b - d]!;
        if (tops[b + d] != null) return tops[b + d]!;
      }
      return 0.3;
    }

    final t = (f - lo).clamp(0.0, 1.0);
    return at(lo) * (1 - t) + at(hi) * t;
  }

  final minX = bins.first * binWidth;
  final maxX = (bins.last + 1) * binWidth;
  for (var i = 0; i < 560; i++) {
    final x = minX + rand.nextDouble() * (maxX - minX);
    // Biased toward the top line, thinning down into the arch.
    final drop = math.pow(rand.nextDouble(), 1.3) * 0.28;
    final center = Offset(x, topAt(x) - 0.012 + drop);
    if (center.dy > 0.46) continue;
    final front = rand.nextDouble() < 0.5;
    clusters.add(
      BlossomCluster(
        center: center,
        radius: 0.014 + rand.nextDouble() * 0.018,
        depth: front ? 0.5 + rand.nextDouble() * 0.5 : rand.nextDouble() * 0.5,
        front: front,
        band: weepingBandFor(center.dx),
        seed: rand.nextInt(1 << 30),
        wet: rand.nextDouble() < 0.3,
      ),
    );
  }

  // Heart of the crown. The scaffolds run bare for a stretch before their
  // first whips, which leaves a dark V over the fork; short inner twigs off
  // their lower reaches carry pools to close it, with the fork itself still
  // showing through. Its own seed, so this never reshuffles the rest.
  final heart = math.Random(_seed ^ 0x4EA7);
  for (final arm in arms) {
    for (final at in const [1, 2]) {
      final dir = arm[at] - arm[at - 1];
      final base = math.atan2(dir.dx, -dir.dy);
      // Turned in toward the upright, so the twigs fill the V rather than
      // following their scaffold out.
      var a =
          base * (0.2 + heart.nextDouble() * 0.3) +
          (heart.nextDouble() - 0.5) * 0.7;
      var p = arm[at];
      final points = <Offset>[p];
      const steps = 4;
      final length = 0.10 + heart.nextDouble() * 0.07;
      for (var i = 1; i <= steps; i++) {
        a += (i.isEven ? 1 : -1) * (0.12 + heart.nextDouble() * 0.14);
        p += Offset(math.sin(a), -math.cos(a)) * (length / steps);
        points.add(p);
      }
      limbs.add(
        _smooth(points, [
          for (var i = 0; i <= steps; i++) 0.010 * (1 - 0.8 * i / steps),
        ]),
      );

      for (final point in points.skip(1)) {
        for (var c = 0; c < 3; c++) {
          final center =
              point +
              Offset(
                (heart.nextDouble() - 0.5) * 0.06,
                (heart.nextDouble() - 0.5) * 0.04,
              );
          if (center.dy > 0.47) continue;
          final front = heart.nextDouble() < 0.5;
          clusters.add(
            BlossomCluster(
              center: center,
              radius: 0.014 + heart.nextDouble() * 0.016,
              depth: front
                  ? 0.5 + heart.nextDouble() * 0.5
                  : heart.nextDouble() * 0.5,
              front: front,
              band: weepingBandFor(center.dx),
              seed: heart.nextInt(1 << 30),
              wet: heart.nextDouble() < 0.3,
            ),
          );
        }
      }
    }
  }

  clusters.sort((a, b) => a.depth.compareTo(b.depth));

  final (weekPetals, petalsByAngle) = _weekPetals(clusters);

  final pivotSums = List<double>.filled(weepingBandCount, 0);
  final pivotCounts = List<int>.filled(weepingBandCount, 0);
  for (final strand in strands) {
    pivotSums[strand.band] += strand.points.first.dy;
    pivotCounts[strand.band]++;
  }

  return WeepingCherryGeometry(
    limbs: limbs,
    strands: strands,
    clusters: clusters,
    bandPivots: [
      for (var b = 0; b < weepingBandCount; b++)
        pivotCounts[b] == 0 ? 0.3 : pivotSums[b] / pivotCounts[b],
    ],
    weekPetals: weekPetals,
    petalsByAngle: petalsByAngle,
  );
}

/// Spreads the 4160 weeks over the blossom: one petal to every pool first, so
/// every pool has a week to lose and the whole canopy can thin, then the rest
/// weighted by pool area. Its own seed, so adding these never reshuffles the
/// tree.
(List<WeekPetal>, List<int>) _weekPetals(List<BlossomCluster> clusters) {
  final rand = math.Random(_seed ^ 0x7EE7);
  final owners = <int>[
    for (var i = 0; i < math.min(clusters.length, weekPetalCount); i++) i,
  ];
  final weights = [for (final c in clusters) c.radius * c.radius];
  final total = weights.fold<double>(0, (a, b) => a + b);
  while (owners.length < weekPetalCount) {
    var pick = rand.nextDouble() * total;
    var i = 0;
    while (pick > weights[i] && i < weights.length - 1) {
      pick -= weights[i];
      i++;
    }
    owners.add(i);
  }

  final petals = <WeekPetal>[];
  for (final owner in owners) {
    final c = clusters[owner];
    final a = rand.nextDouble() * math.pi * 2;
    final d = math.sqrt(rand.nextDouble()) * c.radius * 0.85;

    petals.add(
      WeekPetal(
        position: c.center + Offset(math.cos(a) * d, math.sin(a) * d),
        cluster: owner,
        size: 0.0045 + rand.nextDouble() * 0.0035,
        tone: rand.nextInt(petalToneCount),
        squash: rand.nextInt(petalSquashLevels),
        rotation: rand.nextDouble() * math.pi * 2,
        groundSize: 0.0050 + rand.nextDouble() * 0.0045,
        phase: rand.nextDouble(),
      ),
    );
  }

  const crown = Offset(0, 0.40);
  final keyed = [
    for (var i = 0; i < petals.length; i++)
      (
        i,
        math.atan2(
          petals[i].position.dy - crown.dy,
          petals[i].position.dx - crown.dx,
        ),
      ),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return (petals, [for (final (i, _) in keyed) i]);
}

/// Chaikin-smooths a jagged centre line twice, carrying the widths along, so
/// the kinks soften into knuckles instead of hard corners.
CherryLimb _smooth(List<Offset> points, List<double> widths) {
  var p = points;
  var w = widths;
  for (var pass = 0; pass < 2; pass++) {
    final np = <Offset>[p.first];
    final nw = <double>[w.first];
    for (var i = 0; i < p.length - 1; i++) {
      np
        ..add(Offset.lerp(p[i], p[i + 1], 0.25)!)
        ..add(Offset.lerp(p[i], p[i + 1], 0.75)!);
      nw
        ..add(w[i] * 0.75 + w[i + 1] * 0.25)
        ..add(w[i] * 0.25 + w[i + 1] * 0.75);
    }
    np.add(p.last);
    nw.add(w.last);
    p = np;
    w = nw;
  }
  return CherryLimb(p, w);
}
