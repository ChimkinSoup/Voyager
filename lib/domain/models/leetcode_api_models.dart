import 'package:voyager/domain/models/enums.dart';

/// A problem as returned by the public LeetCode GraphQL API. Deliberately
/// separate from [LeetCodeProblem] (the persisted, user-authored record) —
/// the API shape and the stored shape diverge (this carries no algorithm,
/// code, or notes; the stored model carries no API-only fields).
class LeetCodeApiQuestion {
  const LeetCodeApiQuestion({
    required this.questionId,
    required this.questionFrontendId,
    required this.title,
    required this.titleSlug,
    required this.difficulty,
    required this.topicTags,
  });

  final String questionId;
  final String questionFrontendId;
  final String title;
  final String titleSlug;
  final LeetCodeDifficulty difficulty;
  final List<String> topicTags;
}

class LeetCodeQuestionCounts {
  const LeetCodeQuestionCounts({
    required this.easy,
    required this.medium,
    required this.hard,
  });

  final int easy;
  final int medium;
  final int hard;

  int get total => easy + medium + hard;
}
