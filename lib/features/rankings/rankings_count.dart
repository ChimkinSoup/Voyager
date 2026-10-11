import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/ranking_models.dart';

/// How many times [entryId] has been had, as the counts provider last read it.
/// 1 until the first read lands, which is what an entry nobody has tapped is.
int watchRankingCount(WidgetRef ref, String entryId) => rankingCountTotal(
  ref.watch(
    rankingCountsProvider.select((sums) => sums.valueOrNull?[entryId] ?? 0),
  ),
);

/// Whether a tap can be written yet: until startup reads the device id, every
/// device holds the same placeholder, and a row under it would have more than
/// one writer (`RANKINGS_COUNTER_HLD.md`). The controls go quiet until then
/// rather than take taps that write nothing.
bool _watchCanCount(WidgetRef ref) =>
    ref.watch(deviceIdProvider) != kUnresolvedDeviceId;

/// Runs a tap's write, saying so when it fails: the controls are fired and
/// forgotten, so the failure would otherwise go unseen.
Future<void> _write(BuildContext context, Future<void> Function() write) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await write();
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack, library: 'rankings'),
    );
    messenger?.showSnackBar(
      const SnackBar(content: Text("Couldn't save the count")),
    );
  }
}

/// The count on a list row: `×N` once there is a repeat to speak of, and a
/// `+` while the row is hovered (`RANKINGS_COUNTER_HLD.md` §6.1).
///
/// The `+` holds its width when hidden, so arriving on a row never shifts the
/// score beside it, and takes no taps or focus while hidden: on a touch screen,
/// where nothing hovers, the count changes only from the editor (§3). A
/// read-only row has no `+` and holds no room for one.
class RankingCountSlot extends ConsumerWidget {
  const RankingCountSlot({
    super.key,
    required this.entryId,
    required this.hovered,
    required this.accent,
    required this.onIncrement,
  });

  final String entryId;
  final bool hovered;
  final Color accent;

  /// Null on a read-only row.
  final Future<void> Function()? onIncrement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = watchRankingCount(ref, entryId);
    final canCount = _watchCanCount(ref);
    final onIncrement = this.onIncrement;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (count >= 2)
          Tooltip(
            message: '$count times',
            child: Text(
              '×$count',
              style: theme.textTheme.labelMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        if (onIncrement != null) ...[
          const SizedBox(width: 2),
          Visibility(
            visible: hovered,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: _CountButton(
              icon: PhosphorIconsRegular.plus,
              tooltip: 'Add one',
              color: accent,
              onPressed: canCount ? () => _write(context, onIncrement) : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// `Count  − N +` for an editor (§6.3). − goes quiet at 1, the floor.
class RankingCountStepper extends ConsumerWidget {
  const RankingCountStepper({
    super.key,
    required this.entryId,
    required this.accent,
    required this.onAdjust,
  });

  final String entryId;
  final Color accent;

  /// Called with ±1. Null makes the stepper read-only.
  final Future<void> Function(int delta)? onAdjust;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = watchRankingCount(ref, entryId);
    final onAdjust = _watchCanCount(ref) ? this.onAdjust : null;
    return Row(
      children: [
        Text(
          'Count',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 12),
        _CountButton(
          icon: PhosphorIconsRegular.minus,
          tooltip: 'Take one back',
          color: accent,
          onPressed: onAdjust == null || count <= 1
              ? null
              : () => _write(context, () => onAdjust(-1)),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '$count',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _CountButton(
          icon: PhosphorIconsRegular.plus,
          tooltip: 'Add one',
          color: accent,
          onPressed: onAdjust == null
              ? null
              : () => _write(context, () => onAdjust(1)),
        ),
      ],
    );
  }
}

/// A small round button. Not an [IconButton]: its 40px minimum made a unit
/// row taller than the rows around it.
class _CountButton extends StatelessWidget {
  const _CountButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: 24,
            child: Icon(
              icon,
              size: 14,
              color: enabled
                  ? color
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.28),
            ),
          ),
        ),
      ),
    );
  }
}
