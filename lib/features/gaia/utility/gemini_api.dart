import 'dart:convert';

import 'package:http/http.dart' as http;

/// Why a Gemini API call failed, as the utility model reports it.
enum GeminiFailure {
  /// 400/401/403: a key Google rejects.
  badKey,

  /// 429 `RESOURCE_EXHAUSTED`: the key's quota is used up for now.
  exhausted,

  /// Anything else: network, server, or a reply that isn't the documented
  /// shape.
  other,
}

class GeminiApiException implements Exception {
  GeminiApiException(this.failure, this.message);

  final GeminiFailure failure;
  final String message;

  @override
  String toString() => 'GeminiApiException(${failure.name}): $message';
}

/// The Gemini API's `generateContent` (GAIA_HLD.md §5.1), unstreamed: the
/// utility model's jobs are short, and want one whole answer. A documented,
/// versioned API, unlike the CLIs' output, so no fixtures are recorded from
/// a live key; the shapes read are the documented ones.
class GeminiApi {
  GeminiApi({required this.key, required this.model, http.Client? client})
    : _client = client ?? http.Client();

  final String key;
  final String model;
  final http.Client _client;

  static const _base = 'https://generativelanguage.googleapis.com/v1beta';

  /// [system] as the system instruction and [prompt] as the one user turn;
  /// the reply's text. Throws a [GeminiApiException].
  Future<String> generate({
    required String system,
    required String prompt,
  }) async {
    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse('$_base/models/$model:generateContent'),
        headers: {'content-type': 'application/json', 'x-goog-api-key': key},
        body: jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': system},
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {'temperature': 0},
        }),
      );
    } catch (error) {
      throw GeminiApiException(GeminiFailure.other, '$error');
    }
    return parseGeminiResponse(response.statusCode, response.body);
  }

  void close() => _client.close();
}

/// The text of a `generateContent` reply, past any thought parts; or the
/// failure its error body describes.
String parseGeminiResponse(int status, String body) {
  Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    json = null;
  }
  if (status != 200) {
    final message = switch (json) {
      {'error': {'message': final String message}} => message,
      _ => 'HTTP $status',
    };
    throw GeminiApiException(switch (status) {
      400 || 401 || 403 => GeminiFailure.badKey,
      429 => GeminiFailure.exhausted,
      _ => GeminiFailure.other,
    }, message);
  }
  if (json case {
    'candidates': [{'content': {'parts': final List parts}}, ...],
  }) {
    return [
      for (final part in parts)
        if (part case {'text': final String text} when part['thought'] != true)
          text,
    ].join().trim();
  }
  throw GeminiApiException(GeminiFailure.other, 'no candidate in the reply');
}
