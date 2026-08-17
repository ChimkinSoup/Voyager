import 'package:voyager/domain/models/enums.dart';

/// Bumped whenever the persisted shape changes in a way an older blob can't be
/// read as. A blob from a different version is discarded rather than migrated —
/// it's one unsaved form, not user data worth carrying forward.
const int kLeetCodeTrackDraftVersion = 1;

/// One solution group of an in-progress Track form, exactly as typed.
///
/// Deliberately not [LeetCodeSolution]: that model trims every box and is
/// dropped when empty, which is right for a saved problem and wrong for a
/// draft, where a blank row the user added is part of the form to restore.
class LeetCodeTrackDraftSolution {
  const LeetCodeTrackDraftSolution({
    this.algorithm = '',
    this.timeComplexity = '',
    this.spaceComplexity = '',
    this.explanation = '',
    required this.codeLanguage,
    this.code = '',
    this.notes = '',
  });

  final String algorithm;
  final String timeComplexity;
  final String spaceComplexity;
  final String explanation;
  final String codeLanguage;
  final String code;
  final String notes;

  /// Whether any box in this group has non-blank text. The language is not
  /// text the user wrote, so it doesn't count — see [LeetCodeTrackDraft.hasText].
  bool get hasText =>
      algorithm.trim().isNotEmpty ||
      timeComplexity.trim().isNotEmpty ||
      spaceComplexity.trim().isNotEmpty ||
      explanation.trim().isNotEmpty ||
      code.trim().isNotEmpty ||
      notes.trim().isNotEmpty;

  bool sameContentAs(LeetCodeTrackDraftSolution other) =>
      algorithm == other.algorithm &&
      timeComplexity == other.timeComplexity &&
      spaceComplexity == other.spaceComplexity &&
      explanation == other.explanation &&
      codeLanguage == other.codeLanguage &&
      code == other.code &&
      notes == other.notes;

  Map<String, dynamic> toJson() => {
    'algorithm': algorithm,
    'timeComplexity': timeComplexity,
    'spaceComplexity': spaceComplexity,
    'explanation': explanation,
    'codeLanguage': codeLanguage,
    'code': code,
    'notes': notes,
  };

  factory LeetCodeTrackDraftSolution.fromJson(Map<String, dynamic> json) =>
      LeetCodeTrackDraftSolution(
        algorithm: json['algorithm'] as String? ?? '',
        timeComplexity: json['timeComplexity'] as String? ?? '',
        spaceComplexity: json['spaceComplexity'] as String? ?? '',
        explanation: json['explanation'] as String? ?? '',
        codeLanguage: json['codeLanguage'] as String? ?? 'python',
        code: json['code'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
      );
}

/// A create-mode Track form captured whole: every field as typed, every row
/// that exists, and the hidden LeetCode identifiers the form is carrying.
///
/// This is not a [LeetCodeProblem] and never becomes one directly — nothing
/// here implies a review schedule, an id, or a place in the sync pipeline.
class LeetCodeTrackDraft {
  const LeetCodeTrackDraft({
    required this.title,
    required this.questionFrontendId,
    required this.tags,
    required this.description,
    required this.examples,
    required this.difficulty,
    required this.solutions,
    this.titleSlug,
    this.questionId,
    required this.savedAt,
  });

  final String title;
  final String questionFrontendId;

  /// The tags *field text*, not parsed tokens — restoring the form means
  /// restoring what was in the box, half-typed `#` and all.
  final String tags;
  final String description;
  final List<String> examples;
  final LeetCodeDifficulty difficulty;
  final List<LeetCodeTrackDraftSolution> solutions;
  final String? titleSlug;
  final String? questionId;
  final DateTime savedAt;

  /// Whether the form holds anything the user would miss.
  ///
  /// Blank rows, a difficulty pill, and language selectors are structure, not
  /// content: a form with no text left in it is cleared rather than persisted
  /// as a hollow blob.
  bool get hasText =>
      title.trim().isNotEmpty ||
      questionFrontendId.trim().isNotEmpty ||
      tags.trim().isNotEmpty ||
      description.trim().isNotEmpty ||
      examples.any((e) => e.trim().isNotEmpty) ||
      solutions.any((s) => s.hasText);

  /// Everything except [savedAt] — which is bookkeeping, not form state, and
  /// so must not make an untouched form look changed.
  bool sameContentAs(LeetCodeTrackDraft other) {
    if (title != other.title ||
        questionFrontendId != other.questionFrontendId ||
        tags != other.tags ||
        description != other.description ||
        difficulty != other.difficulty ||
        titleSlug != other.titleSlug ||
        questionId != other.questionId ||
        examples.length != other.examples.length ||
        solutions.length != other.solutions.length) {
      return false;
    }
    for (var i = 0; i < examples.length; i++) {
      if (examples[i] != other.examples[i]) return false;
    }
    for (var i = 0; i < solutions.length; i++) {
      if (!solutions[i].sameContentAs(other.solutions[i])) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'version': kLeetCodeTrackDraftVersion,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'title': title,
    'questionFrontendId': questionFrontendId,
    'tags': tags,
    'description': description,
    'examples': examples,
    'difficulty': difficulty.name,
    'titleSlug': titleSlug,
    'questionId': questionId,
    'solutions': [for (final s in solutions) s.toJson()],
  };

  /// Throws on anything it can't read, which the store turns into "no draft".
  factory LeetCodeTrackDraft.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int?;
    if (version != kLeetCodeTrackDraftVersion) {
      throw FormatException('Unsupported draft version: $version');
    }
    return LeetCodeTrackDraft(
      title: json['title'] as String? ?? '',
      questionFrontendId: json['questionFrontendId'] as String? ?? '',
      tags: json['tags'] as String? ?? '',
      description: json['description'] as String? ?? '',
      examples: [
        for (final e in (json['examples'] as List<dynamic>? ?? const []))
          e as String,
      ],
      difficulty: LeetCodeDifficulty.values.byName(
        json['difficulty'] as String? ?? 'medium',
      ),
      titleSlug: json['titleSlug'] as String?,
      questionId: json['questionId'] as String?,
      solutions: [
        for (final s in (json['solutions'] as List<dynamic>? ?? const []))
          LeetCodeTrackDraftSolution.fromJson(
            Map<String, dynamic>.from(s as Map),
          ),
      ],
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}

/// Whether a draft should be resumed for the question the Track flow just
/// looked up. Trim + case-insensitive, and a draft with no name never matches
/// anything — there is nothing to compare it by.
bool leetCodeTrackDraftMatches(LeetCodeTrackDraft draft, String questionTitle) {
  final a = draft.title.trim().toLowerCase();
  final b = questionTitle.trim().toLowerCase();
  return a.isNotEmpty && a == b;
}
