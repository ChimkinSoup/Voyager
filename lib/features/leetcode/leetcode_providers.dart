import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/domain/models/enums.dart';

/// Keyword filter typed into the Review Deck's control bar.
final leetCodeDeckSearchQueryProvider = StateProvider<String>((ref) => '');

/// Difficulties the Review Deck is narrowed to. Empty means no narrowing —
/// the same thing as all three selected, but it keeps "no filter" as the
/// state the page opens in rather than something the user has to restore.
final leetCodeDeckDifficultyFilterProvider =
    StateProvider<Set<LeetCodeDifficulty>>((ref) => const {});

/// Tags the Review Deck is narrowed to. A problem has to carry every selected
/// tag to survive the filter — narrowing by "dp" then "binary-search" should
/// find the problems that are both, not the pile that is either.
final leetCodeDeckTagFilterProvider = StateProvider<Set<String>>(
  (ref) => const {},
);
