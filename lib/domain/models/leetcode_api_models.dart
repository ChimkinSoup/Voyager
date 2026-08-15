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
    this.description,
    this.examples = const [],
    this.submissionLanguage,
  });

  final String questionId;
  final String questionFrontendId;
  final String title;
  final String titleSlug;
  final LeetCodeDifficulty difficulty;
  final List<String> topicTags;

  /// Plain-text problem statement (examples stripped). Null on search-list
  /// hits that never fetched full question content.
  final String? description;

  /// The worked examples that [description] leaves out, one per entry. Empty
  /// on search-list hits, and on questions that ship no examples.
  final List<String> examples;

  /// The `lang` of the submission this question was reached through, as
  /// LeetCode spells it ("python3", "golang", …), or null when the question
  /// wasn't reached through a submission at all — a search hit or a direct
  /// slug lookup. It's a property of *how the question was found*, not of the
  /// question, which is why it lives beside the metadata rather than in it.
  final String? submissionLanguage;

  LeetCodeApiQuestion withSubmissionLanguage(String? language) =>
      LeetCodeApiQuestion(
        questionId: questionId,
        questionFrontendId: questionFrontendId,
        title: title,
        titleSlug: titleSlug,
        difficulty: difficulty,
        topicTags: topicTags,
        description: description,
        examples: examples,
        submissionLanguage: language,
      );
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
