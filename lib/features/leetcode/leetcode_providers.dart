import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/leetcode/leetcode_mini_flashcard.dart';

/// Keyword filter typed into the Review Deck's control bar.
final leetCodeDeckSearchQueryProvider = StateProvider<String>((ref) => '');

/// Difficulties the Review Deck is narrowed to. Empty means no narrowing —
/// the same thing as all three selected, but it keeps "no filter" as the
/// state the page opens in rather than something the user has to restore.
final leetCodeDeckDifficultyFilterProvider =
    StateProvider<Set<LeetCodeDifficulty>>((ref) => const {});

/// Tags the Review Deck is narrowed to. A problem has to carry every selected
/// tag to survive the filter — narrowing by "dp" then "binary-search" should
/// find the problems that are both, not the pile that is either. Held
/// lowercased: tags match ignoring case.
final leetCodeDeckTagFilterProvider = StateProvider<Set<String>>(
  (ref) => const {},
);

/// Lowercased front/back search haystacks per problem id, rebuilt only when
/// the library itself changes rather than on every keystroke.
///
/// Deriving them inline cost four full string builds per visible tile per
/// character typed — two for the filter and two more for the grid's
/// back-only check — over the id, title, whole description, every tag, and
/// every solution's algorithm, complexities and explanation.
final leetCodeDeckSearchIndexProvider =
    Provider<Map<String, LeetCodeSearchText>>((ref) {
      final problems =
          ref.watch(leetcodeProblemsProvider.settled).valueOrNull ?? const [];
      return {for (final p in problems) p.id: leetCodeSearchTextFor(p)};
    });

/// The time the LeetCode pages read "today" and "due" at, recomputed at the
/// next local midnight or the next moment a problem comes due, whichever is
/// sooner. The pages stay mounted between visits and the app runs all day
/// from the tray, so a time read once at build left "Last 30 days", the
/// tiles' days-until-due and the due count on whenever they last rebuilt.
final leetCodeClockProvider = Provider.autoDispose<DateTime>((ref) {
  final now = DateTime.now();
  var next = DateTime(now.year, now.month, now.day + 1);
  final problems =
      ref.watch(leetcodeProblemsProvider.settled).valueOrNull ?? const [];
  for (final problem in problems) {
    final due = problem.dueAt?.toLocal();
    if (due != null && due.isAfter(now) && due.isBefore(next)) next = due;
  }
  final timer = Timer(next.difference(now), ref.invalidateSelf);
  // A timer's countdown may not run while the PC sleeps, so a long one can
  // wake hours late. The wall clock is checked each minute as well, and the
  // pages rebuild only once the moment has actually passed.
  final wake = Timer.periodic(const Duration(minutes: 1), (_) {
    if (!DateTime.now().isBefore(next)) ref.invalidateSelf();
  });
  ref.onDispose(() {
    timer.cancel();
    wake.cancel();
  });
  return now;
});
