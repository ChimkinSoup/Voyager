import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/utility/gemini_api.dart';

/// How long the router may hold up a new chat's first message before the
/// last used tier takes it (§7.2: it aims for about 300 ms).
const _routeTimeout = Duration(seconds: 2);
const _titleTimeout = Duration(seconds: 15);
const _summaryTimeout = Duration(seconds: 30);

/// Gaia's small internal jobs on the utility model (GAIA_HLD.md §5.1): the
/// tier router and chat titles. Gemini on an API key, for sub-second
/// answers a CLI's cold start can't give.
///
/// Off, and every job a null, until the user has saved a key on this device
/// and acknowledged the slot's terms (a paid-tier key, or Google may use
/// the prompts). Any failure is a null too: the caller falls back to what
/// Gaia does with no utility model.
class GaiaUtility {
  GaiaUtility({required this._readKey, this._client});

  final Future<String?> Function() _readKey;
  final http.Client Function()? _client;

  var model = kGaiaDefaultUtilityModel;
  var acknowledged = false;
  var autoRoute = true;

  /// The router's rubric; empty for [kGaiaDefaultRouterRubric].
  var rubric = '';

  void apply(Map<String, Object?> settings) {
    model = settings['utilityModel'] as String? ?? kGaiaDefaultUtilityModel;
    acknowledged = settings['utilityAcknowledged'] == true;
    autoRoute = settings['autoRoute'] != false;
    rubric = settings['routerRubric'] as String? ?? '';
  }

  Future<GeminiApi?> _api() async {
    if (!acknowledged || model.trim().isEmpty) return null;
    final key = await _readKey();
    if (key == null) return null;
    return GeminiApi(key: key, model: model.trim(), client: _client?.call());
  }

  /// The tier for a new chat's first message (§7.2), or null to use the
  /// last used one.
  Future<GaiaTier?> route(String prompt) async {
    if (!autoRoute) return null;
    final api = await _api();
    if (api == null) return null;
    try {
      final answer = await api
          .generate(
            system:
                "You route a user's message to one of three model tiers.\n\n"
                '${rubric.trim().isEmpty ? kGaiaDefaultRouterRubric : rubric}'
                '\n\nReply with exactly one word: quick, standard or deep.',
            prompt: _clip(prompt, 4000),
          )
          .timeout(_routeTimeout);
      return parseRoute(answer);
    } catch (error) {
      debugPrint('[gaia] router: $error');
      return null;
    } finally {
      api.close();
    }
  }

  /// A title for a chat from its first exchange, or null to keep the
  /// first-line one.
  Future<String?> title(String question, String reply) async {
    final api = await _api();
    if (api == null) return null;
    try {
      final answer = await api
          .generate(
            system:
                'Write a title of at most six words for a chat that starts '
                'with this exchange. Reply with the title only.',
            prompt:
                'User: ${_clip(question, 2000)}\n\n'
                'Assistant: ${_clip(reply, 2000)}',
          )
          .timeout(_titleTimeout);
      return cleanTitle(answer);
    } catch (error) {
      debugPrint('[gaia] title: $error');
      return null;
    } finally {
      api.close();
    }
  }

  /// A summary of [transcript] for an agent taking the chat over (§7.4),
  /// or null to leave the older turns out.
  Future<String?> summarize(String transcript) async {
    final api = await _api();
    if (api == null) return null;
    try {
      final answer = await api
          .generate(
            system:
                'Summarise this conversation in under 300 words for an '
                'assistant taking it over. Keep the facts, decisions and '
                'open questions; leave out pleasantries.',
            prompt: _clip(transcript, 200000),
          )
          .timeout(_summaryTimeout);
      return answer.trim().isEmpty ? null : answer.trim();
    } catch (error) {
      debugPrint('[gaia] summary: $error');
      return null;
    } finally {
      api.close();
    }
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : text.substring(0, max);
}

/// The tier a router answer names; null when it names none.
@visibleForTesting
GaiaTier? parseRoute(String answer) {
  final word = RegExp(r'[a-z]+').firstMatch(answer.toLowerCase())?.group(0);
  return switch (word) {
    'quick' => GaiaTier.quick,
    'standard' || 'std' => GaiaTier.standard,
    'deep' => GaiaTier.deep,
    _ => null,
  };
}

/// [answer]'s first line, without quotes, a heading mark or an end stop,
/// cut to 60 characters; null when nothing's left.
@visibleForTesting
String? cleanTitle(String answer) {
  var title = answer.trim().split('\n').first.trim();
  title = title.replaceAll(RegExp(r'''^[#*"'“‘\s]+|["'”’*.\s]+$'''), '');
  if (title.isEmpty) return null;
  return title.length > 60 ? '${title.substring(0, 60)}…' : title;
}
