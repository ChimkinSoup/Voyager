import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_sky.dart';
import 'package:voyager/features/gaia/companion/gaia_starfield.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/usage/gaia_stats_model.dart';
import 'package:voyager/features/gaia/usage/gaia_tokens.dart';

/// `/stats` and the sidebar's moon (GAIA_STATS_HLD.md §5): the headline
/// numbers, the rare satellites and auroras seen, and the lifetime tokens.
/// [preview], from the debug menu, is shown in place of the real ones.
Future<void> showGaiaStats(
  BuildContext context,
  GaiaController controller, {
  ({GaiaStats? stats, List<GaiaTokenRow>? tokens})? preview,
}) {
  return showDialog<void>(
    context: context,
    // Rebuilt as the stats and tokens land, which may be after it opens.
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        controller.tokens,
        controller.stats,
      ]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        final stats = preview == null ? controller.stats.value : preview.stats;
        final tokens = preview == null
            ? controller.tokens.value
            : preview.tokens;
        String accountLabel(String key) {
          for (final adapter in [kGaiaClaudeCodeAdapter, kGaiaCodexAdapter]) {
            for (final account in controller.accountsFor(adapter)) {
              if (account.key == key) {
                return '${adapter == kGaiaCodexAdapter ? 'Codex' : 'Claude'}'
                    ' · ${account.label}';
              }
            }
          }
          // Removed, or only on another desktop.
          return '${key.split('/').first == kGaiaCodexAdapter ? 'Codex' : 'Claude'}'
              ' · other account';
        }

        // Rising in with the first of what's under it.
        Widget heading(String text, int order) => _Rise(
          order: order,
          child: Padding(
            padding: const EdgeInsets.only(top: 28, bottom: 12),
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
        String compact(int? n) =>
            n == null ? '–' : NumberFormat.compact().format(n);

        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            // Most of the window's width; the Dialog's insets still cap it.
            width: MediaQuery.sizeOf(context).width * 0.8,
            // Scrolls without a bar.
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: Stack(
                children: [
                  // A little night over the title, fading out under it.
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 140,
                    child: IgnorePointer(
                      child: CustomPaint(painter: _HeaderStarsPainter()),
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 20, 20, 28),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Stats',
                                  style: theme.textTheme.titleLarge,
                                ),
                              ),
                              GaiaButton(
                                icon: Icons.close,
                                size: 32,
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _Headlines([
                            (compact(stats?.days.length), 'Days active'),
                            (compact(stats?.chats), 'Chats started'),
                            (compact(stats?.meteors), 'Meteors seen'),
                            (
                              compact(
                                tokens?.fold<int>(
                                  0,
                                  (n, row) => n + row.count.total,
                                ),
                              ),
                              'Lifetime tokens',
                            ),
                          ]),
                          heading('Rare satellites', 4),
                          _Tiles([
                            for (final (i, look) in gaiaStatsSatellites.indexed)
                              _Rise(
                                order: 4 + i,
                                child: _SeenTile(
                                  name: _satelliteNames[look]!,
                                  seen: stats?.satellites[look.name],
                                  loaded: stats != null,
                                  glow: _satelliteGlow,
                                  icon: (silhouette) => Center(
                                    child: SizedBox.fromSize(
                                      size: _iconSize,
                                      child: _SatelliteIcon(
                                        look,
                                        silhouette: silhouette,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ]),
                          heading('Rare auroras', 8),
                          _Tiles([
                            for (final (i, colours) in gaiaStatsAuroras.indexed)
                              _Rise(
                                order: 8 + i,
                                child: _SeenTile(
                                  name: _auroraNames[colours]!,
                                  seen: stats?.auroras[colours.name],
                                  loaded: stats != null,
                                  glow: gaiaRareAuroraColors(colours).first,
                                  icon: (silhouette) => _AuroraCurtains(
                                    colours,
                                    silhouette: silhouette,
                                  ),
                                ),
                              ),
                          ]),
                          heading('Lifetime tokens', 12),
                          _Rise(
                            order: 12,
                            child: tokens == null
                                ? Text('Not read yet', style: muted)
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: gaiaTokenLines(
                                      context,
                                      tokens,
                                      accountLabel,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// The rare satellites as the tiles show them: rarest last.
@visibleForTesting
const gaiaStatsSatellites = [
  GaiaSatellite.dish,
  GaiaSatellite.array,
  GaiaSatellite.hubble,
  GaiaSatellite.iss,
];

/// The rare auroras as the tiles show them: rarest last.
@visibleForTesting
const gaiaStatsAuroras = [
  GaiaRareAurora.crimson,
  GaiaRareAurora.twilight,
  GaiaRareAurora.mauve,
  GaiaRareAurora.gold,
];

const _satelliteNames = {
  GaiaSatellite.iss: 'ISS',
  GaiaSatellite.hubble: 'Hubble',
  GaiaSatellite.array: 'Array',
  GaiaSatellite.dish: 'Dish',
};

const _auroraNames = {
  GaiaRareAurora.gold: 'Gold',
  GaiaRareAurora.mauve: 'Mauve',
  GaiaRareAurora.twilight: 'Twilight',
  GaiaRareAurora.crimson: 'Crimson',
};

/// A row of four tiles, or two rows of two when narrow (§5.1).
class _Tiles extends StatelessWidget {
  const _Tiles(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 8.0;
      final perRow = constraints.maxWidth < 360 ? 2 : 4;
      final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
      // Each row as tall as its tallest tile, as a count under its name
      // makes one taller.
      return Column(
        spacing: gap,
        children: [
          for (var i = 0; i < children.length; i += perRow)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: gap,
                children: [
                  for (final child in children.skip(i).take(perRow))
                    SizedBox(width: width, child: child),
                ],
              ),
            ),
        ],
      );
    },
  );
}

/// The headline numbers, each over its label, in columns split by hairlines:
/// four across, or two rows of two when narrow.
class _Headlines extends StatelessWidget {
  const _Headlines(this.items);

  final List<(String value, String label)> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final perRow = constraints.maxWidth < 360 ? 2 : 4;
        return Column(
          spacing: 16,
          children: [
            for (var i = 0; i < items.length; i += perRow)
              IntrinsicHeight(
                child: Row(
                  children: [
                    for (
                      var j = i;
                      j < i + perRow && j < items.length;
                      j++
                    ) ...[
                      if (j > i)
                        VerticalDivider(
                          width: 33,
                          thickness: 1,
                          color: GaiaInk.hairline,
                        ),
                      Expanded(
                        child: _Rise(
                          order: j,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                items[j].$1,
                                style: theme.textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                items[j].$2,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: GaiaInk.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// [child] fading and rising in as the stats open, [order] steps after the
/// first; still under reduced motion.
class _Rise extends StatelessWidget {
  const _Rise({required this.order, required this.child});

  final int order;
  final Widget child;

  static const _step = 35;
  static const _each = 320;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final total = _each + order * _step;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(order * _step / total, 1, curve: GaiaMotion.curve),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// A rare satellite or aurora on its window onto the sky, glowing a little
/// in its colour, with its name, count and first sighting; or, never seen,
/// its silhouette and "???" (§5.2). Seen while the stats are open, its glow
/// flares and settles.
class _SeenTile extends StatefulWidget {
  const _SeenTile({
    required this.name,
    required this.seen,
    required this.loaded,
    required this.glow,
    required this.icon,
  });

  final String name;
  final GaiaSeen? seen;

  /// Whether the stats are read yet: those arriving flare nothing.
  final bool loaded;
  final Color glow;
  final Widget Function(bool silhouette) icon;

  @override
  State<_SeenTile> createState() => _SeenTileState();
}

class _SeenTileState extends State<_SeenTile>
    with SingleTickerProviderStateMixin {
  late final _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
    value: 1,
  );

  static bool _isSeen(GaiaSeen? seen) => (seen?.count ?? 0) > 0;

  @override
  void didUpdateWidget(_SeenTile old) {
    super.didUpdateWidget(old);
    if (old.loaded &&
        !_isSeen(old.seen) &&
        _isSeen(widget.seen) &&
        !MediaQuery.disableAnimationsOf(context)) {
      _flash.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seen = _isSeen(widget.seen) ? widget.seen : null;
    return AnimatedBuilder(
      animation: _flash,
      builder: (context, child) {
        // 1 at rest, up to 3 as it flares.
        final flare = 1 + 2 * (1 - Curves.easeOut.transform(_flash.value));
        return Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: seen == null
                  ? GaiaInk.hairline
                  : Color.lerp(
                      GaiaInk.hairline,
                      widget.glow.withValues(alpha: 0.5),
                      (flare - 1) / 2,
                    )!,
            ),
            borderRadius: BorderRadius.circular(GaiaRadius.row),
            // Seen, its colour washing down from the top.
            gradient: seen == null
                ? null
                : LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      widget.glow.withValues(alpha: 0.05 * flare),
                      widget.glow.withValues(alpha: 0),
                    ],
                  ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SkyWindow(
                seed: widget.name.codeUnits.fold(7, (h, c) => h * 31 + c),
                glow: seen == null
                    ? null
                    : widget.glow.withValues(
                        alpha: (0.16 * flare).clamp(0.0, 1.0),
                      ),
                stars: seen == null ? 0.3 : 0.7,
                child: widget.icon(seen == null),
              ),
              child!,
            ],
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The count at the right, or under the name when there's no room.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                children: [
                  Text(
                    seen == null ? '???' : widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: seen == null ? GaiaInk.faint : GaiaInk.bright,
                    ),
                  ),
                  if (seen != null)
                    Text(
                      '×${NumberFormat.decimalPattern().format(seen.count)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: GaiaInk.muted,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            // A line even when empty, so locked tiles are as tall.
            Text(
              switch (seen?.first) {
                final first? => 'since ${DateFormat('d MMM y').format(first)}',
                _ => '',
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: GaiaInk.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// How tall a tile's window onto the sky is.
const _windowHeight = 56.0;

/// Room for a satellite in its window.
const _iconSize = Size(64, 32);

/// What locked tiles draw in.
const _silhouetteInk = GaiaInk.faint;

/// The glow behind a seen satellite: starlight.
const _satelliteGlow = Color(0xFFCFDDFF);

/// A small patch of night sky, its stars seeded by [seed] so each keeps its
/// own, with [child] on it and a soft [glow] behind that.
class _SkyWindow extends StatelessWidget {
  const _SkyWindow({
    required this.seed,
    required this.glow,
    required this.stars,
    required this.child,
  });

  final int seed;
  final Color? glow;

  /// How bright its stars are, 0 to 1.
  final double stars;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(GaiaRadius.chip),
    child: CustomPaint(
      painter: _WindowPainter(
        seed,
        Color.lerp(Theme.of(context).colorScheme.surface, Colors.black, 0.4)!,
        glow,
        stars,
      ),
      child: SizedBox(
        height: _windowHeight,
        width: double.infinity,
        child: child,
      ),
    ),
  );
}

class _WindowPainter extends CustomPainter {
  _WindowPainter(this.seed, this.night, this.glow, this.stars);

  final int seed;
  final Color night;
  final Color? glow;
  final double stars;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = night);
    _paintStars(canvas, size, seed, count: 14, alpha: stars);
    if (glow case final glow?) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(rect.center, size.width * 0.45, [
            glow,
            glow.withValues(alpha: 0),
          ]),
      );
    }
  }

  @override
  bool shouldRepaint(_WindowPainter old) =>
      old.seed != seed ||
      old.night != night ||
      old.glow != glow ||
      old.stars != stars;
}

/// [count] stars seeded by [seed] over [size], the bigger ones tinted, as
/// bright as [alpha] times what [fade] gives for their height, 0 at the
/// top to 1 at the bottom.
void _paintStars(
  Canvas canvas,
  Size size,
  int seed, {
  required int count,
  required double alpha,
  double Function(double y)? fade,
}) {
  final random = math.Random(seed);
  final paint = Paint();
  for (var i = 0; i < count; i++) {
    final big = random.nextDouble() < 0.25;
    final at = Offset(
      random.nextDouble() * size.width,
      random.nextDouble() * size.height,
    );
    final tint = big
        ? kGaiaStarTints[random.nextInt(kGaiaStarTints.length)]
        : kGaiaStarTints.first;
    final strength =
        alpha *
        (0.3 + random.nextDouble() * 0.7) *
        (fade?.call(at.dy / size.height) ?? 1);
    canvas.drawCircle(
      at,
      big ? 0.9 : 0.5,
      paint..color = tint.withValues(alpha: strength),
    );
  }
}

/// The stars over the stats' title, fading out downwards.
class _HeaderStarsPainter extends CustomPainter {
  const _HeaderStarsPainter();

  @override
  void paint(Canvas canvas, Size size) => _paintStars(
    canvas,
    size,
    11,
    count: (size.width * size.height / 1400).round(),
    alpha: 0.55,
    fade: (y) => math.pow(1 - y, 2).toDouble(),
  );

  @override
  bool shouldRepaint(_HeaderStarsPainter old) => false;
}

/// Each rare craft's extent as the sky draws it, unscaled and heading right,
/// to fit it to [_iconSize].
const _satelliteBounds = {
  GaiaSatellite.iss: Rect.fromLTRB(-7, -14, 7.6, 14),
  GaiaSatellite.array: Rect.fromLTRB(-20.6, -5.6, 20.6, 2.8),
  GaiaSatellite.hubble: Rect.fromLTRB(-8.9, -6.3, 8, 6.3),
  GaiaSatellite.dish: Rect.fromLTRB(-13.9, -2.1, 13.9, 7.7),
};

/// A rare satellite as the sky draws it, still and level (§5.3).
class _SatelliteIcon extends StatelessWidget {
  const _SatelliteIcon(this.look, {required this.silhouette});

  final GaiaSatellite look;
  final bool silhouette;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _SatellitePainter(look, silhouette));
}

class _SatellitePainter extends CustomPainter {
  _SatellitePainter(this.look, this.silhouette);

  final GaiaSatellite look;
  final bool silhouette;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = _satelliteBounds[look]!;
    final scale = [
      size.width / bounds.width,
      size.height / bounds.height,
    ].reduce((a, b) => a < b ? a : b);
    final at = size.center(Offset.zero) - bounds.center * scale;
    if (silhouette) {
      canvas.saveLayer(
        null,
        Paint()
          ..colorFilter = const ColorFilter.mode(
            _silhouetteInk,
            BlendMode.srcIn,
          ),
      );
    }
    paintGaiaSatellite(
      canvas,
      look,
      at,
      const Offset(1, 0),
      scale: scale,
      flat: silhouette,
    );
    if (silhouette) canvas.restore();
  }

  @override
  bool shouldRepaint(_SatellitePainter old) =>
      old.look != look || old.silhouette != silhouette;
}

/// The rare aurora's curtains, high, main and low, as the sky hangs them:
/// rays brightest at their lower edge and fading up, the edge waving
/// (§5.3). Locked, the same curtains faint and flat.
class _AuroraCurtains extends StatelessWidget {
  const _AuroraCurtains(this.colours, {required this.silhouette});

  final GaiaRareAurora colours;
  final bool silhouette;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _AuroraPainter(colours, silhouette));
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.colours, this.silhouette);

  final GaiaRareAurora colours;
  final bool silhouette;

  /// Each curtain's upper and lower edge as shares of the height: the high
  /// one up top, the low one at the bottom.
  static const _bands = [(0.05, 0.55), (0.18, 0.75), (0.35, 0.92)];

  @override
  void paint(Canvas canvas, Size size) {
    final [main, high, low] = gaiaRareAuroraColors(colours);
    final random = math.Random(colours.index + 3);
    final phase = random.nextDouble() * math.pi * 2;
    const step = 2.0;
    final paint = Paint()
      ..blendMode = silhouette ? BlendMode.srcOver : BlendMode.plus;
    for (final (i, hue) in [high, main, low].indexed) {
      final (top, bottom) = _bands[i];
      final ink = silhouette ? _silhouetteInk : hue;
      for (var x = 0.0; x < size.width; x += step) {
        final along = (x + step / 2) / size.width;
        final edge =
            (bottom +
                0.05 * math.sin(along * math.pi * 2.6 + phase + i * 1.7) +
                0.025 * math.sin(along * math.pi * 6.2 - phase + i)) *
            size.height;
        final reach =
            (bottom - top) *
            size.height *
            (0.6 +
                0.25 * math.sin(along * 13 + phase * 2 + i) +
                0.15 * math.sin(along * 31 - phase + i * 2));
        // Softer at its ends, and each ray its own brightness.
        final strength =
            (silhouette ? 0.3 : 0.7) *
            math.sqrt(math.sin(math.pi * along)) *
            (0.6 + 0.4 * random.nextDouble());
        final ray = Rect.fromLTRB(x, edge - reach, x + step, edge + 3);
        canvas.drawRect(
          ray,
          paint
            ..shader = ui.Gradient.linear(
              ray.topCenter,
              ray.bottomCenter,
              [
                ink.withValues(alpha: 0),
                ink.withValues(alpha: strength),
                ink.withValues(alpha: 0),
              ],
              [0, 0.85, 1],
            ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.colours != colours || old.silhouette != silhouette;
}

/// The stats' lifetime tokens: the total's split (the total itself is the
/// headline's), then each account's when there are several, each by tier
/// with its models and its share of the account, then the utility model by
/// job. Biggest first.
@visibleForTesting
List<Widget> gaiaTokenLines(
  BuildContext context,
  List<GaiaTokenRow> rows,
  String Function(String key) accountLabel,
) {
  final theme = Theme.of(context);
  final detailStyle = theme.textTheme.bodySmall?.copyWith(color: GaiaInk.faint);
  String compact(int n) => NumberFormat.compact().format(n);
  GaiaTokenCount sum(Iterable<GaiaTokenRow> rows) =>
      rows.fold(const GaiaTokenCount(), (sum, row) => sum + row.count);
  String detail(GaiaTokenCount used) =>
      '${compact(used.input)} in · ${compact(used.output)} out · '
      '${compact(used.cacheRead)} cache read · '
      '${compact(used.cacheWrite)} cache write';
  List<(String, List<GaiaTokenRow>)> by(
    Iterable<GaiaTokenRow> rows,
    String Function(GaiaTokenRow row) key,
  ) {
    final groups = <String, List<GaiaTokenRow>>{};
    for (final row in rows) {
      groups.putIfAbsent(key(row), () => []).add(row);
    }
    return [for (final MapEntry(:key, :value) in groups.entries) (key, value)]
      ..sort((a, b) => sum(b.$2).total.compareTo(sum(a.$2).total));
  }

  // Its in, out and cache split under it, or in its tooltip. [open], for a
  // group's header, adds the chevron that says whether it is open, and
  // [share], its part of what it's in, a bar under it. [bold] is an
  // account's, a header a tier's, and the rest a model's or a job's.
  Widget line(
    String name,
    GaiaTokenCount used, {
    int depth = 0,
    bool bold = false,
    bool split = false,
    bool? open,
    double? share,
  }) {
    final style = bold
        ? theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: GaiaInk.bright,
          )
        : open != null
        ? theme.textTheme.bodyMedium?.copyWith(color: GaiaInk.dim)
        : theme.textTheme.bodySmall?.copyWith(color: GaiaInk.muted);
    final row = Row(
      children: [
        Flexible(child: Text(name, style: style)),
        if (open != null)
          AnimatedRotation(
            turns: open ? 0.25 : 0,
            duration: GaiaMotion.quick,
            child: const Icon(
              Icons.chevron_right,
              size: 16,
              color: GaiaInk.faint,
            ),
          ),
        const Spacer(),
        Text(compact(used.total), style: style),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(
        left: 16.0 * depth,
        top: bold
            ? 16
            : open != null
            ? 10
            : 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (split) row else Tooltip(message: detail(used), child: row),
          if (share != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ShareBar(share),
            ),
          if (split)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(detail(used), style: detailStyle),
            ),
        ],
      ),
    );
  }

  List<Widget> sources(List<GaiaTokenRow> rows, int depth) {
    final whole = sum(rows).total;
    List<Widget> group(
      String name,
      List<GaiaTokenRow> rows,
      String Function(GaiaTokenRow row) part,
    ) => [
      if (rows.isNotEmpty)
        _TokenGroup(
          // Its own open or shut, kept across the dialog's rebuilds.
          key: ValueKey(('group', rows.first.account, depth, name)),
          header: (open) => line(
            name,
            sum(rows),
            depth: depth,
            split: open,
            open: open,
            share: whole == 0 ? 0 : sum(rows).total / whole,
          ),
          children: [
            for (final (key, rows) in by(rows, part))
              line(key, sum(rows), depth: depth + 1),
          ],
        ),
    ];
    final utility = [
      for (final row in rows)
        if (row.source.startsWith(kGaiaTokensUtility)) row,
    ];
    return [
      for (final tier in GaiaTier.values)
        ...group(tier.label, [
          for (final row in rows)
            if (row.source == tier.name) row,
        ], (row) => row.model),
      ...group('Utility', utility, (row) {
        final job = row.source.substring(kGaiaTokensUtility.length);
        return job.isEmpty ? job : job[0].toUpperCase() + job.substring(1);
      }),
      ...group('Other', [
        for (final row in rows)
          if (!GaiaTier.values.any((tier) => tier.name == row.source) &&
              !row.source.startsWith(kGaiaTokensUtility))
            row,
      ], (row) => row.model),
    ];
  }

  final accounts = by(rows, (row) => row.account);
  return [
    Text(detail(sum(rows)), style: detailStyle),
    if (accounts.length < 2)
      ...sources(rows, 0)
    else
      for (final (account, rows) in accounts) ...[
        line(accountLabel(account), sum(rows), bold: true, split: true),
        ...sources(rows, 1),
      ],
  ];
}

/// A tier's share of its account's tokens: the accent along a hairline.
class _ShareBar extends StatelessWidget {
  const _ShareBar(this.share);

  final double share;

  @override
  Widget build(BuildContext context) => Container(
    height: 2,
    decoration: BoxDecoration(
      color: GaiaInk.hairline,
      borderRadius: BorderRadius.circular(1),
    ),
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: share.clamp(0.0, 1.0),
      heightFactor: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    ),
  );
}

/// One group of the lifetime tokens, shut to its total until clicked open
/// to show its split and its lines.
class _TokenGroup extends StatefulWidget {
  const _TokenGroup({super.key, required this.header, required this.children});

  final Widget Function(bool open) header;
  final List<Widget> children;

  @override
  State<_TokenGroup> createState() => _TokenGroupState();
}

class _TokenGroupState extends State<_TokenGroup> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: widget.header(_open),
          ),
        ),
        if (_open) ...widget.children,
      ],
    );
  }
}
