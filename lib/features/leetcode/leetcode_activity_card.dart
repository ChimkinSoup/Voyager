import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/leetcode/leetcode_activity_calendar.dart';
import 'package:voyager/features/leetcode/leetcode_activity_chart.dart';
import 'package:voyager/features/leetcode/leetcode_activity_data.dart';

/// Height of the dashboard card, matched to the tallest progress ring beside
/// it so the two read as one band rather than two stacked things.
const double kLeetCodeActivityCardHeight = 132;

/// Fraction of the open over which the expanded card finishes fading in —
/// verbatim from [openLeetCodeDetailView], since this is the same gesture.
const double _kCardFadeInFraction = 0.3;

/// Height the expanded sparkline gets, dated axis included, before the year
/// calendar takes the rest of the card.
///
/// Deliberately short: it is a shape, not a chart to study, and the calendar
/// underneath is the part worth scrolling. It still has to clear the hover
/// bubble, which is laid out inside the chart's own box and is ~80 tall.
const double _kExpandedSparklineHeight = 160;

/// The dashboard's activity card: the last 30 days of solving, one curve per
/// difficulty, sitting in the space to the right of the progress rings.
///
/// Deliberately small and label-free — it is a shape to glance at, and tapping
/// it grows the same three curves into a full-screen view with axes, a hover
/// breakdown and a year calendar.
class LeetCodeActivityCard extends ConsumerStatefulWidget {
  const LeetCodeActivityCard({super.key});

  @override
  ConsumerState<LeetCodeActivityCard> createState() =>
      _LeetCodeActivityCardState();
}

class _LeetCodeActivityCardState extends ConsumerState<LeetCodeActivityCard> {
  final _key = GlobalKey();
  bool _hovered = false;

  void _open() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    openLeetCodeActivityView(
      context,
      box.localToGlobal(Offset.zero) & box.size,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problems =
        ref.watch(leetcodeProblemsProvider).valueOrNull ?? const [];
    final window = leetCodeActivityWindow(
      byDay: leetCodeCountsByDay(problems),
      today: DateTime.now(),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _open,
        behavior: HitTestBehavior.opaque,
        child: Container(
          key: _key,
          height: kLeetCodeActivityCardHeight,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            // The same rest/hover treatment the analytics sparkline tiles use:
            // a tint at rest, an outline only once the pointer is on it.
            color: theme.colorScheme.onSurface.withValues(
              alpha: _hovered ? 0.07 : 0.04,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? theme.colorScheme.primary.withValues(alpha: 0.35)
                  : VoyagerColors.of(context).hairline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Last 30 days',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(
                    PhosphorIconsRegular.arrowsOut,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: _hovered ? 0.8 : 0.4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                // fl_chart hit-tests its whole plot even with touches
                // disabled, so without this the middle of the card — nearly
                // all of it — swallowed the tap that opens the expanded view.
                child: IgnorePointer(
                  child: LeetCodeActivityChart(window: window, compact: true),
                ),
              ),
              const SizedBox(height: 6),
              LeetCodeActivityLegend(window: window, compact: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grows the activity view out of [anchorRect] to fill the screen, the same
/// camera zoom [openLeetCodeDetailView] uses for a problem — tapping a thing
/// expands that thing, everywhere on this page.
Future<void> openLeetCodeActivityView(BuildContext context, Rect anchorRect) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _LeetCodeActivityOverlay(anchorRect: anchorRect),
    ),
  );
}

class _LeetCodeActivityOverlay extends StatefulWidget {
  const _LeetCodeActivityOverlay({required this.anchorRect});

  final Rect anchorRect;

  @override
  State<_LeetCodeActivityOverlay> createState() =>
      _LeetCodeActivityOverlayState();
}

class _LeetCodeActivityOverlayState extends State<_LeetCodeActivityOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    // Guarded so a second Escape mid-close can't leave two reverses racing for
    // the same pop — see [openLeetCodeDetailView]'s copy of this.
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final fullScreenRect = Offset.zero & MediaQuery.sizeOf(context);
    final reducedMotion = VoyagerMotion.reduced(context);

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: PopScope(
          // The route pops instantly (its transition duration is zero), so a
          // system back has to be routed through the same shrink-back close.
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _close();
          },
          child: Material(
            color: Colors.black.withValues(alpha: 0.001),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final raw = _controller.value.clamp(0.0, 1.0);
                final scrim = Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.5 * raw),
                    ),
                  ),
                );
                if (reducedMotion) {
                  return Stack(
                    children: [
                      scrim,
                      Positioned.fill(
                        child: Opacity(opacity: raw, child: child),
                      ),
                    ],
                  );
                }
                final t = VoyagerSpring.moveCurve.transform(raw);
                final rect = Rect.lerp(widget.anchorRect, fullScreenRect, t)!;
                return Stack(
                  children: [
                    scrim,
                    // Laid out full-screen and scaled by transform rather than
                    // resized: reflowing a chart and a year of month tiles into
                    // the card's starting width overflows on the first frames.
                    Positioned.fill(
                      child: Transform(
                        alignment: Alignment.topLeft,
                        transform: Matrix4.identity()
                          ..translate(rect.left, rect.top)
                          ..scale(
                            rect.width / fullScreenRect.width,
                            rect.height / fullScreenRect.height,
                          ),
                        child: Opacity(
                          opacity: (t / _kCardFadeInFraction).clamp(0.0, 1.0),
                          child: child,
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: _ActivityDetailCard(onClose: _close),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityDetailCard extends ConsumerStatefulWidget {
  const _ActivityDetailCard({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_ActivityDetailCard> createState() =>
      _ActivityDetailCardState();
}

class _ActivityDetailCardState extends ConsumerState<_ActivityDetailCard> {
  /// The tier the legend is holding, or null for all three. It filters the
  /// sparkline and the calendar together — one click re-reads the whole page.
  LeetCodeDifficulty? _selected;

  void _toggle(LeetCodeDifficulty difficulty) => setState(() {
    _selected = _selected == difficulty ? null : difficulty;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problems =
        ref.watch(leetcodeProblemsProvider).valueOrNull ?? const [];
    final byDay = leetCodeCountsByDay(problems);
    final window = leetCodeActivityWindow(byDay: byDay, today: DateTime.now());

    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Problems solved per day',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(PhosphorIconsRegular.x, size: 20),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Its own row rather than pinned to the title's right: three
              // full capsules and a title don't both fit across a phone-width
              // overlay, and these are controls now, not a footnote.
              Align(
                alignment: Alignment.centerLeft,
                child: LeetCodeActivityLegend(
                  window: window,
                  selected: _selected,
                  onSelect: _toggle,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: _kExpandedSparklineHeight,
                child: Padding(
                  // Right inset so the last day's curve doesn't run into the
                  // card's edge, and the bubble it raises has somewhere to sit.
                  padding: const EdgeInsets.only(right: 8),
                  child: LeetCodeActivityChart(
                    window: window,
                    selected: _selected,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LeetCodeActivityCalendar(
                  byDay: byDay,
                  difficulty: _selected,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
