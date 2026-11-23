import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_sky.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/usage/gaia_stats_model.dart';
import 'package:voyager/features/gaia/usage/gaia_tokens.dart';

/// `/stats` and the sidebar's moon (GAIA_STATS_HLD.md §5): the headline
/// numbers, the rare satellites and auroras seen, and the lifetime tokens.
Future<void> showGaiaStats(BuildContext context, GaiaController controller) {
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
        final stats = controller.stats.value;
        final tokens = controller.tokens.value;
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

        Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 28, bottom: 12),
          child: Text(
            text,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
        String compact(int? n) =>
            n == null ? '–' : NumberFormat.compact().format(n);

        return Dialog(
          child: SizedBox(
            width: 480,
            child: SingleChildScrollView(
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
                    const SizedBox(height: 16),
                    _Tiles([
                      _Headline(compact(stats?.days.length), 'Days active'),
                      _Headline(compact(stats?.chats), 'Chats started'),
                      _Headline(compact(stats?.meteors), 'Meteors seen'),
                      _Headline(
                        compact(
                          tokens?.fold<int>(0, (n, row) => n + row.count.total),
                        ),
                        'Lifetime tokens',
                      ),
                    ]),
                    heading('Rare satellites'),
                    _Tiles([
                      for (final look in gaiaStatsSatellites)
                        _SeenTile(
                          name: _satelliteNames[look]!,
                          seen: stats?.satellites[look.name],
                          icon: (silhouette) =>
                              _SatelliteIcon(look, silhouette: silhouette),
                        ),
                    ]),
                    heading('Rare auroras'),
                    _Tiles([
                      for (final colours in gaiaStatsAuroras)
                        _SeenTile(
                          name: _auroraNames[colours]!,
                          seen: stats?.auroras[colours.name],
                          icon: (silhouette) =>
                              _AuroraSwatch(colours, silhouette: silhouette),
                        ),
                    ]),
                    heading('Lifetime tokens'),
                    if (tokens == null)
                      Text('Not read yet', style: muted)
                    else
                      ...gaiaTokenLines(context, tokens, accountLabel),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// The rare satellites as the tiles show them: rarest first.
@visibleForTesting
const gaiaStatsSatellites = [
  GaiaSatellite.iss,
  GaiaSatellite.hubble,
  GaiaSatellite.array,
  GaiaSatellite.dish,
];

/// The rare auroras as the tiles show them: rarest first.
@visibleForTesting
const gaiaStatsAuroras = [
  GaiaRareAurora.gold,
  GaiaRareAurora.mauve,
  GaiaRareAurora.twilight,
  GaiaRareAurora.crimson,
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
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

BoxDecoration _tileBox() => BoxDecoration(
  border: Border.all(color: GaiaInk.hairline),
  borderRadius: BorderRadius.circular(GaiaRadius.row),
);

/// A big number over its label.
class _Headline extends StatelessWidget {
  const _Headline(this.value, this.label);

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: _tileBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 2),
          // A word a line, so every tile is as tall at any width.
          Text(
            label.replaceAll(' ', '\n'),
            style: theme.textTheme.bodySmall?.copyWith(color: GaiaInk.muted),
          ),
        ],
      ),
    );
  }
}

/// A rare satellite or aurora: its icon, name, count and first sighting; or,
/// never seen, its silhouette and "???" (§5.2).
class _SeenTile extends StatelessWidget {
  const _SeenTile({required this.name, required this.seen, required this.icon});

  final String name;
  final GaiaSeen? seen;
  final Widget Function(bool silhouette) icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: GaiaInk.muted);
    final seen = switch (this.seen) {
      final seen? when seen.count > 0 => seen,
      _ => null,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: _tileBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: SizedBox(
              width: _iconSize.width,
              height: _iconSize.height,
              child: icon(seen == null),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  seen == null ? '???' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: seen == null ? GaiaInk.faint : GaiaInk.bright,
                  ),
                ),
              ),
              if (seen != null) Text('×${seen.count}', style: small),
            ],
          ),
          const SizedBox(height: 2),
          // Two lines even when empty, so locked tiles are as tall.
          Text(switch (seen?.first) {
            final first? =>
              'First seen\n${DateFormat('d MMM y').format(first)}',
            _ => '\n',
          }, style: small),
        ],
      ),
    );
  }
}

/// Room for a tile's icon.
const _iconSize = Size(64, 32);

/// What locked tiles draw in.
const _silhouetteInk = GaiaInk.faint;

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

/// The rare aurora's curtains as soft bands, high, main and low, over the
/// sky (§5.3); locked, a flat swatch.
class _AuroraSwatch extends StatelessWidget {
  const _AuroraSwatch(this.colours, {required this.silhouette});

  final GaiaRareAurora colours;
  final bool silhouette;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _AuroraPainter(
      colours,
      silhouette,
      Theme.of(context).scaffoldBackgroundColor,
    ),
  );
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.colours, this.silhouette, this.sky);

  final GaiaRareAurora colours;
  final bool silhouette;
  final Color sky;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(GaiaRadius.chip),
    );
    if (silhouette) {
      canvas.drawRRect(box, Paint()..color = _silhouetteInk);
      return;
    }
    final [main, high, low] = gaiaRareAuroraColors(colours);
    final rect = Offset.zero & size;
    canvas
      ..save()
      ..clipRRect(box)
      ..drawRect(rect, Paint()..color = sky)
      // The curtains side by side, each strongest low down.
      ..drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            rect.centerLeft,
            rect.centerRight,
            [
              for (final c in [high, main, low]) c.withValues(alpha: 0.85),
            ],
            [0.15, 0.5, 0.85],
          ),
      )
      // Fading into the sky above.
      ..drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(rect.bottomCenter, rect.topCenter, [
            sky.withValues(alpha: 0),
            sky.withValues(alpha: 0.85),
          ]),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.colours != colours || old.silhouette != silhouette || old.sky != sky;
}

/// The stats' lifetime tokens: the total, then each account's when there
/// are several, each by tier with its models, then the utility model by job.
/// Biggest first.
@visibleForTesting
List<Widget> gaiaTokenLines(
  BuildContext context,
  List<GaiaTokenRow> rows,
  String Function(String key) accountLabel,
) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
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

  // Its in, out and cache split under it, or in its tooltip.
  Widget line(
    String name,
    GaiaTokenCount used, {
    int depth = 0,
    bool bold = false,
    bool split = false,
  }) {
    final style =
        (depth == 0 ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
            ?.copyWith(
              fontWeight: bold ? FontWeight.w600 : null,
              color: depth > 1 ? muted : null,
            );
    final row = Row(
      children: [
        Expanded(child: Text(name, style: style)),
        Text(compact(used.total), style: style),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(left: 16.0 * depth, top: depth == 0 ? 14 : 6),
      child: split
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row,
                const SizedBox(height: 2),
                Text(
                  detail(used),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            )
          : Tooltip(message: detail(used), child: row),
    );
  }

  List<Widget> sources(List<GaiaTokenRow> rows, int depth) {
    List<Widget> group(
      String name,
      List<GaiaTokenRow> rows,
      String Function(GaiaTokenRow row) part,
    ) => [
      if (rows.isNotEmpty) ...[
        line(name, sum(rows), depth: depth, split: true),
        for (final (key, rows) in by(rows, part))
          line(key, sum(rows), depth: depth + 1),
      ],
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
    line('All', sum(rows), bold: true, split: true),
    if (accounts.length < 2)
      ...sources(rows, 0)
    else
      for (final (account, rows) in accounts) ...[
        line(accountLabel(account), sum(rows), bold: true, split: true),
        ...sources(rows, 1),
      ],
  ];
}
