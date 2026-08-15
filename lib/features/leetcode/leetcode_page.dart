import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
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
              child: Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<_LeetCodeViewMode>(
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
              ),
            ),
            Expanded(
              // Glass-safe: arrive stays opaque so review-deck BackdropFilter
              // glass keeps sampling the real backdrop; depart fades + recedes.
              child: VoyagerCrossfadeIndex(
                index: mode.index,
                fadeIncoming: false,
                children: const [
                  LeetCodeDashboard(),
                  LeetCodeReviewDeck(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
