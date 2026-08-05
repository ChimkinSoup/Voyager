import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/features/leetcode/leetcode_dashboard.dart';
import 'package:voyager/features/leetcode/leetcode_loading_toast.dart';
import 'package:voyager/features/leetcode/leetcode_review_deck.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';

enum _LeetCodeViewMode { dashboard, reviewDeck }

final _leetCodeViewModeProvider = StateProvider<_LeetCodeViewMode>(
  (_) => _LeetCodeViewMode.dashboard,
);

class LeetCodePage extends ConsumerWidget {
  const LeetCodePage({super.key});

  Future<void> _handleTrackTap(BuildContext context, WidgetRef ref) async {
    final username = ref.read(settingsProvider).value?.leetcodeUsername?.trim();
    if (username == null || username.isEmpty) {
      await showLeetCodeTrackModal(context, ref);
      return;
    }

    final dismissToast = showLeetCodeLoadingToast(
      context,
      message: 'Fetching your latest submission…',
    );
    try {
      final recent = await ref
          .read(leetCodeApiClientProvider)
          .fetchMostRecentAcceptedSubmission(username);
      dismissToast();
      if (!context.mounted) return;
      await showLeetCodeTrackModal(context, ref, prefill: recent);
    } catch (_) {
      dismissToast();
      if (!context.mounted) return;
      await showLeetCodeTrackModal(context, ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(_leetCodeViewModeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: GlassButton(
        tooltip: 'Track a problem',
        label: 'Track',
        icon: const Icon(PhosphorIconsRegular.plus),
        onPressed: () => _handleTrackTap(context, ref),
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
                      ref.read(_leetCodeViewModeProvider.notifier).state = set.first;
                    }
                  },
                ),
              ),
            ),
            Expanded(
              child: mode == _LeetCodeViewMode.dashboard
                  ? const LeetCodeDashboard()
                  : const LeetCodeReviewDeck(),
            ),
          ],
        ),
      ),
    );
  }
}
