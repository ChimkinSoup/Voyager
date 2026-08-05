import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

class LeetCodeProblem extends SoftDeletable {
  const LeetCodeProblem({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.title,
    this.questionId,
    this.questionFrontendId,
    this.titleSlug,
    required this.difficulty,
    this.tags = const [],
    this.algorithm = '',
    this.timeComplexity,
    this.spaceComplexity,
    this.explanation = '',
    this.codeLanguage = 'python',
    this.code = '',
    this.notes,
    required this.solvedAt,
  });

  final String title;
  final String? questionId;
  final String? questionFrontendId;
  final String? titleSlug;
  final LeetCodeDifficulty difficulty;
  final List<String> tags;
  final String algorithm;
  final String? timeComplexity;
  final String? spaceComplexity;
  final String explanation;
  final String codeLanguage;
  final String code;
  final String? notes;
  final DateTime solvedAt;

  /// Derived from [titleSlug] rather than stored, so it can never diverge
  /// from the slug the problem was actually fetched/saved under.
  String? get leetcodeUrl =>
      titleSlug == null ? null : 'https://leetcode.com/problems/$titleSlug/';

  LeetCodeProblem copyWith({
    String? title,
    String? questionId,
    String? questionFrontendId,
    String? titleSlug,
    LeetCodeDifficulty? difficulty,
    List<String>? tags,
    String? algorithm,
    String? timeComplexity,
    String? spaceComplexity,
    String? explanation,
    String? codeLanguage,
    String? code,
    String? notes,
    DateTime? solvedAt,
    DateTime? deletedAt,
    int? version,
    bool bumpVersion = true,
  }) {
    return LeetCodeProblem(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: version ?? (bumpVersion ? this.version + 1 : this.version),
      deletedAt: deletedAt ?? this.deletedAt,
      title: title ?? this.title,
      questionId: questionId ?? this.questionId,
      questionFrontendId: questionFrontendId ?? this.questionFrontendId,
      titleSlug: titleSlug ?? this.titleSlug,
      difficulty: difficulty ?? this.difficulty,
      tags: tags ?? this.tags,
      algorithm: algorithm ?? this.algorithm,
      timeComplexity: timeComplexity ?? this.timeComplexity,
      spaceComplexity: spaceComplexity ?? this.spaceComplexity,
      explanation: explanation ?? this.explanation,
      codeLanguage: codeLanguage ?? this.codeLanguage,
      code: code ?? this.code,
      notes: notes ?? this.notes,
      solvedAt: solvedAt ?? this.solvedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'version': version,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'title': title,
    'questionId': questionId,
    'questionFrontendId': questionFrontendId,
    'titleSlug': titleSlug,
    'difficulty': difficulty.name,
    'tags': tags,
    'algorithm': algorithm,
    'timeComplexity': timeComplexity,
    'spaceComplexity': spaceComplexity,
    'explanation': explanation,
    'codeLanguage': codeLanguage,
    'code': code,
    'notes': notes,
    'solvedAt': solvedAt.toUtc().toIso8601String(),
  };

  factory LeetCodeProblem.fromJson(Map<String, dynamic> json) {
    return LeetCodeProblem(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      version: json['version'] as int? ?? 0,
      deletedAt: json['deletedAt'] != null
          ? DateTime.parse(json['deletedAt'] as String).toUtc()
          : null,
      title: json['title'] as String,
      questionId: json['questionId'] as String?,
      questionFrontendId: json['questionFrontendId'] as String?,
      titleSlug: json['titleSlug'] as String?,
      difficulty: LeetCodeDifficulty.values.byName(
        json['difficulty'] as String? ?? 'medium',
      ),
      tags: List<String>.from(json['tags'] as List? ?? const []),
      algorithm: json['algorithm'] as String? ?? '',
      timeComplexity: json['timeComplexity'] as String?,
      spaceComplexity: json['spaceComplexity'] as String?,
      explanation: json['explanation'] as String? ?? '',
      codeLanguage: json['codeLanguage'] as String? ?? 'python',
      code: json['code'] as String? ?? '',
      notes: json['notes'] as String?,
      solvedAt: DateTime.parse(json['solvedAt'] as String).toUtc(),
    );
  }
}

int compareLeetCodeProblemsNewestFirst(LeetCodeProblem a, LeetCodeProblem b) {
  final bySolved = b.solvedAt.compareTo(a.solvedAt);
  if (bySolved != 0) return bySolved;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return b.id.compareTo(a.id);
}

List<LeetCodeProblem> sortLeetCodeProblemsNewestFirst(
  Iterable<LeetCodeProblem> problems,
) {
  final sorted = problems.toList()..sort(compareLeetCodeProblemsNewestFirst);
  return sorted;
}
