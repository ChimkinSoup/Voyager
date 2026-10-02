import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/rankings/rankings_map_style.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';

/// The base style every map is recoloured from — see [voyagerMapStyle].
final _baseStyleProvider = FutureProvider<Map<String, dynamic>>(
  (ref) async =>
      jsonDecode(await rootBundle.loadString('assets/rankings_map_style.json'))
          as Map<String, dynamic>,
);

/// The closest any rankings map zooms. The tile layer draws nothing past its
/// own maximum, so a map allowed further would show only its background.
const rankingsMapMaxZoom = 20.0;

/// The furthest out a rankings map [width] wide zooms: the world just fills
/// it, so no place shows twice side by side.
double rankingsMapMinZoomAt(double width) => math.log(width / 256) / math.ln2;

/// Geoapify's vector tiles, drawn in the app's own colours and font: land in
/// the theme's surface, everything on it a shade toward the theme's ink, water
/// and major roads leaning toward the accent, and every label in the app font. Vector rather
/// than raster because a raster tile arrives with its colours and lettering
/// already painted in.
///
/// No name is in the tiles: they are drawn over them here, each the same size
/// on screen at any zoom, where a tile's own would grow and shrink with it
/// between whole zooms. A place to eat or drink shows its name once there is
/// room for it, and before that a dot once there is room for that — see
/// [planFoodLabels] — so zooming in only ever brings one out, never puts one
/// back. Its dot shows the name while the mouse is over it, and name and dot
/// are pressed alike — see [RankingsTileLayerState]. Both are left out under
/// a pin, or under the title a pin carries. Streets', places' and water's
/// names make way for them, and for each other.
///
/// Draws nothing without a key — the caller shows the unavailable state.
class RankingsTileLayer extends ConsumerStatefulWidget {
  const RankingsTileLayer({super.key, this.pins = const []});

  /// The map's pins and the title each carries under it, which the names
  /// make way for.
  final List<({LatLng point, String title})> pins;

  @override
  ConsumerState<RankingsTileLayer> createState() => RankingsTileLayerState();
}

/// The zoom a place to eat or drink's name first shows at — the style's
/// `poi_food_major` — and with it the title under a pin.
const rankingsMapNameZoom = 15;

/// A pin's title: how wide it may run before it wraps, how many lines it
/// may take, and how far under the pin's point it starts.
const rankingsMapTitleWidth = 96.0;
const rankingsMapTitleLines = 2;
const rankingsMapTitleDrop = 17.0;

/// Drawn without a box, so it is ringed in the land's colour to stand off
/// the roads it crosses.
TextStyle rankingsMapTitleStyle(ThemeData theme) =>
    theme.textTheme.labelSmall!.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w700,
      height: 1.15,
      shadows: [
        for (final offset in const [
          Offset(-1, -1),
          Offset(1, -1),
          Offset(-1, 1),
          Offset(1, 1),
        ])
          Shadow(color: theme.colorScheme.surface, offset: offset),
      ],
    );

/// One name drawn over the tiles: its label, and the corner of the layout
/// the label's own offsets are from, in the world's pixels at the zoom the
/// label was laid out for.
typedef _Name = ({vtr.PlacedLabel label, Offset corner});

/// A dot's radius on screen, and how near the mouse must come to it.
const _dotRadius = 3.5;
const _dotReach = 8.0;

/// The room a dot keeps around itself, on screen, from names and other dots.
const _dotGap = 2.5;

/// The zoom from which every dot shows, room or not: places a dot apart
/// there share a building, and no closer camera would part them.
const _allDotsZoom = 19.0;

/// The furthest out a place to eat or drink's name is laid out for: the
/// style's `poi_food_major` starts at [rankingsMapNameZoom], which the
/// camera rounds to from half a zoom further out.
const _foodFloor = rankingsMapNameZoom - 0.5;

/// When each place to eat or drink of [labels] shows its dot and its name:
/// from the zoom `dot` and the zoom `name` on, the name taking the dot's
/// place. Each label is its point in the pixels of [zoom], the box its name
/// takes around that point, and its sort key, the lowest first.
///
/// The best known claim their room first. A name shows from the zoom on
/// which it runs into no better known name shown at that zoom or any closer
/// one; a dot, of [dot]'s size, from the zoom on which it runs into no name
/// and no better known dot. Both are worked out for every zoom at once, as
/// the names keep their size on screen while their points spread apart, so
/// one that shows at a zoom shows at every zoom closer in. A name or a dot
/// that runs into another only further out than [floor] shows from there.
@visibleForTesting
List<({double dot, double name})> planFoodLabels(
  List<({Offset at, Rect box, double key})> labels, {
  required int zoom,
  required Rect dot,
  double floor = _foodFloor,
}) {
  final count = labels.length;
  final order = List.generate(count, (i) => i)
    ..sort((a, b) {
      final (x, y) = (labels[a], labels[b]);
      return x.key != y.key
          ? x.key.compareTo(y.key)
          : x.at.dx != y.at.dx
          ? x.at.dx.compareTo(y.at.dx)
          : x.at.dy != y.at.dy
          ? x.at.dy.compareTo(y.at.dy)
          : a.compareTo(b);
    });
  final names = List.filled(count, floor);
  final dots = List.filled(count, floor);
  if (count == 0) return const [];

  // Two boxes only meet further out than [floor] once their points are
  // this far apart, at [zoom]: a grid of cells this size finds the rest.
  var widest = dot.width;
  var tallest = dot.height;
  for (final label in labels) {
    widest = math.max(widest, label.box.width);
    tallest = math.max(tallest, label.box.height);
  }
  final reach = math.pow(2, zoom - floor).toDouble();
  final cellWidth = 2 * widest * reach;
  final cellHeight = 2 * tallest * reach;
  final grid = <(int, int), List<int>>{};
  (int, int) cellOf(Offset at) =>
      ((at.dx / cellWidth).floor(), (at.dy / cellHeight).floor());
  for (var i = 0; i < count; i++) {
    (grid[cellOf(labels[i].at)] ??= []).add(i);
  }
  Iterable<int> near(int i) sync* {
    final (x, y) = cellOf(labels[i].at);
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        yield* grid[(x + dx, y + dy)] ?? const <int>[];
      }
    }
  }

  final rankOf = List.filled(count, 0);
  for (var rank = 0; rank < count; rank++) {
    rankOf[order[rank]] = rank;
  }
  for (final i in order) {
    var from = floor;
    for (final j in near(i)) {
      if (rankOf[j] >= rankOf[i]) continue;
      final apart = _apartFrom(
        labels,
        i,
        labels[i].box,
        j,
        labels[j].box,
        zoom,
      );
      if (apart > names[j]) from = math.max(from, apart);
    }
    names[i] = from;
  }
  // After every name, which a dot makes way for, better known or not.
  for (final i in order) {
    var from = floor;
    for (final j in near(i)) {
      if (j == i) continue;
      final apart = _apartFrom(labels, i, dot, j, labels[j].box, zoom);
      if (apart > names[j]) from = math.max(from, apart);
      // A better known dot, which shows from dots[j] until its name does.
      if (rankOf[j] < rankOf[i] && dots[j] < names[j]) {
        final until = math.min(
          _apartFrom(labels, i, dot, j, dot, zoom),
          names[j],
        );
        if (until > dots[j]) from = math.max(from, until);
      }
    }
    dots[i] = from;
  }
  return [for (var i = 0; i < count; i++) (dot: dots[i], name: names[i])];
}

/// The zoom from which [a] around label [i]'s point and [b] around label
/// [j]'s stop meeting as the camera comes in, their points spreading apart
/// from where they are at [zoom] while the boxes keep their size. Minus
/// infinity for two that never meet.
double _apartFrom(
  List<({Offset at, Rect box, double key})> labels,
  int i,
  Rect a,
  int j,
  Rect b,
  int zoom,
) {
  final apart = labels[j].at - labels[i].at;
  // Where [b]'s point may sit from [a]'s, on screen, for the two to meet.
  final meet = Rect.fromLTRB(
    a.left - b.right,
    a.top - b.bottom,
    a.right - b.left,
    a.bottom - b.top,
  );
  // The spread, on screen over [zoom]'s pixels, over which they meet.
  var low = 0.0;
  var high = double.infinity;
  for (final (along, min, max) in [
    (apart.dx, meet.left, meet.right),
    (apart.dy, meet.top, meet.bottom),
  ]) {
    if (along == 0) {
      if (min >= 0 || max <= 0) return double.negativeInfinity;
      continue;
    }
    final (from, to) = along > 0
        ? (min / along, max / along)
        : (max / along, min / along);
    low = math.max(low, from);
    high = math.min(high, to);
  }
  if (high <= low) return double.negativeInfinity;
  return zoom + math.log(high) / math.ln2;
}

/// Whether [name] is a place to eat or drink's — the style's `poi_food`
/// layers — rather than a street's, a place's or water's.
bool _isFood(_Name name) => name.label.layer.startsWith('poi');

/// The point [name] is anchored to, in its layout's pixels.
Offset _anchorOf(_Name name) => name.corner + name.label.at;

/// What [name] takes on the map, in its layout's pixels at [scale] from them
/// to the camera's: its text, or for one that found no room, its dot. Both
/// keep their size on screen, so they take less of the layout the closer
/// the camera is.
Rect _boxOf(_Name name, double scale) {
  final anchor = _anchorOf(name);
  if (!name.label.placed) {
    return Rect.fromCircle(center: anchor, radius: _dotReach / scale);
  }
  final box = name.label.bounds.shift(-name.label.at);
  return Rect.fromLTRB(
    anchor.dx + box.left / scale,
    anchor.dy + box.top / scale,
    anchor.dx + box.right / scale,
    anchor.dy + box.bottom / scale,
  );
}

/// [name] drawn as its text when [placed], or else as its dot, whatever
/// room the layout found for it.
_Name _drawnAs(_Name name, {required bool placed}) => (
  label: (
    text: name.label.text,
    at: name.label.at,
    painter: name.label.painter,
    corner: name.label.corner,
    bounds: name.label.bounds,
    placed: placed,
    rotation: name.label.rotation,
    layer: name.label.layer,
    sortKey: name.label.sortKey,
  ),
  corner: name.corner,
);

/// A place to eat or drink's name, and the zooms from which its dot and its
/// name show — see [planFoodLabels].
typedef _Planned = ({_Name name, double dot, double text});

class RankingsTileLayerState extends ConsumerState<RankingsTileLayer> {
  final _controller = VectorTileController();

  /// The names laid out for the tiles last on screen, the whole zoom those
  /// were drawn at, and when the places to eat or drink among them show.
  /// Kept while the next are fetched, as the tiles are.
  ({int zoom, List<_Name> names, List<_Planned> food})? _names;

  /// Which tiles [_names] was last asked for.
  String? _asked;

  /// What the last build drew, for [nameAt]: the camera, and the names left
  /// once the pins and each other had taken their room.
  MapCamera? _camera;
  List<_Name> _drawn = const [];

  /// The name under the mouse — see [light].
  _Name? _lit;

  /// The size of each of the pins' titles, by its text.
  final _titleSizes = <String, Size>{};

  /// The place to eat or drink's name or dot drawn over [point] and the place
  /// it names, or null.
  ({String text, LatLng point})? nameAt(LatLng point) {
    final name = _drawnAt(point);
    return name == null
        ? null
        : (
            text: name.label.text,
            point: _camera!.unprojectAtZoom(
              _anchorOf(name),
              _names!.zoom.toDouble(),
            ),
          );
  }

  /// Draws the name over [point] in the accent, to show it can be pressed,
  /// and no other. Whether there is one.
  bool light(LatLng? point) {
    final name = point == null ? null : _drawnAt(point);
    if (name != _lit) setState(() => _lit = name);
    return name != null;
  }

  _Name? _drawnAt(LatLng point) {
    final camera = _camera;
    final names = _names;
    if (camera == null || names == null) return null;
    final at = camera.projectAtZoom(point, names.zoom.toDouble());
    final scale = math.pow(2, camera.zoom - names.zoom).toDouble();
    // A dot first: one that lost its room lies under a name that won it.
    for (final placed in [false, true]) {
      for (final name in _drawn) {
        if (_isFood(name) &&
            name.label.placed == placed &&
            _boxOf(name, scale).contains(at)) {
          return name;
        }
      }
    }
    return null;
  }

  /// Fetches the names of the tiles from ([left], [top]) to ([right],
  /// [bottom]) at [zoom], unless they are the ones last asked for.
  Future<void> _ask(
    Object theme,
    int zoom,
    int left,
    int top,
    int right,
    int bottom,
  ) async {
    final asked = '${identityHashCode(theme)}/$zoom/$left/$top/$right/$bottom';
    if (asked == _asked) return;
    _asked = asked;
    // The tile layer under this one is built, or rebuilt for a new theme,
    // after this is called, and only then does the controller answer for it.
    await null;
    final names = <_Name>[];
    final seen = <List<vtr.PlacedLabel>>[];
    for (var x = left; x <= right; x++) {
      for (var y = top; y <= bottom; y++) {
        final tile = TileIdentity(zoom, x, y);
        if (!tile.isValid()) continue;
        final cut = await _controller.overlaidLabels(tile);
        // Every tile cut from one source tile answers with the same list.
        if (cut == null || seen.any((list) => identical(list, cut.labels))) {
          continue;
        }
        seen.add(cut.labels);
        final corner = Offset(x * 256, y * 256) - cut.origin;
        names.addAll([
          for (final label in cut.labels) (label: label, corner: corner),
        ]);
      }
    }
    if (!mounted || asked != _asked) return;
    final food = [
      for (final name in names)
        if (_isFood(name)) name,
    ];
    final plan = planFoodLabels(
      [
        for (final name in food)
          (
            at: _anchorOf(name),
            box: name.label.bounds.shift(-name.label.at),
            key: name.label.sortKey,
          ),
      ],
      zoom: zoom,
      dot: Rect.fromCircle(center: Offset.zero, radius: _dotRadius + _dotGap),
    );
    setState(
      () => _names = (
        zoom: zoom,
        names: names,
        food: [
          for (var i = 0; i < food.length; i++)
            (name: food[i], dot: plan[i].dot, text: plan[i].name),
        ],
      ),
    );
  }

  /// What [camera] shows, in the world's pixels at [zoom].
  Rect _viewAt(MapCamera camera, int zoom) {
    final scale = math.pow(2, camera.zoom - zoom);
    return Rect.fromCenter(
      center: camera.projectAtZoom(camera.center, zoom.toDouble()),
      width: camera.size.width / scale,
      height: camera.size.height / scale,
    );
  }

  /// The names and dots of [names] on screen at the camera's zoom, at the
  /// size they are drawn: a place to eat or drink's as [planFoodLabels]
  /// planned it — every dot from [_allDotsZoom] — where no pin of the map
  /// sits on it and no pin's title runs over it; then any other name that
  /// runs into none drawn before it.
  List<_Name> _visible(
    BuildContext context,
    MapCamera camera,
    ({int zoom, List<_Name> names, List<_Planned> food}) names,
  ) {
    final zoom = names.zoom.toDouble();
    // The names are laid out at a whole zoom and stretched to the camera's.
    final scale = math.pow(2, camera.zoom - zoom).toDouble();
    final view = _viewAt(camera, names.zoom);
    final style = rankingsMapTitleStyle(Theme.of(context));
    final scaler = MediaQuery.textScalerOf(context);
    final pins = <({Offset at, Rect title})>[];
    for (final pin in widget.pins) {
      final at = camera.projectAtZoom(pin.point, zoom);
      if (!view.inflate(rankingsMapTitleWidth / scale).contains(at)) continue;
      final size = pin.title.isEmpty || camera.zoom < rankingsMapNameZoom
          ? Size.zero
          : _titleSizes.putIfAbsent(pin.title, () {
              final painter = TextPainter(
                text: TextSpan(text: pin.title, style: style),
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                textScaler: scaler,
                maxLines: rankingsMapTitleLines,
                ellipsis: '…',
              )..layout(maxWidth: rankingsMapTitleWidth);
              final size = painter.size;
              painter.dispose();
              return size;
            });
      pins.add((
        at: at,
        title: Rect.fromLTWH(
          at.dx - size.width / scale / 2,
          at.dy + rankingsMapTitleDrop / scale,
          size.width / scale,
          size.height / scale,
        ),
      ));
    }
    // A name is centred on its place, and so is the pin of an entry made of
    // it: the pin's own disc is the room the pin takes. A neighbour's name is
    // under it too once its box reaches into the disc.
    final disc = RankingsMapPin.size / 2 / scale;
    bool underPin(_Name name, Rect box) => pins.any((pin) {
      final nearest = Offset(
        pin.at.dx.clamp(box.left, box.right).toDouble(),
        pin.at.dy.clamp(box.top, box.bottom).toDouble(),
      );
      return (_anchorOf(name) - pin.at).distance < disc ||
          (nearest - pin.at).distance < disc ||
          pin.title.overlaps(box);
    });
    final drawn = <_Name>[];
    final taken = <Rect>[];
    final everyDot = camera.zoom >= _allDotsZoom;
    for (final planned in names.food) {
      final text = camera.zoom >= planned.text;
      if (!text && !everyDot && camera.zoom < planned.dot) continue;
      final name = _drawnAs(planned.name, placed: text);
      final box = _boxOf(name, scale);
      if (!box.overlaps(view) || underPin(name, box)) continue;
      taken.add(
        text
            ? box
            : Rect.fromCircle(
                center: _anchorOf(name),
                radius: (_dotRadius + _dotGap) / scale,
              ),
      );
      drawn.add(name);
    }
    // In the layout's order, which places the names that matter most first.
    // Laid out at a whole zoom, they only run into each other on a camera
    // further out than that.
    for (final name in names.names) {
      if (_isFood(name) || !name.label.placed) continue;
      final box = _boxOf(name, scale);
      if (!box.overlaps(view) || taken.any(box.overlaps)) continue;
      taken.add(box);
      drawn.add(name);
    }
    return drawn;
  }

  @override
  void didUpdateWidget(RankingsTileLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _titleSizes.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _titleSizes.clear();
  }

  /// The theme last built and the colours it was built from. Reading a style
  /// parses all of its layers, which is not work to repeat on every rebuild.
  ({Color land, Color ink, Color accent, vtr.Theme theme})? _built;

  vtr.Theme _themeFor(Map<String, dynamic> base, ColorScheme scheme) {
    final built = _built;
    if (built != null &&
        built.land == scheme.surface &&
        built.ink == scheme.onSurface &&
        built.accent == scheme.primary) {
      return built.theme;
    }
    final theme = vtr.ThemeReader().read(
      voyagerMapStyle(
        base,
        land: scheme.surface,
        ink: scheme.onSurface,
        accent: scheme.primary,
        fontFamily: AppFonts.family,
      ),
    );
    _built = (
      land: scheme.surface,
      ink: scheme.onSurface,
      accent: scheme.primary,
      theme: theme,
    );
    return theme;
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(geoapifyClientProvider);
    final base = ref.watch(_baseStyleProvider).valueOrNull;
    if (client == null || base == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final theme = _themeFor(base, scheme);
    final camera = _camera = MapCamera.of(context);

    // The zoom the tiles on screen are drawn at, and so lay their names out
    // at.
    final zoom = camera.zoom.round();
    final view = _viewAt(camera, zoom);
    unawaited(
      _ask(
        theme,
        zoom,
        view.left ~/ 256,
        view.top ~/ 256,
        view.right ~/ 256,
        view.bottom ~/ 256,
      ),
    );
    final names = _names;
    _drawn = names == null ? const [] : _visible(context, camera, names);

    return Stack(
      fit: StackFit.expand,
      children: [
        _tiles(theme, client.apiKey),
        if (names != null)
          MobileLayerTransformer(
            child: IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: _NamesPainter(
                  names: _drawn,
                  // Only while it is drawn as it was lit: a zoom with the
                  // mouse still moves no hover, and may since have turned
                  // it from a dot to a name, hidden it, or laid it out anew.
                  lit: _drawn.contains(_lit) ? _lit : null,
                  litColor: scheme.primary,
                  backing: scheme.surface,
                  scale: math.pow(2, camera.zoom - names.zoom).toDouble(),
                  origin: camera.pixelOrigin,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tiles(vtr.Theme theme, String apiKey) {
    return VectorTileLayer(
      controller: _controller,
      theme: theme,
      tileProviders: TileProviders({
        'default':
            ref.watch(rankingMapTileProviderProvider) ??
            NetworkVectorTileProvider(
              urlTemplate:
                  'https://maps.geoapify.com/v1/tile/vector/{z}/{x}/{y}.pbf'
                  '?apiKey=$apiKey',
              maximumZoom: 14,
            ),
      }),
      // Viewed tiles are kept on disk, so a revisited area draws offline and
      // spends no credits. A month: a street map does not go stale between
      // visits.
      fileCacheTtl: const Duration(days: 30),
      // Rendered tiles are stored per palette, so each theme fills it anew.
      fileCacheMaximumSizeInBytes: 200 * 1024 * 1024,
      // Tiles in flight is twice this. At the default 4, a fresh screen
      // queued behind the network and its last tile took 2.5–5 s to appear;
      // at 16, under 1 s.
      concurrency: 16,
      maximumZoom: rankingsMapMaxZoom,
    );
  }
}

/// Draws [names] where the tiles would have, over a dot for each that found
/// no room, and [lit] in [litColor] — one without room by its dot, on
/// [backing] so it reads over the names around it.
class _NamesPainter extends CustomPainter {
  const _NamesPainter({
    required this.names,
    required this.lit,
    required this.litColor,
    required this.backing,
    required this.scale,
    required this.origin,
  });

  final List<_Name> names;
  final _Name? lit;
  final Color litColor;
  final Color backing;

  /// From the pixels the names were laid out in to the camera's, and the
  /// camera's corner in those.
  final double scale;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    // Dots under names: past the zoom where every dot shows, one may sit
    // under a name, which must still read.
    for (final name in names) {
      if (!name.label.placed) {
        canvas.drawCircle(
          _anchorOf(name) * scale - origin,
          _dotRadius,
          Paint()
            ..color = name == lit
                ? litColor
                // The tiles' renderer sets a label's colour as its paint.
                : name.label.painter.text?.style?.foreground?.color ?? litColor,
        );
      }
    }
    for (final name in names) {
      if (name.label.placed) _paintName(canvas, name);
    }
    // Over the others, which it would have collided with.
    if (lit case final lit? when !lit.label.placed) {
      final painter = lit.label.painter;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          (_anchorOf(lit) * scale - origin + _offsetOf(lit)) & painter.size,
          const Radius.circular(3),
        ).inflate(3),
        Paint()..color = backing,
      );
      _paintName(canvas, lit);
    }
  }

  /// From [name]'s anchor to its text's corner, before it is turned. The
  /// layout's own pixels are the screen's: the text is not stretched.
  static Offset _offsetOf(_Name name) => name.label.corner - name.label.at;

  /// Paints [name] at its size in the layout, wherever the camera's zoom
  /// puts its anchor, turned about the anchor as the layout turned it.
  void _paintName(Canvas canvas, _Name name) {
    final at = _anchorOf(name) * scale - origin;
    canvas
      ..save()
      ..translate(at.dx, at.dy);
    if (name.label.rotation != 0) canvas.rotate(-name.label.rotation);
    if (name == lit) {
      // The painter carries the map's own colour; only its shape is kept.
      canvas.saveLayer(
        null,
        Paint()..colorFilter = ColorFilter.mode(litColor, BlendMode.srcIn),
      );
    }
    name.label.painter.paint(canvas, _offsetOf(name));
    if (name == lit) canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NamesPainter old) =>
      old.names != names ||
      old.lit != lit ||
      old.litColor != litColor ||
      old.backing != backing ||
      old.scale != scale ||
      old.origin != origin;
}

/// The credit the tile and data providers require, always on the map.
class RankingsMapAttribution extends StatelessWidget {
  const RankingsMapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Powered by Geoapify · © OpenMapTiles · © OpenStreetMap contributors',
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 9,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// What the map shows in place of itself when there is no Geoapify key.
class RankingsMapUnavailable extends StatelessWidget {
  const RankingsMapUnavailable({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        'Map unavailable — no Geoapify key',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One pin: solid in [color] with the score on it once ranked, hollow with no
/// number while unranked.
class RankingsMapPin extends StatelessWidget {
  const RankingsMapPin({
    super.key,
    required this.color,
    this.score,
    this.selected = false,
  });

  /// The square a pin is laid out in, ring included.
  static const size = 40.0;

  final Color color;

  /// The formatted overall score, or null for an unranked entry.
  final String? score;

  /// The entry open in the panel: raised and ringed.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ranked = score != null;
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: selected ? size : size - 10,
        height: selected ? size : size - 10,
        padding: EdgeInsets.all(selected ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: selected ? Border.all(color: color, width: 2) : null,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ranked ? color : theme.colorScheme.surface,
            border: ranked ? null : Border.all(color: color, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: selected ? 0.35 : 0.2),
                blurRadius: selected ? 8 : 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Center(
            child: ranked
                ? Text(
                    score!,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: onColorLabel(color),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
