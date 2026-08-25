import 'dart:math' as math;
import 'dart:ui';

import 'package:voyager/core/widgets/leaf_shapes.dart';

/// Which life statistic a label points at. Fixed set per the Life Tracker spec.
enum LifeStat {
  weeksRemaining,
  heartbeats,
  sleepTime,
  tasksConquered,
  lifetimeMood,
  kmTraveled,
  fullMoons,
}

/// One of the 4160 weeks of a life, and one fleck of blossom texture over the
/// canopy wash. The crown's colour comes from the wash, not from these — they
/// are the fine grain on top of it, and the thing that visibly detaches and
/// drifts to the ground when a week is spent.
class LeafSpec {
  LeafSpec({
    required this.position,
    required this.size,
    required this.designIndex,
    required this.colorIndex,
    required this.baseAngle,
    required this.swayPhase,
    required this.cellIndex,
  });

  final Offset position;
  final double size;
  final int designIndex;

  /// Index into the painter's tone palette — light tint, base, or deep shade
  /// of one of the petal colours.
  final int colorIndex;
  final double baseAngle;

  /// Drives the side-to-side drift while falling, so no two petals take the
  /// same path down.
  final double swayPhase;

  /// Nearest wash cell, so a speck sways with the same pigment it sits on.
  final int cellIndex;
}

/// One statistic, as a point in the canopy joined by a leader line to a label
/// parked in the margin. Slots are assigned up front (see
/// [_statAnchors]) rather than derived at layout time, so labels can never
/// collide with each other.
class BlossomSpec {
  BlossomSpec({
    required this.position,
    required this.labelAnchor,
    required this.onLeft,
    required this.stat,
  });

  /// Where in the canopy the leader line starts.
  final Offset position;

  /// The label's inner edge — its right edge when [onLeft], left edge
  /// otherwise.
  final Offset labelAnchor;

  final bool onLeft;
  final LifeStat stat;
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

/// One pool of pigment in the canopy. The crown is not modelled as foliage
/// hanging off branches — it is painted the way the reference is, as a mass of
/// overlapping translucent washes with hard, irregular edges, laid over a
/// skeleton that shows through it.
class WashCell {
  WashCell({
    required this.center,
    required this.radiusX,
    required this.radiusY,
    required this.rotation,
    required this.colorIndex,
    required this.wobblePhases,
    required this.wobbleAmount,
    required this.alpha,
    required this.shedOrder,
    required this.swayPhase,
  });

  final Offset center;
  final double radiusX;
  final double radiusY;
  final double rotation;
  final int colorIndex;

  /// Phases of the harmonics that perturb this pool's outline. Watercolour
  /// dries to a crisp, lobed edge, so these run at higher frequency than a
  /// blurred blob would need — the cauliflower rim is the whole tell.
  final List<double> wobblePhases;
  final double wobbleAmount;

  /// Pigment strength before layering. Cells multiply over each other, so a
  /// dozen weak pools stack into the deep patches seen in the reference.
  final double alpha;

  /// Fraction of the life that must have been spent before this pool washes
  /// out. Uniform over the crown, so the canopy thins evenly rather than
  /// retreating from one side.
  final double shedOrder;

  final double swayPhase;
}

/// A clump of grass at the foot of the tree. The reference sets the tree on
/// scattered sage tufts rather than a shadow pool, and the tufts are what stop
/// the trunk from looking like it was pasted onto blank paper.
class GrassTuft {
  GrassTuft({
    required this.base,
    required this.width,
    required this.height,
    required this.bladeCount,
    required this.seed,
    required this.toneMix,
  });

  final Offset base;
  final double width;
  final double height;
  final int bladeCount;
  final int seed;

  /// 0 for the pale sage of a distant tuft, 1 for the darker green of one in
  /// front.
  final double toneMix;
}

/// Everything needed to paint the tree. Pure data, generated once per app run
/// (see [generateLifeTreeGeometry]) and scaled to the actual canvas [Size] at
/// paint time.
class LifeTreeGeometry {
  LifeTreeGeometry({
    required this.leaves,
    required this.blossoms,
    required this.limbs,
    required this.cells,
    required this.grass,
    required this.trunkTop,
    required this.trunkBase,
    required this.groundY,
    required this.figureAnchor,
    required this.figureHeight,
    required this.figureLean,
    required this.canopyCenter,
    required this.canopyRadiusX,
    required this.canopyRadiusY,
    required this.branchHubRect,
    required this.leafDesigns,
    required this.branchLimbStartIndex,
  });

  final List<LeafSpec> leaves;
  final List<BlossomSpec> blossoms;

  /// Trunk, roots, branches and twigs, in paint order.
  final List<TreeLimb> limbs;

  /// Index into [limbs] where the above-ground branches start — everything
  /// before it is the trunk (index 0) and the root flares. Lets code that
  /// only wants the visible branch fan (e.g. the bucket-list tap target)
  /// slice `limbs` without hardcoding how many root segments there are.
  final int branchLimbStartIndex;

  /// The canopy's pigment, back to front.
  final List<WashCell> cells;

  final List<GrassTuft> grass;

  /// Where the trunk forks — the pivot the whole canopy breathes about.
  final Offset trunkTop;

  /// Where the trunk meets the ground and the roots fan out from. Used to
  /// tell each root's own base cap from a mid-limb fork — see `roundBase` in
  /// life_tree_canvas.dart's `_paintWood`.
  final Offset trunkBase;

  /// Normalized y of the ground line the roots sit on.
  final double groundY;

  /// Where the seated figure rests on the trunk, as the midpoint of its body.
  final Offset figureAnchor;

  /// Figure height as a fraction of the canvas height.
  final double figureHeight;

  /// How far the figure reclines back along the trunk, in radians.
  final double figureLean;

  /// Bounding ellipse of the whole canopy. Used to order leaves around the
  /// tree for the opening animation.
  final Offset canopyCenter;
  final double canopyRadiusX;
  final double canopyRadiusY;

  /// Bounds of the branch fan-out around the trunk fork, in unit space — the
  /// tap target for the bucket list, since the branches converging there read
  /// as a more natural thing to tap than the seated figure lower on the trunk.
  final Rect branchHubRect;

  /// Petal silhouettes used by [LeafSpec.designIndex], in a fixed order so the
  /// index is stable.
  final List<LeafDesign> leafDesigns;

  /// Leaves ordered by angle around the canopy center, so the leaves picked
  /// for the ground come out "evenly spread out across the tree".
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

/// Vertical offset applied to the whole tree once it's built, so the roots
/// and grass sit near the bottom of the canvas instead of floating with a gap
/// beneath them. Large enough that the lowest grass tufts (groundY + up to
/// ~0.048) land right at the canvas edge.
const _treeYShift = 0.087;

Offset _shiftY(Offset o) => Offset(o.dx, o.dy + _treeYShift);

Rect _shiftRect(Rect r) => r.shift(Offset(0, _treeYShift));

TreeLimb _shiftLimb(TreeLimb limb) => TreeLimb(
      start: _shiftY(limb.start),
      control: _shiftY(limb.control),
      end: _shiftY(limb.end),
      startWidth: limb.startWidth,
      endWidth: limb.endWidth,
    );

const _leafDesigns = [
  LeafDesign.watercolorPetal,
  LeafDesign.raindropPetal,
  LeafDesign.petal,
];

/// Fixed seed so the tree's shape, leaf scatter, and label placement are
/// identical every time the app runs — the tree should read as *this* tree,
/// not reshuffle on every restart.
const _treeSeed = 20260802;

const totalLeafCount = 4160;

/// The trunk leans hard from the lower right up to the left, as in the
/// reference — that diagonal is what the seated figure rests on, and a
/// symmetrical upright trunk gives it nowhere to sit. The control point sits
/// closer to _trunkBase's x than a straight lean would put it, which steepens
/// the curve's approach to near-vertical right at the base — that's what
/// tucks its flat end cap behind the root fan below instead of leaving a gap
/// beside it.
const _trunkBase = Offset(0.610, 0.850);
const _trunkControl = Offset(0.560, 0.660);
const _trunkFork = Offset(0.430, 0.540);
const _groundY = 0.865;

/// Where the three main limbs (left sweep, center-up, right sweep) converge
/// and first fan out from the trunk fork — the visible "hub" of branches a
/// tap should land in to open the bucket list.
const _branchHubRect = Rect.fromLTRB(0.280, 0.350, 0.620, 0.545);

const _figureTrunkT = 0.24;
const _figureHeight = 0.170;
const _figureLean = -0.42;
const _figureTrunkOffset = 0.032;

const _crownCenter = Offset(0.490, 0.340);
const _crownRadiusX = 0.450;
const _crownRadiusY = 0.300;

const _baseLobeCount = 48;
const _detailCellCount = 280;

const _leafSizeMin = 0.0022;
const _leafSizeRange = 0.0035;

const _tonesPerColor = 3;

int _washTone(math.Random rand) {
  final base = rand.nextDouble() < 0.75 ? 0 : rand.nextInt(4);
  final r = rand.nextDouble();
  final tone = r < 0.45 ? 0 : r < 0.88 ? 1 : 2;
  return base * _tonesPerColor + tone;
}

int _leafTone(math.Random rand) {
  final base = rand.nextDouble() < 0.80 ? 0 : rand.nextInt(4);
  final r = rand.nextDouble();
  final tone = r < 0.65 ? 0 : r < 0.96 ? 1 : 2;
  return base * _tonesPerColor + tone;
}

// Each blossom position is pinned to a point on an actual limb (trunk, root
// or branch) so its leader line always lands on drawn wood rather than blank
// paper. Label anchors are unrelated to limb shape and stay hand-placed in an
// evenly spaced column down each margin.
const _statAnchors = <(Offset, Offset, bool)>[
  (Offset(0.276, 0.258), Offset(0.192, 0.222), true),
  (Offset(0.278, 0.431), Offset(0.192, 0.404), true),
  (Offset(0.261, 0.495), Offset(0.192, 0.586), true),
  // Tasks and Full Moons sit up top, above the canopy, per user request —
  // not stacked at the bottom of their column with the others.
  (Offset(0.417, 0.476), Offset(0.192, 0.060), true),
  (Offset(0.753, 0.285), Offset(0.808, 0.256), false),
  (Offset(0.778, 0.484), Offset(0.808, 0.462), false),
  (Offset(0.502, 0.387), Offset(0.808, 0.060), false),
];

LifeTreeGeometry generateLifeTreeGeometry() {
  final rand = math.Random(_treeSeed);
  final decor = math.Random(_treeSeed ^ 0x5A5A5A);

  final limbs = <TreeLimb>[];

  const trunk = TreeLimb(
    start: _trunkBase,
    control: _trunkControl,
    end: _trunkFork,
    startWidth: 0.075,
    endWidth: 0.032,
  );
  limbs.add(trunk);

  // Root flares fanning out from the trunk base, each starting exactly at
  // _trunkBase (matching trunk's own start) so the roots meet the trunk
  // without a gap. Each is two segments rather than one smooth curve — a
  // single bezier reads as too straight for a root, which kinks and changes
  // direction as it goes — with the second segment bending back against the
  // first's curvature rather than simply continuing it. Endpoints sit deep in
  // the grass wash's span (groundY ± 0.035–0.045) so the fine tip is buried
  // under it rather than resting on top. Deliberately not mirror images of
  // each other, so the fan doesn't read as stamped.
  final rootLimbs = <TreeLimb>[
    // Outer-left root — longest, thickest.
    const TreeLimb(
      start: _trunkBase,
      control: Offset(0.550, 0.872),
      end: Offset(0.490, 0.888),
      startWidth: 0.030,
      endWidth: 0.015,
    ),
    const TreeLimb(
      start: Offset(0.490, 0.888),
      control: Offset(0.455, 0.906),
      end: Offset(0.395, 0.902),
      startWidth: 0.015,
      endWidth: 0.005,
    ),
    // Inner-left root — shorter, thinner.
    const TreeLimb(
      start: _trunkBase,
      control: Offset(0.590, 0.868),
      end: Offset(0.560, 0.882),
      startWidth: 0.020,
      endWidth: 0.010,
    ),
    const TreeLimb(
      start: Offset(0.560, 0.882),
      control: Offset(0.530, 0.895),
      end: Offset(0.545, 0.900),
      startWidth: 0.010,
      endWidth: 0.004,
    ),
    // Inner-right root.
    const TreeLimb(
      start: _trunkBase,
      control: Offset(0.635, 0.866),
      end: Offset(0.665, 0.880),
      startWidth: 0.020,
      endWidth: 0.010,
    ),
    const TreeLimb(
      start: Offset(0.665, 0.880),
      control: Offset(0.700, 0.890),
      end: Offset(0.680, 0.898),
      startWidth: 0.010,
      endWidth: 0.004,
    ),
    // Outer-right root — longest, thickest.
    const TreeLimb(
      start: _trunkBase,
      control: Offset(0.672, 0.870),
      end: Offset(0.735, 0.885),
      startWidth: 0.030,
      endWidth: 0.015,
    ),
    const TreeLimb(
      start: Offset(0.735, 0.885),
      control: Offset(0.775, 0.900),
      end: Offset(0.825, 0.895),
      startWidth: 0.015,
      endWidth: 0.005,
    ),
  ];
  limbs.addAll(rootLimbs);

  // Everything from here on is an above-ground branch — captured before
  // they're added so [LifeTreeGeometry.branchLimbStartIndex] doesn't have to
  // hardcode how many limbs precede them.
  final branchLimbStartIndex = limbs.length;

  // Hand-crafted Sumi-e Calligraphic Limbs matching the reference image 1:1.
  // Every child limb's start point is exactly its parent's end point: the
  // ribbon caps taper to a point at that shared coordinate (see
  // _limbRibbon), so any mismatch there leaves a sliver of bare paper between
  // segments instead of one continuous stroke.
  const sumiELimbs = <TreeLimb>[
    // 1. Main Left Arm — replaced with a shallower, more upward-angled sweep
    // per user request, tracing the direction of a line they drew over the
    // previous version. Tapers all the way down to a point at the tip
    // instead of the blunt cut the old version ended in.
    TreeLimb(start: _trunkFork, control: Offset(0.300, 0.500), end: Offset(0.170, 0.477), startWidth: 0.034, endWidth: 0.002),

    // Left Arm Upper Branching (splits off along the left arm's new curve,
    // at the same point along it as before, so it doesn't float free of the
    // branch beneath it).
    TreeLimb(start: Offset(0.326, 0.511), control: Offset(0.280, 0.440), end: Offset(0.240, 0.360), startWidth: 0.018, endWidth: 0.008),
    TreeLimb(start: Offset(0.240, 0.360), control: Offset(0.200, 0.280), end: Offset(0.170, 0.210), startWidth: 0.008, endWidth: 0.002),
    TreeLimb(start: Offset(0.240, 0.360), control: Offset(0.270, 0.280), end: Offset(0.290, 0.210), startWidth: 0.007, endWidth: 0.002),

    // 2. Main Center-Up Branch
    TreeLimb(start: _trunkFork, control: Offset(0.410, 0.430), end: Offset(0.380, 0.340), startWidth: 0.026, endWidth: 0.012),
    TreeLimb(start: Offset(0.380, 0.340), control: Offset(0.360, 0.240), end: Offset(0.350, 0.160), startWidth: 0.012, endWidth: 0.002),
    TreeLimb(start: Offset(0.380, 0.340), control: Offset(0.405, 0.250), end: Offset(0.430, 0.170), startWidth: 0.009, endWidth: 0.002),

    // Center-Right Upper Twigs — shifted further right and up from their
    // original spot per user request, to fill whitespace between the
    // center-up branch and the right sweeping arm.
    TreeLimb(start: _trunkFork, control: Offset(0.480, 0.430), end: Offset(0.520, 0.350), startWidth: 0.020, endWidth: 0.009),
    TreeLimb(start: Offset(0.520, 0.350), control: Offset(0.510, 0.260), end: Offset(0.545, 0.190), startWidth: 0.009, endWidth: 0.002),
    TreeLimb(start: Offset(0.520, 0.350), control: Offset(0.575, 0.260), end: Offset(0.635, 0.175), startWidth: 0.008, endWidth: 0.002),

    // 3. Main Right Sweeping Arm
    TreeLimb(start: _trunkFork, control: Offset(0.570, 0.510), end: Offset(0.680, 0.490), startWidth: 0.032, endWidth: 0.018),
    TreeLimb(start: Offset(0.680, 0.490), control: Offset(0.740, 0.430), end: Offset(0.790, 0.360), startWidth: 0.018, endWidth: 0.008),
    TreeLimb(start: Offset(0.790, 0.360), control: Offset(0.820, 0.280), end: Offset(0.840, 0.210), startWidth: 0.008, endWidth: 0.002),
    TreeLimb(start: Offset(0.790, 0.360), control: Offset(0.750, 0.280), end: Offset(0.720, 0.220), startWidth: 0.006, endWidth: 0.002),
    TreeLimb(start: Offset(0.680, 0.490), control: Offset(0.780, 0.485), end: Offset(0.870, 0.475), startWidth: 0.014, endWidth: 0.003),
    TreeLimb(start: Offset(0.870, 0.475), control: Offset(0.910, 0.475), end: Offset(0.940, 0.475), startWidth: 0.003, endWidth: 0.0015),
  ];
  limbs.addAll(sumiELimbs);

  // The crown's outline, as a radius multiplier per angle. Three harmonics is
  // enough to keep the silhouette from reading as an ellipse without turning
  // it into a starburst.
  final envelopePhases = [
    decor.nextDouble() * math.pi * 2,
    decor.nextDouble() * math.pi * 2,
    decor.nextDouble() * math.pi * 2,
  ];
  double envelopeAt(double angle) {
    return 1.0 +
        0.115 * math.sin(3 * angle + envelopePhases[0]) +
        0.070 * math.sin(5 * angle + envelopePhases[1]) +
        0.045 * math.sin(8 * angle + envelopePhases[2]);
  }

  final cells = <WashCell>[];

  // Base pools: large, pale, and spread over the whole envelope so their union
  // is the silhouette. Their shed order starts high, so the crown keeps its
  // shape long after the detail over it has thinned.
  for (var i = 0; i < _baseLobeCount; i++) {
    final angle = (i / _baseLobeCount) * math.pi * 2 + decor.nextDouble() * 0.28;
    final radial = i == 0 ? 0.0 : (0.30 + decor.nextDouble() * 0.52);
    final edge = envelopeAt(angle);
    final center = Offset(
      _crownCenter.dx + math.cos(angle) * _crownRadiusX * radial * edge,
      _crownCenter.dy + math.sin(angle) * _crownRadiusY * radial * edge,
    );
    final rx = _crownRadiusX * (0.30 + decor.nextDouble() * 0.13);
    cells.add(
      WashCell(
        center: center,
        radiusX: rx,
        radiusY: rx * (_crownRadiusY / _crownRadiusX) * (1.05 + decor.nextDouble() * 0.30),
        rotation: decor.nextDouble() * math.pi * 2,
        colorIndex: _washTone(decor),
        wobblePhases: [
          decor.nextDouble() * math.pi * 2,
          decor.nextDouble() * math.pi * 2,
          decor.nextDouble() * math.pi * 2,
        ],
        wobbleAmount: 0.14 + decor.nextDouble() * 0.08,
        // Kept faint on purpose. These exist to guarantee the silhouette, not
        // to colour it — if they carry the pigment, washing out the detail
        // over them barely changes the crown and the shedding stops reading.
        alpha: 0.055 + decor.nextDouble() * 0.035,
        shedOrder: 0.50 + decor.nextDouble() * 0.50,
        swayPhase: decor.nextDouble() * 1.1,
      ),
    );
  }

  // Detail pools. Smaller toward the rim, which is what frays the crown's edge
  // into lobes instead of ending it on a clean curve.
  for (var i = 0; i < _detailCellCount; i++) {
    final angle = rand.nextDouble() * math.pi * 2;
    final edge = envelopeAt(angle);
    final radial = math.sqrt(rand.nextDouble()) * edge;
    final center = Offset(
      _crownCenter.dx + math.cos(angle) * _crownRadiusX * radial,
      _crownCenter.dy + math.sin(angle) * _crownRadiusY * radial,
    );
    final taper = 1.0 - 0.32 * (radial / edge).clamp(0.0, 1.0);
    final rx = _crownRadiusX * (0.075 + rand.nextDouble() * 0.075) * taper;
    // One pool in eight is loaded with pigment. These are the mauve patches
    // that give the reference its depth — evenly-weighted washes dry flat.
    final isAccent = rand.nextDouble() < 0.05;
    cells.add(
      WashCell(
        center: center,
        radiusX: rx,
        radiusY: rx * (_crownRadiusY / _crownRadiusX) * (0.90 + rand.nextDouble() * 0.45),
        rotation: rand.nextDouble() * math.pi * 2,
        colorIndex: isAccent
            ? (rand.nextDouble() < 0.7 ? 2 : 5)
            : _washTone(rand),
        wobblePhases: [
          rand.nextDouble() * math.pi * 2,
          rand.nextDouble() * math.pi * 2,
          rand.nextDouble() * math.pi * 2,
        ],
        wobbleAmount: 0.18 + rand.nextDouble() * 0.12,
        alpha: isAccent
            ? 0.040 + rand.nextDouble() * 0.025
            : 0.035 + rand.nextDouble() * 0.025,
        shedOrder: rand.nextDouble(),
        swayPhase: rand.nextDouble() * 1.1,
      ),
    );
  }

  // The stipple, sampled over the same envelope as the wash and thinned toward
  // the rim so the grain fades out before the pigment does.
  final leaves = <LeafSpec>[];
  var attempts = 0;
  while (leaves.length < totalLeafCount && attempts < totalLeafCount * 40) {
    attempts++;
    final angle = rand.nextDouble() * math.pi * 2;
    final edge = envelopeAt(angle);
    final radial = math.sqrt(rand.nextDouble()) * edge * 0.98;
    if (rand.nextDouble() < math.pow(radial / edge, 3.0) * 0.55) continue;
    leaves.add(
      LeafSpec(
        position: Offset(
          _crownCenter.dx + math.cos(angle) * _crownRadiusX * radial,
          _crownCenter.dy + math.sin(angle) * _crownRadiusY * radial,
        ),
        size: _leafSizeMin + rand.nextDouble() * _leafSizeRange,
        designIndex: rand.nextInt(_leafDesigns.length),
        colorIndex: _leafTone(rand),
        baseAngle: rand.nextDouble() * math.pi * 2,
        swayPhase: rand.nextDouble() * math.pi * 2,
        // Filled in below, once every cell exists.
        cellIndex: 0,
      ),
    );
  }
  // Top up with unthinned specks if the rejection pass came up short, so the
  // count stays exactly [totalLeafCount].
  while (leaves.length < totalLeafCount) {
    final angle = rand.nextDouble() * math.pi * 2;
    final radial = math.sqrt(rand.nextDouble()) * 0.75;
    leaves.add(
      LeafSpec(
        position: Offset(
          _crownCenter.dx + math.cos(angle) * _crownRadiusX * radial,
          _crownCenter.dy + math.sin(angle) * _crownRadiusY * radial,
        ),
        size: _leafSizeMin + rand.nextDouble() * _leafSizeRange,
        designIndex: rand.nextInt(_leafDesigns.length),
        colorIndex: _leafTone(rand),
        baseAngle: rand.nextDouble() * math.pi * 2,
        swayPhase: rand.nextDouble() * math.pi * 2,
        cellIndex: 0,
      ),
    );
  }

  // Bind each speck to the pigment it sits on, so it sways with that pool
  // rather than with the crown as a rigid sheet.
  final boundLeaves = <LeafSpec>[
    for (final leaf in leaves)
      LeafSpec(
        position: leaf.position,
        size: leaf.size,
        designIndex: leaf.designIndex,
        colorIndex: leaf.colorIndex,
        baseAngle: leaf.baseAngle,
        swayPhase: leaf.swayPhase,
        cellIndex: _nearestCell(cells, leaf.position),
      ),
  ];

  final blossoms = <BlossomSpec>[
    for (var i = 0; i < LifeStat.values.length && i < _statAnchors.length; i++)
      BlossomSpec(
        position: _statAnchors[i].$1,
        labelAnchor: _statAnchors[i].$2,
        onLeft: _statAnchors[i].$3,
        stat: LifeStat.values[i],
      ),
  ];

  // Grass, densest right under the trunk and trailing off both ways. The two
  // outlying clusters matter more than they look — without something out at
  // the edges the ground line stops dead under the canopy.
  const grassClusters = <(double, double, int)>[
    (0.585, 0.170, 14),
    (0.410, 0.110, 8),
    (0.735, 0.110, 8),
    (0.270, 0.070, 5),
    (0.845, 0.060, 5),
    (0.150, 0.045, 3),
    (0.930, 0.040, 3),
    // Right at the edges, so the grass runs the full screen width instead of
    // leaving bare paper margins the wash mound alone doesn't cover.
    (0.020, 0.020, 3),
    (0.980, 0.020, 3),
  ];
  final grass = <GrassTuft>[];
  for (final cluster in grassClusters) {
    for (var i = 0; i < cluster.$3; i++) {
      final x = cluster.$1 + (decor.nextDouble() - 0.5) * cluster.$2 * 2;
      final baseY = _groundY + decor.nextDouble() * 0.048;
      final base = Offset(x, baseY);
      var height = 0.030 + decor.nextDouble() * 0.046;
      // Tufts close enough to the trunk to sit against it need their
      // tallest blades kept clear of its silhouette — grass painted with
      // BlendMode.multiply only darkens, so a tall blade leaning in over
      // the trunk's edge reads as the trunk's own outline growing a sharp
      // point rather than as grass in front of it. 1.05 matches the
      // tallest a blade actually reaches relative to [GrassTuft.height] in
      // _paintGrass.
      final distFromTrunkX = (x - _trunkBase.dx).abs();
      if (distFromTrunkX < 0.14) {
        final maxHeight = (baseY - (_trunkBase.dy - 0.010)) / 1.05;
        height = math.min(height, math.max(0.020, maxHeight));
      }
      grass.add(
        GrassTuft(
          base: base,
          width: height * (0.75 + decor.nextDouble() * 0.60),
          height: height,
          bladeCount: 16 + decor.nextInt(14),
          seed: decor.nextInt(1 << 30),
          toneMix: decor.nextDouble(),
        ),
      );
    }
  }
  // Front to back, so the darker near tufts overlap the pale far ones.
  grass.sort((a, b) => a.base.dy.compareTo(b.base.dy));

  return LifeTreeGeometry(
    leaves: [
      for (final leaf in boundLeaves)
        LeafSpec(
          position: _shiftY(leaf.position),
          size: leaf.size,
          designIndex: leaf.designIndex,
          colorIndex: leaf.colorIndex,
          baseAngle: leaf.baseAngle,
          swayPhase: leaf.swayPhase,
          cellIndex: leaf.cellIndex,
        ),
    ],
    blossoms: [
      for (final blossom in blossoms)
        BlossomSpec(
          position: _shiftY(blossom.position),
          labelAnchor: _shiftY(blossom.labelAnchor),
          onLeft: blossom.onLeft,
          stat: blossom.stat,
        ),
    ],
    limbs: limbs.map(_shiftLimb).toList(),
    cells: [
      for (final cell in cells)
        WashCell(
          center: _shiftY(cell.center),
          radiusX: cell.radiusX,
          radiusY: cell.radiusY,
          rotation: cell.rotation,
          colorIndex: cell.colorIndex,
          wobblePhases: cell.wobblePhases,
          wobbleAmount: cell.wobbleAmount,
          alpha: cell.alpha,
          shedOrder: cell.shedOrder,
          swayPhase: cell.swayPhase,
        ),
    ],
    grass: [
      for (final tuft in grass)
        GrassTuft(
          base: _shiftY(tuft.base),
          width: tuft.width,
          height: tuft.height,
          bladeCount: tuft.bladeCount,
          seed: tuft.seed,
          toneMix: tuft.toneMix,
        ),
    ],
    trunkTop: _shiftY(_trunkFork),
    trunkBase: _shiftY(_trunkBase),
    groundY: _groundY + _treeYShift,
    figureAnchor: _shiftY(_figureSeat(trunk)),
    figureHeight: _figureHeight,
    figureLean: _figureLean,
    canopyCenter: _shiftY(_crownCenter),
    canopyRadiusX: _crownRadiusX,
    canopyRadiusY: _crownRadiusY,
    branchHubRect: _shiftRect(_branchHubRect),
    leafDesigns: _leafDesigns,
    branchLimbStartIndex: branchLimbStartIndex,
  );
}

/// The point on top of the trunk the figure rests on: a point along the curve,
/// pushed out along its normal. The trunk rises to the left, so its normal
/// points up and to the right — which is the side of it you could sit on.
Offset _figureSeat(TreeLimb trunk) {
  final on = quadPointAt(trunk.start, trunk.control, trunk.end, _figureTrunkT);
  final tangent =
      quadTangentAt(trunk.start, trunk.control, trunk.end, _figureTrunkT);
  final length = tangent.distance;
  if (length == 0) return on;
  return on +
      Offset(-tangent.dy / length, tangent.dx / length) * _figureTrunkOffset;
}

int _nearestCell(List<WashCell> cells, Offset p) {
  var best = 0;
  var bestDistance = double.infinity;
  for (var i = 0; i < cells.length; i++) {
    // Measured in each pool's own units, so a big pale lobe doesn't claim
    // every speck that a small pool right under them also covers.
    final dx = (p.dx - cells[i].center.dx) / cells[i].radiusX;
    final dy = (p.dy - cells[i].center.dy) / cells[i].radiusY;
    final d = dx * dx + dy * dy;
    if (d < bestDistance) {
      bestDistance = d;
      best = i;
    }
  }
  return best;
}
