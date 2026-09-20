import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_entry.dart';
import 'package:voyager/features/leetcode/leetcode_dashboard.dart';
import 'package:voyager/features/leetcode/leetcode_review_deck.dart';

enum _LeetCodeViewMode { dashboard, reviewDeck }

final _leetCodeViewModeProvider = StateProvider<_LeetCodeViewMode>(
  (_) => _LeetCodeViewMode.dashboard,
);

class LeetCodePage extends ConsumerWidget {
  const LeetCodePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(_leetCodeViewModeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: GlassButton(
        tooltip: 'Track a problem',
        label: 'Track',
        icon: const Icon(PhosphorIconsRegular.plus),
        onPressed: () => startLeetCodeTrackFlow(context, ref),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  SegmentedButton<_LeetCodeViewMode>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: _LeetCodeViewMode.dashboard,
                        icon: Icon(PhosphorIconsRegular.gridFour, size: 15),
                        label: Text('Dashboard'),
                      ),
                      ButtonSegment(
                        value: _LeetCodeViewMode.reviewDeck,
                        icon: Icon(PhosphorIconsRegular.cards, size: 15),
                        label: Text('Review Deck'),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (set) {
                      if (set.isNotEmpty) {
                        ref.read(_leetCodeViewModeProvider.notifier).state =
                            set.first;
                      }
                    },
                  ),
                  const Spacer(),
                  // Right-aligned opposite the segmented control, and nowhere
                  // near the Track FAB in the bottom-right corner.
                  _ArrivingCheatSheetButton(mode: mode),
                ],
              ),
            ),
            Expanded(
              // Glass-safe: arrive stays opaque so review-deck BackdropFilter
              // glass keeps sampling the real backdrop; depart fades + recedes.
              child: VoyagerCrossfadeIndex(
                index: mode.index,
                fadeIncoming: false,
                children: const [LeetCodeDashboard(), LeetCodeReviewDeck()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The cheat sheet button, moving with the view it sits above rather than
/// staying put while everything under it changes.
///
/// [VoyagerCrossfadeIndex] cannot simply wrap it: that builds a
/// `StackFit.expand` Stack, and the header [Row] hands an unbounded width to a
/// child that is not flexible. So the arriving half of the same transition is
/// applied here — full opacity, enlarging from `1 - [kVoyagerCrossfadeRecede]`
/// over [kVoyagerCrossfadeDuration], which is exactly what the incoming page
/// does. Only the arriving half: the button belongs to both views, so there is
/// no departing copy for it to dissolve out of.
class _ArrivingCheatSheetButton extends StatelessWidget {
  const _ArrivingCheatSheetButton({required this.mode});

  /// Drives the animation by keying it. [TweenAnimationBuilder] restarts on a
  /// changed end value, and this tween's end is always 1 — a new key on every
  /// switch is what makes it run.
  final _LeetCodeViewMode mode;

  @override
  Widget build(BuildContext context) {
    const button = LeetCodeCheatSheetButton(dense: true);
    // The body drops its own scale under reduced motion; this follows it.
    if (VoyagerMotion.reduced(context)) return button;
    return TweenAnimationBuilder<double>(
      key: ValueKey(mode),
      tween: Tween(begin: 1 - kVoyagerCrossfadeRecede, end: 1),
      // Linear, like the crossfade's own progress — it applies no curve.
      duration: kVoyagerCrossfadeDuration,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: button,
    );
  }
}
