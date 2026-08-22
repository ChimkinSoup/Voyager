import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// One way of solving a problem: the approach, what it costs, the walkthrough,
/// the code, and whatever the user wanted to remember about *this* way of
/// doing it.
///
/// A problem holds a list of these. The "Solution 1", "Solution 2" … headings
/// come from list position rather than being stored, the same way the worked
/// examples are numbered — so deleting one renumbers the rest for free, and a
/// problem with a single solution can render with no heading at all.
class LeetCodeSolution {
  const LeetCodeSolution({
    this.algorithm = '',
    this.timeComplexity,
    this.spaceComplexity,
    this.explanation = '',
    this.codeLanguage = 'python',
    this.code = '',
    this.notes,
  });

  final String algorithm;
  final String? timeComplexity;
  final String? spaceComplexity;
  final String explanation;

  /// Per solution rather than per problem: a second pass at the same question
  /// is often a rewrite in another language.
  final String codeLanguage;
  final String code;
  final String? notes;

  /// Nothing written in any box. The editor drops these on save rather than
  /// storing an "Add solution" the user never filled in — same rule the
  /// examples editor uses for blank boxes.
  bool get isEmpty =>
      algorithm.trim().isEmpty &&
      (timeComplexity ?? '').trim().isEmpty &&
      (spaceComplexity ?? '').trim().isEmpty &&
      explanation.trim().isEmpty &&
      code.trim().isEmpty &&
      (notes ?? '').trim().isEmpty;

  Map<String, dynamic> toJson() => {
    'algorithm': algorithm,
    'timeComplexity': timeComplexity,
    'spaceComplexity': spaceComplexity,
    'explanation': explanation,
    'codeLanguage': codeLanguage,
    'code': code,
    'notes': notes,
  };

  factory LeetCodeSolution.fromJson(Map<String, dynamic> json) {
    return LeetCodeSolution(
      algorithm: json['algorithm'] as String? ?? '',
      timeComplexity: json['timeComplexity'] as String?,
      spaceComplexity: json['spaceComplexity'] as String?,
      explanation: json['explanation'] as String? ?? '',
      codeLanguage: json['codeLanguage'] as String? ?? 'python',
      code: json['code'] as String? ?? '',
      notes: json['notes'] as String?,
    );
  }

  static List<LeetCodeSolution> listFromJson(List<dynamic> raw) => [
    for (final entry in raw)
      LeetCodeSolution.fromJson(Map<String, dynamic>.from(entry as Map)),
  ];
}

/// The solution a record written before this field existed carried in its flat
/// `algorithm`/`code`/… fields, as a one-entry list — or an empty list when
/// every one of them was blank, since that record had no solution to keep.
///
/// Shared by the JSON importer, the remote merge, and the database migration:
/// all three read the same set of legacy fields.
List<LeetCodeSolution> leetCodeSolutionsFromLegacyFields({
  String? algorithm,
  String? timeComplexity,
  String? spaceComplexity,
  String? explanation,
  String? codeLanguage,
  String? code,
  String? notes,
}) {
  final solution = LeetCodeSolution(
    algorithm: algorithm ?? '',
    timeComplexity: timeComplexity,
    spaceComplexity: spaceComplexity,
    explanation: explanation ?? '',
    codeLanguage: codeLanguage ?? 'python',
    code: code ?? '',
    notes: notes,
  );
  return solution.isEmpty ? const [] : [solution];
}

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
    this.description,
    this.examples = const [],
    this.solutions = const [],
    required this.solvedAt,
    this.interval = 0,
    this.ease = 2.5,
    this.dueAt,
    this.reviewCount = 0,
  });

  final String title;
  final String? questionId;
  final String? questionFrontendId;
  final String? titleSlug;
  final LeetCodeDifficulty difficulty;
  final List<String> tags;

  /// Problem statement shown on the flashcard front. Null for problems
  /// tracked before this field existed (or when the user cleared it).
  final String? description;

  /// Worked examples, one entry per example, in display order. Each holds the
  /// Input/Output lines and that example's explanation together as plain text.
  ///
  /// The "Example 1", "Example 2" … headings are derived from position rather
  /// than stored, so deleting one renumbers the rest for free. Empty for
  /// problems tracked before this field existed.
  final List<String> examples;

  /// Every way the user has written this problem up, in display order.
  ///
  /// Empty for a problem tracked with nothing filled in past the statement.
  /// Records written before a problem could hold more than one solution have
  /// their single flat solution folded in here as the only entry.
  final List<LeetCodeSolution> solutions;
  final DateTime solvedAt;

  /// The solution shown when there is only room for one — the tile back, the
  /// "Copy code" action. Null when nothing has been written down yet.
  LeetCodeSolution? get primarySolution =>
      solutions.isEmpty ? null : solutions.first;

  /// The grammar inline `` `code` `` in the statement and the examples is
  /// tokenized with. Those fields belong to the problem rather than to any one
  /// solution, so they follow the first solution's language.
  String get codeLanguage => primarySolution?.codeLanguage ?? 'python';

  /// SM-2 review state, shared in spirit (and in arithmetic) with
  /// [StudyCard] — the Review Deck schedules problems the same way the Study
  /// page schedules flashcards. [interval] is in days; `interval <= 0` means
  /// no successful review yet.
  final double interval;
  final double ease;

  /// When this problem comes up for review again. Null for a problem that has
  /// never been graded, which reads as "due now" — that way tracking a
  /// problem puts it straight into the next study session, and problems
  /// tracked before the Review Deck learned to schedule need no backfill.
  final DateTime? dueAt;
  final int reviewCount;

  bool get isNew => reviewCount == 0;
  bool get isLearning => reviewCount > 0 && interval < 1;

  bool isDue({DateTime? now}) =>
      dueAt == null || !dueAt!.isAfter(now ?? DateTime.now().toUtc());

  /// Derived from [title] rather than stored, so the link always points at the
  /// problem name currently saved here.
  ///
  /// [titleSlug] is only what a GraphQL lookup returned at the time it ran;
  /// renaming the problem afterwards left the link pointing at the old one.
  /// The trade-off is that a title that isn't a real LeetCode problem name
  /// slugifies into a dead link — the title is treated as the source of truth
  /// either way.
  String? get leetcodeUrl {
    final slug = leetCodeTitleSlug(title);
    return slug.isEmpty ? null : 'https://leetcode.com/problems/$slug/';
  }

  LeetCodeProblem copyWith({
    String? title,
    String? questionId,
    String? questionFrontendId,
    String? titleSlug,
    LeetCodeDifficulty? difficulty,
    List<String>? tags,
    String? description,
    List<String>? examples,
    List<LeetCodeSolution>? solutions,
    DateTime? solvedAt,
    double? interval,
    double? ease,
    DateTime? dueAt,
    int? reviewCount,
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
      description: description ?? this.description,
      examples: examples ?? this.examples,
      solutions: solutions ?? this.solutions,
      solvedAt: solvedAt ?? this.solvedAt,
      interval: interval ?? this.interval,
      ease: ease ?? this.ease,
      dueAt: dueAt ?? this.dueAt,
      reviewCount: reviewCount ?? this.reviewCount,
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
    'description': description,
    'examples': examples,
    'solutions': [for (final solution in solutions) solution.toJson()],
    ...leetCodeLegacySolutionFields(primarySolution),
    'solvedAt': solvedAt.toUtc().toIso8601String(),
    'interval': interval,
    'ease': ease,
    'dueAt': dueAt?.toUtc().toIso8601String(),
    'reviewCount': reviewCount,
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
      description: json['description'] as String?,
      examples: List<String>.from(json['examples'] as List? ?? const []),
      // A record exported before a problem could hold more than one solution
      // has no list, only the flat fields — read those instead of importing
      // the write-up as blank.
      solutions: json['solutions'] != null
          ? LeetCodeSolution.listFromJson(json['solutions'] as List)
          : leetCodeSolutionsFromLegacyFields(
              algorithm: json['algorithm'] as String?,
              timeComplexity: json['timeComplexity'] as String?,
              spaceComplexity: json['spaceComplexity'] as String?,
              explanation: json['explanation'] as String?,
              codeLanguage: json['codeLanguage'] as String?,
              code: json['code'] as String?,
              notes: json['notes'] as String?,
            ),
      solvedAt: DateTime.parse(json['solvedAt'] as String).toUtc(),
      interval: (json['interval'] as num?)?.toDouble() ?? 0,
      ease: (json['ease'] as num?)?.toDouble() ?? 2.5,
      dueAt: json['dueAt'] != null
          ? DateTime.parse(json['dueAt'] as String).toUtc()
          : null,
      reviewCount: json['reviewCount'] as int? ?? 0,
    );
  }
}

/// [solution] written back into the flat fields a build that predates
/// alternative solutions reads, for the payloads those builds can still see:
/// exported JSON and the synced Firestore document.
///
/// Current builds ignore these keys entirely — the `solutions` list is the
/// source of truth. They exist so an older device shows the primary solution
/// instead of an empty card, and a null [solution] clears them rather than
/// leaving the last one it saw.
Map<String, dynamic> leetCodeLegacySolutionFields(LeetCodeSolution? solution) =>
    {
      'algorithm': solution?.algorithm ?? '',
      'timeComplexity': solution?.timeComplexity,
      'spaceComplexity': solution?.spaceComplexity,
      'explanation': solution?.explanation ?? '',
      'codeLanguage': solution?.codeLanguage ?? 'python',
      'code': solution?.code ?? '',
      'notes': solution?.notes,
    };

/// The `/problems/<slug>/` segment LeetCode uses for a problem of this name.
///
/// LeetCode's own scheme: lowercase, runs of anything that isn't a letter or
/// digit collapsed to a single hyphen, no leading or trailing hyphen. So
/// "Two Sum II - Input Array Is Sorted" becomes
/// "two-sum-ii-input-array-is-sorted".
String leetCodeTitleSlug(String title) {
  return title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

/// The key two tracked problems have to share to be the same LeetCode
/// question.
///
/// A stored [LeetCodeProblem.titleSlug] wins when a GraphQL lookup supplied
/// one, so renaming one copy doesn't hide it from the other; a problem tracked
/// by hand falls back to slugifying its title, which is what the lookup would
/// have stored anyway. Empty for a title that slugifies to nothing.
String leetCodeIdentityKey(LeetCodeProblem problem) {
  final stored = problem.titleSlug;
  if (stored != null && stored.isNotEmpty) return stored;
  return leetCodeTitleSlug(problem.title);
}

/// How many of [problems] share each identity key, keeping only the keys held
/// by more than one — i.e. the same question tracked twice.
///
/// Problems with an empty key are left out rather than piled together: a title
/// that slugifies to nothing says nothing about which question it is.
Map<String, int> leetCodeDuplicateCounts(Iterable<LeetCodeProblem> problems) {
  final counts = <String, int>{};
  for (final problem in problems) {
    final key = leetCodeIdentityKey(problem);
    if (key.isEmpty) continue;
    counts.update(key, (count) => count + 1, ifAbsent: () => 1);
  }
  counts.removeWhere((_, count) => count < 2);
  return counts;
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
