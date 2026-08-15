import 'dart:convert';

// ignore_for_file: prefer_initializing_formals
import 'package:http/http.dart' as http;
import 'package:voyager/data/remote/leetcode_content.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';

/// Hand-rolled client for LeetCode's public (unofficial, unauthenticated)
/// GraphQL endpoint — the same approach community LeetCode trackers use.
/// No official public API exists for problem metadata.
class LeetCodeApiClient {
  LeetCodeApiClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  static final Uri _endpoint = Uri.parse('https://leetcode.com/graphql');

  Future<LeetCodeQuestionCounts> fetchQuestionCounts() async {
    final data = await _post(
      'query allQuestionsCount { allQuestionsCount { difficulty count } }',
      const {},
    );
    final entries = data['allQuestionsCount'] as List<dynamic>?;
    if (entries == null) {
      throw Exception('Unexpected LeetCode API response (missing counts).');
    }
    int? easy, medium, hard;
    for (final raw in entries) {
      final entry = raw as Map<String, dynamic>;
      final difficulty = (entry['difficulty'] as String?)?.toLowerCase();
      final count = (entry['count'] as num?)?.toInt();
      if (count == null) continue;
      switch (difficulty) {
        case 'easy':
          easy = count;
        case 'medium':
          medium = count;
        case 'hard':
          hard = count;
      }
    }
    if (easy == null || medium == null || hard == null) {
      throw Exception('LeetCode API did not return all difficulty counts.');
    }
    return LeetCodeQuestionCounts(easy: easy, medium: medium, hard: hard);
  }

  /// Fetches the given user's most recently accepted submission and returns
  /// its full question metadata, or `null` if they have no accepted
  /// submissions (or [username] doesn't resolve to a real profile).
  Future<LeetCodeApiQuestion?> fetchMostRecentAcceptedSubmission(
    String username,
  ) async {
    final data = await _post(
      '''
      query recentAcSubmissions(\$username: String!, \$limit: Int!) {
        recentAcSubmissionList(username: \$username, limit: \$limit) {
          titleSlug
          lang
        }
      }
      ''',
      {'username': username, 'limit': 1},
    );
    final submissions = data['recentAcSubmissionList'] as List<dynamic>?;
    if (submissions == null || submissions.isEmpty) return null;
    final submission = submissions.first as Map<String, dynamic>;
    final titleSlug = submission['titleSlug'] as String?;
    if (titleSlug == null || titleSlug.isEmpty) return null;
    final question = await fetchBySlug(titleSlug);
    // The question lookup knows nothing about how it was reached, so the
    // submission's own language is carried across here — it's what the Track
    // modal preselects in its language row.
    return question.withSubmissionLanguage(submission['lang'] as String?);
  }

  Future<LeetCodeApiQuestion> fetchBySlug(String titleSlug) async {
    final data = await _post(
      '''
      query questionBySlug(\$titleSlug: String!) {
        question(titleSlug: \$titleSlug) {
          questionId
          questionFrontendId
          title
          titleSlug
          difficulty
          content
          topicTags { name }
        }
      }
      ''',
      {'titleSlug': titleSlug},
    );
    final question = data['question'] as Map<String, dynamic>?;
    if (question == null) {
      throw Exception('No LeetCode problem found for "$titleSlug".');
    }
    return _questionFromJson(question, includeContent: true);
  }

  /// Searches by title. LeetCode's search query shape has shifted across API
  /// versions in community trackers, so on any failure this falls back to a
  /// naive slugification of [query] fed into [fetchBySlug] — degraded but
  /// still functional for an exact/near-exact title match.
  Future<List<LeetCodeApiQuestion>> searchByTitle(
    String query, {
    int limit = 8,
  }) async {
    try {
      final data = await _post(
        '''
        query problemsetQuestionList(\$limit: Int, \$searchKeywords: String) {
          problemsetQuestionList: questionList(
            categorySlug: ""
            limit: \$limit
            skip: 0
            filters: { searchKeywords: \$searchKeywords }
          ) {
            questions: data {
              questionFrontendId
              title
              titleSlug
              difficulty
              topicTags { name }
            }
          }
        }
        ''',
        {'limit': limit, 'searchKeywords': query},
      );
      final questions =
          (data['problemsetQuestionList']
                  as Map<String, dynamic>?)?['questions']
              as List<dynamic>?;
      if (questions == null) {
        throw Exception('Unexpected LeetCode search response shape.');
      }
      return [
        for (final raw in questions)
          _questionFromJson(raw as Map<String, dynamic>),
      ];
    } catch (_) {
      final slug = _naiveSlugify(query);
      if (slug.isEmpty) return const [];
      try {
        return [await fetchBySlug(slug)];
      } catch (_) {
        return const [];
      }
    }
  }

  String _naiveSlugify(String title) {
    final lower = title.trim().toLowerCase();
    final stripped = lower.replaceAll(RegExp(r'[^a-z0-9\s-]'), '');
    return stripped.trim().replaceAll(RegExp(r'\s+'), '-');
  }

  LeetCodeApiQuestion _questionFromJson(
    Map<String, dynamic> json, {
    bool includeContent = false,
  }) {
    final topicTags = (json['topicTags'] as List<dynamic>? ?? const [])
        .map((t) => (t as Map<String, dynamic>)['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    return LeetCodeApiQuestion(
      questionId: json['questionId'] as String? ?? '',
      questionFrontendId: json['questionFrontendId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      titleSlug: json['titleSlug'] as String? ?? '',
      difficulty: _parseDifficulty(json['difficulty'] as String?),
      topicTags: topicTags,
      description: includeContent
          ? leetCodeContentToDescription(json['content'] as String?)
          : null,
      examples: includeContent
          ? leetCodeContentToExamples(json['content'] as String?)
          : const [],
    );
  }

  LeetCodeDifficulty _parseDifficulty(String? value) {
    switch (value?.toLowerCase()) {
      case 'easy':
        return LeetCodeDifficulty.easy;
      case 'hard':
        return LeetCodeDifficulty.hard;
      default:
        return LeetCodeDifficulty.medium;
    }
  }

  Future<Map<String, dynamic>> _post(
    String query,
    Map<String, dynamic> variables,
  ) async {
    final response = await _http.post(
      _endpoint,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'query': query, 'variables': variables}),
    );
    if (response.statusCode >= 400) {
      throw Exception('LeetCode API request failed (${response.statusCode}).');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw Exception('LeetCode API returned an invalid response.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected LeetCode API response shape.');
    }
    if (decoded['errors'] != null) {
      throw Exception('LeetCode API returned errors: ${decoded['errors']}');
    }
    final data = decoded['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Unexpected LeetCode API response shape (missing "data").');
    }
    return data;
  }
}
