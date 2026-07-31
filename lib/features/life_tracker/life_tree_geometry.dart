import 'dart:math' as math;
import 'dart:ui';

import 'package:voyager/core/widgets/leaf_shapes.dart';

/// Which life statistic a blossom shows. Fixed set per the Life Tracker spec.
enum LifeStat {
  weeksRemaining,
  heartbeats,
  sleepTime,
  tasksConquered,
  lifetimeMood,
  milesTraveled,
  fullMoons,
}

/// One of the 4160 weeks of a life, and one dot of the canopy's stipple.
/// The crown is painted as thousands of small discrete specks with bare paper
/// showing between them — so a leaf is drawn while attached, and detaching it
/// genuinely removes a fleck of blossom from the tree.
class LeafSpec {
  LeafSpec({
    required this.position,
    required this.size,
    required this.designIndex,
    required this.colorIndex,
    required this.baseAngle,
    required this.swayPhase,
    required this.clumpIndex,
  });

  final Offset position;
  final double size;
  final int designIndex;

  /// Index into the painter's tone palette — light tint, base, or deep
  /// shade of one of the petal colours. The reference painting gets its
  /// depth from mixing all three, not from one flat pink.
  final int colorIndex;
  final double baseAngle;

  /// Drives the side-to-side drift while falling, so no two petals take the
  /// same path down.
  final double swayPhase;

  /// Which clump this leaf hangs in, so it sways with the right branch.
  final int clumpIndex;
}

/// A fleck of pigment flicked off the brush, landing outside the canopy.
/// Loose spatter around the crown is a signature of the technique and does
/// most of the work of making the tree read as painted rather than drawn.
class SplatterSpeck {
  SplatterSpeck({
    required this.position,
    required this.size,
    required this.colorIndex,
  });

  final Offset position;
  final double size;
  final int colorIndex;
}

/// One blossom, tied to a single statistic. Placed on a foliage clump chosen
/// for maximum separation from the others, so they never cluster.
class BlossomSpec {
  BlossomSpec({required this.position, required this.stat, required this.size});

  final Offset position;
  final LifeStat stat;
  final double size;
}

/// One tapered woody segment — trunk, root, branch or twig. Painted as a
/// filled ribbon that narrows from [startWidth] to [endWidth] rather than a
/// constant-width stroke, so limbs taper the way real wood does.
class TreeLimb {
  const TreeLimb({
    required this.start,
    required this.control,
    required this.end,
    required this.startWidth,
    required this.endWidth,
  });

  final Offset start;
  final Offset control;
  final Offset end;

  /// Widths are a fraction of the canvas's shortest side, so a limb keeps its
  /// proportions instead of stretching with the window.
  final double startWidth;
  final double endWidth;
}

/// One mass of foliage hanging off a branch tip. Each clump is painted into
/// its own cached layer and sways about [pivot] — the point where its branch
/// meets it — so a gust can shake one side of the tree without the whole
/// canopy moving as a rigid block.
class FoliageClump {
  FoliageClump({
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.pivot,
    required this.swayPhase,
  });

  final Offset center;
  final double radiusX;
  final double radiusY;
  final Offset pivot;
  final double swayPhase;
}

/// One soft watercolor blot inside a clump. Deliberately rim-less and
/// heavily overlapped: a couple of dozen of these per clump build up into a
/// continuous wash, which is what reads as watercolor — any hard outline on
/// an individual blot immediately reads as vector art instead.
class CanopyBlob {
  CanopyBlob({
    required this.clumpIndex,
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.rotation,
    required this.colorIndex,
    required this.wobblePhases,
    required this.wobbleAmount,
    required this.depth,
  });

  final int clumpIndex;
  final Offset center;
  final double radiusX;
  final double radiusY;
  final double rotation;
  final int colorIndex;

  /// Phases of the three harmonics that perturb this blot's outline, so no
  /// two blots share a silhouette.
  final List<double> wobblePhases;
  final double wobbleAmount;

  /// 0 at the top of its clump, 1 at the bottom. Lower blots carry more
  /// pigment, which is what gives the canopy its sense of volume.
  final double depth;
}

/// Everything needed to paint the tree: the woody skeleton, the foliage
/// clumps and their blot washes, the leaf/blossom scatter, and the swing's
/// anchor. Pure data, generated once per app run (see
/// [generateLifeTreeGeometry]) and scaled to the actual canvas [Size] at
/// paint time.
class LifeTreeGeometry {
  LifeTreeGeometry({
    required this.leaves,
    required this.blossoms,
    required this.limbs,
    required this.clumps,
    required this.blobs,
    required this.splatter,
    required this.trunkTop,
    required this.groundY,
    required this.swingAnchor,
    required this.canopyCenter,
    required this.canopyRadiusX,
    required this.canopyRadiusY,
    required this.leafDesigns,
  });

  final List<LeafSpec> leaves;
  final List<BlossomSpec> blossoms;

  /// Trunk, roots, branches and twigs, in paint order.
  final List<TreeLimb> limbs;

  final List<FoliageClump> clumps;

  /// The blots making up every clump's wash, tagged with [CanopyBlob.clumpIndex].
  final List<CanopyBlob> blobs;

  /// Loose pigment flicked around the crown.
  final List<SplatterSpeck> splatter;

  /// Where the trunk ends and the crown forks — the pivot the whole canopy
  /// breathes about.
  final Offset trunkTop;

  /// Normalized y of the ground line the roots sit on.
  final double groundY;

  /// Normalized attachment point of the branch the swing hangs from.
  final Offset swingAnchor;

  /// Bounding ellipse of the whole canopy. Only used to order leaves around
  /// the tree for the opening animation.
  final Offset canopyCenter;
  final double canopyRadiusX;
  final double canopyRadiusY;

  /// Petal silhouettes used by [LeafSpec.designIndex], in a fixed order so
  /// the index is stable.
  final List<LeafDesign> leafDesigns;

  /// Leaves ordered by angle around the canopy center, for the opening
  /// animation's "evenly spread out across the tree" fall selection.
  List<int> get leafIndicesByAngle {
    final indices = List<int>.generate(leaves.length, (i) => i);
    indices.sort((a, b) {
      final aa = _angleOf(leaves[a].position);
      final ba = _angleOf(leaves[b].position);
      return aa.compareTo(ba);
    });
    return indices;
  }

  double _angleOf(Offset p) {
    return math.atan2(
      (p.dy - canopyCenter.dy) / canopyRadiusY,
      (p.dx - canopyCenter.dx) / canopyRadiusX,
    );
  }
}

/// Point at [t] along the quadratic bezier a-b-c.
Offset quadPointAt(Offset a, Offset b, Offset c, double t) {
  final u = 1 - t;
  return Offset(
    u * u * a.dx + 2 * u * t * b.dx + t * t * c.dx,
    u * u * a.dy + 2 * u * t * b.dy + t * t * c.dy,
  );
}

/// Unnormalized tangent at [t] along the quadratic bezier a-b-c.
Offset quadTangentAt(Offset a, Offset b, Offset c, double t) {
  final u = 1 - t;
  return Offset(
    2 * u * (b.dx - a.dx) + 2 * t * (c.dx - b.dx),
    2 * u * (b.dy - a.dy) + 2 * t * (c.dy - b.dy),
  );
}

const _leafDesigns = [
  LeafDesign.watercolorPetal,
  LeafDesign.raindropPetal,
  LeafDesign.petal,
];

/// Fixed seed so the tree's shape, leaf scatter, and blossom placement are
/// identical every time the app runs — the tree should read as *this* tree,
/// not reshuffle on every restart.
const _treeSeed = 20260730;

const totalLeafCount = 4160;

const _trunkTop = Offset(0.500, 0.655);
const _groundY = 0.900;

/// Where the crown forks off the trunk: `(t along the trunk, heading in
/// radians with -pi/2 straight up, length, width)`. Two low side limbs and a
/// three-way fork at the top — every deeper branch grows recursively out of
/// one of these, so the skeleton is always physically connected.
const _primaryLimbs = <(double, double, double, double)>[
  (0.78, -2.80, 0.144, 0.0096),
  (0.86, -0.34, 0.144, 0.0096),
  (0.96, -2.40, 0.166, 0.0126),
  (1.00, -1.55, 0.180, 0.0132),
  (0.97, -0.76, 0.166, 0.0126),
];

/// How many times a primary limb may fork before its tip carries foliage.
const _maxBranchDepth = 2;

/// Chance a limb stops early and carries foliage instead of forking again.
/// Terminating at mixed depths is what keeps the crown's outline ragged
/// rather than a smooth arc.
const _earlyTipChance = 0.22;

const _blobsPerClump = 10;

/// Size of the foliage strung along a limb's span, as `base + length * rate`.
/// These are what fuse the clumps at the forks and tips into a single crown;
/// shrink them and the canopy visibly splits back into islands.
const _spineRadiusBase = 0.030;
const _spineRadiusPerLength = 0.16;

/// Speck size, as a fraction of the canvas's shortest side. Sized so that the
/// [totalLeafCount] specks ink roughly four fifths of the crown: below that
/// the stipple reads as scattered dots rather than blossom, and above it the
/// paper stops showing through and the watercolor look goes with it.
const _leafSizeMin = 0.0041;
const _leafSizeRange = 0.0078;

/// Tones per petal colour in the painter's palette: a light tint, the colour
/// itself, and a deep shade. Weighted toward the lighter two, with the deep
/// shade used sparingly as the accents that give the crown its depth.
const _tonesPerColor = 3;

int _weightedTone(math.Random rand) {
  final r = rand.nextDouble();
  final tone = r < 0.44
      ? 0
      : r < 0.82
          ? 1
          : 2;
  return rand.nextInt(4) * _tonesPerColor + tone;
}

/// How far below horizontal a branch may head. Without this a fork can send
/// a limb diving at the ground, which never reads as a living branch.
const _maxHeadingDrop = 0.14;

/// Keeps a heading from pointing further down than [_maxHeadingDrop],
/// preserving which side of the tree it was growing toward.
double _clampHeading(double angle) {
  final dy = math.sin(angle);
  if (dy <= _maxHeadingDrop) return angle;
  return math.atan2(_maxHeadingDrop, math.cos(angle));
}

/// Builds the tree's full geometry: a recursively-grown woody skeleton,
/// foliage clumps at every branch tip and their blot washes,
/// [totalLeafCount] scattered leaves, one blossom per [LifeStat], and the
/// swing's branch anchor. Everything is normalized to [0,1]x[0,1] and
/// deterministic (see [_treeSeed]), so it can be computed once and reused for
/// the app's lifetime regardless of window size.
LifeTreeGeometry generateLifeTreeGeometry() {
  final rand = math.Random(_treeSeed);
  final decor = math.Random(_treeSeed ^ 0x5A5A5A);

  final limbs = <TreeLimb>[];
  final clumps = <FoliageClump>[];

  const trunk = TreeLimb(
    start: Offset(0.500, 0.935),
    control: Offset(0.520, 0.790),
    end: _trunkTop,
    startWidth: 0.036,
    endWidth: 0.0145,
  );
  limbs.add(trunk);

  // Root flares gripping the ground line. They start inside the trunk so
  // they merge with it rather than reading as spikes stuck on the side.
  const rootSpecs = <(Offset, Offset, Offset, double, double)>[
    (Offset(0.500, 0.874), Offset(0.462, 0.890), Offset(0.412, 0.901), 0.026, 0.0022),
    (Offset(0.500, 0.874), Offset(0.545, 0.891), Offset(0.598, 0.901), 0.026, 0.0022),
    (Offset(0.500, 0.882), Offset(0.474, 0.894), Offset(0.446, 0.905), 0.017, 0.0016),
    (Offset(0.500, 0.882), Offset(0.530, 0.895), Offset(0.562, 0.905), 0.017, 0.0016),
  ];
  for (final r in rootSpecs) {
    limbs.add(
      TreeLimb(
        start: r.$1,
        control: r.$2,
        end: r.$3,
        startWidth: r.$4,
        endWidth: r.$5,
      ),
    );
  }

  /// Grows one limb from [start] heading at [angle], then either forks into
  /// two children that begin exactly where it ended — which is what makes
  /// the skeleton read as a tree rather than a fan of loose sticks — or
  /// terminates and carries a clump of foliage.
  void grow(Offset start, double angle, double length, double width, int depth) {
    final direction = Offset(math.cos(angle), math.sin(angle));
    final end = start + direction * length;
    final perpendicular = Offset(-direction.dy, direction.dx);
    final bend = (rand.nextDouble() - 0.5) * 0.42;

    final control =
        start + direction * (length * 0.5) + perpendicular * (length * bend);
    limbs.add(
      TreeLimb(
        start: start,
        control: control,
        end: end,
        startWidth: width,
        endWidth: width * 0.60,
      ),
    );

    // Foliage carried along the span of the limb, not only at its ends.
    // Without this the clumps at successive forks sit too far apart to touch
    // and the crown breaks into separate floating islands — the canopy has to
    // read as one continuous mass, so every span between forks carries
    // blossom too.
    // Jitter drawn from [decor] rather than [rand] so that adding foliage
    // never perturbs the random sequence the skeleton itself is grown from —
    // otherwise tuning the canopy silently regrows a different tree.
    final spineRadiusX = _spineRadiusBase + length * _spineRadiusPerLength;
    clumps.add(
      FoliageClump(
        center: quadPointAt(start, control, end, 0.58),
        radiusX: spineRadiusX,
        radiusY: spineRadiusX * (1.08 + decor.nextDouble() * 0.26),
        pivot: start,
        swayPhase: decor.nextDouble() * 1.1,
      ),
    );

    if (depth < _maxBranchDepth && rand.nextDouble() > _earlyTipChance) {
      // A real fork is lopsided: the limb mostly carries on in its own
      // direction and throws off a thinner, sharper-angled side shoot.
      // Two equal children would give the repeated symmetrical Y that made
      // the old crown read as a diagram.
      final leans = rand.nextBool() ? -1.0 : 1.0;
      final leadSpread = 0.12 + rand.nextDouble() * 0.14;
      final shootSpread = 0.42 + rand.nextDouble() * 0.30;
      final drift = (rand.nextDouble() - 0.5) * 0.14;
      final childLength = length * (0.76 + rand.nextDouble() * 0.12);

      // Foliage at the fork itself, not only out at the tips. Without it the
      // wedges between diverging limbs stay bare and the crown reads as
      // separate islands on sticks instead of one mass.
      final forkRadiusX =
          0.026 + rand.nextDouble() * 0.014 + (_maxBranchDepth - depth) * 0.005;
      clumps.add(
        FoliageClump(
          center: end,
          radiusX: forkRadiusX,
          radiusY: forkRadiusX * (1.12 + rand.nextDouble() * 0.32),
          pivot: end,
          swayPhase: rand.nextDouble() * 1.1,
        ),
      );

      grow(
        end,
        _clampHeading(angle + leans * leadSpread + drift),
        childLength,
        width * 0.72,
        depth + 1,
      );
      grow(
        end,
        _clampHeading(angle - leans * shootSpread + drift),
        childLength * (0.62 + rand.nextDouble() * 0.20),
        width * 0.52,
        depth + 1,
      );
      return;
    }

    // A tip that stops short of the outer canopy carries a heavier clump,
    // since it is a thicker branch ending early.
    final radiusX =
        0.042 + rand.nextDouble() * 0.029 + (_maxBranchDepth - depth) * 0.0085;
    // Normalized y-radius runs larger than x: the canvas is wider than it is
    // tall, so equal normalized radii would paint every clump as a flat
    // ellipse — which is exactly what made the old canopy read as an arch.
    final radiusY = radiusX * (1.12 + rand.nextDouble() * 0.32);

    // Bare twigs carrying on past the blossom, so the crown's edge is picked
    // out by fine woody lines rather than stopping dead at the foliage.
    for (var i = 0; i < 2; i++) {
      final spurAngle = _clampHeading(angle + (rand.nextDouble() - 0.5) * 1.0);
      final spurDirection = Offset(math.cos(spurAngle), math.sin(spurAngle));
      final spurLength = radiusX * (1.05 + rand.nextDouble() * 0.75);
      final spurEnd = start + direction * length + spurDirection * spurLength;
      limbs.add(
        TreeLimb(
          start: end,
          control: Offset.lerp(end, spurEnd, 0.5)! +
              spurDirection * (spurLength * 0.12),
          end: spurEnd,
          startWidth: width * 0.46,
          endWidth: width * 0.14,
        ),
      );
    }

    clumps.add(
      FoliageClump(
        center: end +
            Offset(direction.dx * radiusX, direction.dy * radiusY) * 0.45,
        radiusX: radiusX,
        radiusY: radiusY,
        pivot: end,
        // Phases stay in a narrow band so the clumps breathe together as one
        // canopy rather than flapping independently.
        swayPhase: rand.nextDouble() * 1.1,
      ),
    );
  }

  for (final primary in _primaryLimbs) {
    grow(
      quadPointAt(trunk.start, trunk.control, trunk.end, primary.$1),
      primary.$2,
      primary.$3,
      primary.$4,
      0,
    );
  }

  // Soft blots per clump, heavily overlapping. Their union is what the eye
  // reads as the canopy's silhouette, so nothing here needs an outline.
  final blobs = <CanopyBlob>[];
  for (var i = 0; i < clumps.length; i++) {
    final clump = clumps[i];
    for (var j = 0; j < _blobsPerClump; j++) {
      final angle = rand.nextDouble() * math.pi * 2;
      final radial = math.sqrt(rand.nextDouble()) * 0.66;
      final center = Offset(
        clump.center.dx + math.cos(angle) * clump.radiusX * radial,
        clump.center.dy + math.sin(angle) * clump.radiusY * radial,
      );
      final scale = 0.40 + rand.nextDouble() * 0.28;
      blobs.add(
        CanopyBlob(
          clumpIndex: i,
          center: center,
          radiusX: clump.radiusX * scale,
          radiusY: clump.radiusY * scale * (0.85 + rand.nextDouble() * 0.32),
          rotation: rand.nextDouble() * math.pi * 2,
          colorIndex: _weightedTone(rand),
          wobblePhases: [
            rand.nextDouble() * math.pi * 2,
            rand.nextDouble() * math.pi * 2,
            rand.nextDouble() * math.pi * 2,
          ],
          wobbleAmount: 0.13 + rand.nextDouble() * 0.13,
          depth: (((center.dy - (clump.center.dy - clump.radiusY)) /
                  (2 * clump.radiusY))
              .clamp(0.0, 1.0)),
        ),
      );
    }
  }

  // The stipple. Leaves are spread over the clumps in proportion to their
  // area, and thinned toward each clump's rim so the crown breaks up into
  // airy, ragged edges instead of ending at a hard boundary.
  final leaves = <LeafSpec>[];
  final weights = [for (final c in clumps) c.radiusX * c.radiusY];
  final totalWeight = weights.reduce((a, b) => a + b);
  for (var i = 0; i < clumps.length; i++) {
    final clump = clumps[i];
    final remaining = totalLeafCount - leaves.length;
    final count = i == clumps.length - 1
        ? remaining
        : math.min(remaining, (totalLeafCount * weights[i] / totalWeight).round());
    var placed = 0;
    var attempts = 0;
    while (placed < count && attempts < count * 40) {
      attempts++;
      final angle = rand.nextDouble() * math.pi * 2;
      final radial = math.sqrt(rand.nextDouble()) * 1.04;
      // Thin the outer rim: the further out, the likelier the speck is
      // rejected and the sparser the edge reads.
      if (rand.nextDouble() < radial * radial * radial * 0.62) continue;
      placed++;
      leaves.add(
        LeafSpec(
          position: Offset(
            clump.center.dx + math.cos(angle) * clump.radiusX * radial,
            clump.center.dy + math.sin(angle) * clump.radiusY * radial,
          ),
          size: _leafSizeMin + rand.nextDouble() * _leafSizeRange,
          designIndex: rand.nextInt(_leafDesigns.length),
          colorIndex: _weightedTone(rand),
          baseAngle: rand.nextDouble() * math.pi * 2,
          swayPhase: rand.nextDouble() * math.pi * 2,
          clumpIndex: i,
        ),
      );
    }
    // Top up with unthinned specks if the rejection pass came up short, so
    // the count stays exactly [totalLeafCount].
    while (placed < count) {
      placed++;
      final angle = rand.nextDouble() * math.pi * 2;
      final radial = math.sqrt(rand.nextDouble()) * 0.75;
      leaves.add(
        LeafSpec(
          position: Offset(
            clump.center.dx + math.cos(angle) * clump.radiusX * radial,
            clump.center.dy + math.sin(angle) * clump.radiusY * radial,
          ),
          size: _leafSizeMin + rand.nextDouble() * _leafSizeRange,
          designIndex: rand.nextInt(_leafDesigns.length),
          colorIndex: _weightedTone(rand),
          baseAngle: rand.nextDouble() * math.pi * 2,
          swayPhase: rand.nextDouble() * math.pi * 2,
          clumpIndex: i,
        ),
      );
    }
  }

  // Blossoms go on the clumps that sit furthest from each other — picked
  // greedily, so they end up spread across the whole crown without needing a
  // retry loop that can fail to place them all.
  final stats = List<LifeStat>.of(LifeStat.values);
  final chosenClumps = <int>[];
  var highest = 0;
  for (var i = 1; i < clumps.length; i++) {
    if (clumps[i].center.dy < clumps[highest].center.dy) highest = i;
  }
  chosenClumps.add(highest);
  while (chosenClumps.length < stats.length && chosenClumps.length < clumps.length) {
    var best = -1;
    var bestDistance = -1.0;
    for (var i = 0; i < clumps.length; i++) {
      if (chosenClumps.contains(i)) continue;
      var nearest = double.infinity;
      for (final c in chosenClumps) {
        nearest = math.min(nearest, (clumps[i].center - clumps[c].center).distance);
      }
      if (nearest > bestDistance) {
        bestDistance = nearest;
        best = i;
      }
    }
    if (best == -1) break;
    chosenClumps.add(best);
  }

  final blossoms = <BlossomSpec>[
    for (var i = 0; i < stats.length && i < chosenClumps.length; i++)
      BlossomSpec(
        position: Offset(
          clumps[chosenClumps[i]].center.dx +
              (rand.nextDouble() - 0.5) * clumps[chosenClumps[i]].radiusX * 0.8,
          clumps[chosenClumps[i]].center.dy +
              (rand.nextDouble() - 0.5) * clumps[chosenClumps[i]].radiusY * 0.8,
        ),
        stat: stats[i],
        size: 0.040,
      ),
  ];

  // The swing hangs from whichever branch reaches furthest out to the right
  // at about the height of the lower crown. Fine twigs are excluded — a rope
  // slung over a pencil-thin spur would never read as load-bearing.
  var swingLimb = limbs.last;
  var swingScore = double.negativeInfinity;
  for (var i = 1 + rootSpecs.length; i < limbs.length; i++) {
    if (limbs[i].startWidth < 0.0045) continue;
    final end = limbs[i].end;
    final score = end.dx - (end.dy - 0.615).abs() * 2.0;
    if (score > swingScore) {
      swingScore = score;
      swingLimb = limbs[i];
    }
  }
  final swingAnchor = quadPointAt(
    swingLimb.start,
    swingLimb.control,
    swingLimb.end,
    0.88,
  );

  // Canopy bounds, measured rather than assumed, so the opening animation
  // still sweeps evenly around whatever shape the crown grew into.
  var left = 1.0, right = 0.0, top = 1.0, bottom = 0.0;
  for (final clump in clumps) {
    left = math.min(left, clump.center.dx - clump.radiusX);
    right = math.max(right, clump.center.dx + clump.radiusX);
    top = math.min(top, clump.center.dy - clump.radiusY);
    bottom = math.max(bottom, clump.center.dy + clump.radiusY);
  }

  final canopyCenter = Offset((left + right) / 2, (top + bottom) / 2);
  final canopyRadiusX = (right - left) / 2;
  final canopyRadiusY = (bottom - top) / 2;

  // Loose spatter thrown around the crown, densest just outside its edge and
  // trailing off into the empty paper.
  final splatter = <SplatterSpeck>[];
  for (var i = 0; i < 260; i++) {
    final angle = rand.nextDouble() * math.pi * 2;
    final radial = 1.0 + math.pow(rand.nextDouble(), 2.0).toDouble() * 0.85;
    final position = Offset(
      canopyCenter.dx + math.cos(angle) * canopyRadiusX * radial,
      canopyCenter.dy + math.sin(angle) * canopyRadiusY * radial,
    );
    if (position.dy > _groundY - 0.02 ||
        position.dy < 0.005 ||
        position.dx < 0.005 ||
        position.dx > 0.995) {
      continue;
    }
    splatter.add(
      SplatterSpeck(
        position: position,
        size: 0.0009 + math.pow(rand.nextDouble(), 2.2).toDouble() * 0.0042,
        colorIndex: _weightedTone(rand),
      ),
    );
  }

  return LifeTreeGeometry(
    leaves: leaves,
    blossoms: blossoms,
    limbs: limbs,
    clumps: clumps,
    blobs: blobs,
    splatter: splatter,
    trunkTop: _trunkTop,
    groundY: _groundY,
    swingAnchor: swingAnchor,
    canopyCenter: canopyCenter,
    canopyRadiusX: canopyRadiusX,
    canopyRadiusY: canopyRadiusY,
    leafDesigns: _leafDesigns,
  );
}
