import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/utility/claude_utility_runner.dart';

/// How long the router may hold up a new chat's first message before the
/// last used tier takes it (§7.2). Haiku answers in about a second from a
/// process started ahead ([warm]); a cold start took 2.6–4.2 s.
const _routeTimeout = Duration(seconds: 5);
const _titleTimeout = Duration(seconds: 15);
const _summaryTimeout = Duration(seconds: 30);
const _captionTimeout = Duration(seconds: 30);

/// Gaia's small internal jobs on the utility model (GAIA_HLD.md §5.1): the
/// tier router, chat titles, and handoff summaries and image captions. Haiku on Claude Code, on
/// the account Gaia's chats use.
///
/// Any failure is a null: the caller falls back to what Gaia does with no
/// utility model.
class GaiaUtility {
  GaiaUtility(this._runner);

  final ClaudeUtilityRunner _runner;

  var autoRoute = true;

  /// The router's rubric; empty for [kGaiaDefaultRouterRubric].
  var rubric = '';

  /// The tier the router picks when unsure; null for no lean.
  GaiaTier? defaultTier;

  void apply(Map<String, Object?> settings) {
    final model = (settings['utilityModel'] as String? ?? '').trim();
    _runner.configure(
      model: model.isEmpty ? kGaiaDefaultUtilityModel : model,
      configDir: settings['claudeConfigDir'] as String? ?? '',
    );
    autoRoute = settings['autoRoute'] != false;
    rubric = settings['routerRubric'] as String? ?? '';
    defaultTier = gaiaTierFromName(settings['defaultTier']);
  }

  /// A new chat is being written: the router will be asked soon.
  void warm() {
    if (!autoRoute) return;
    unawaited(
      _runner.warm().catchError((Object error) {
        debugPrint('[gaia] utility: $error');
      }),
    );
  }

  /// The tier for a new chat's first message (§7.2), or null to use the
  /// default or last used one.
  Future<GaiaTier?> route(String prompt) async {
    if (!autoRoute) {
      debugPrint('[gaia] router: off, using the default or last used tier');
      return null;
    }
    final elapsed = Stopwatch()..start();
    debugPrint(
      '[gaia] router: asking, rubric '
      '${rubric.trim().isEmpty ? 'default' : 'custom'}',
    );
    try {
      final answer = await _runner
          .generate(
            "Route the user's message in <input> to one of three model "
            'tiers.\n\n'
            '${rubric.trim().isEmpty ? kGaiaDefaultRouterRubric : rubric}'
            '${defaultTier == null ? '' : '\n\nIf unsure, choose ${defaultTier!.name}.'}'
            '\n\nReply with exactly one word: quick, standard or deep.',
            _clip(prompt, 4000),
          )
          .timeout(_routeTimeout);
      final tier = parseRoute(answer);
      debugPrint(
        '[gaia] router: answered "$answer" in ${elapsed.elapsedMilliseconds} '
        'ms -> ${tier?.name ?? 'no tier, using the default or last used one'}',
      );
      return tier;
    } catch (error) {
      debugPrint(
        '[gaia] router: failed after ${elapsed.elapsedMilliseconds} ms, '
        'using the default or last used tier: $error',
      );
      return null;
    }
  }

  /// A title for a chat from its first exchange, or null to keep the
  /// first-line one.
  Future<String?> title(String question, String reply) async {
    try {
      final answer = await _runner
          .generate(
            'Write a title of at most six words for a chat that starts '
                'with the exchange in <input>. Reply with the title only.',
            'User: ${_clip(question, 2000)}\n\n'
                'Assistant: ${_clip(reply, 2000)}',
          )
          .timeout(_titleTimeout);
      return cleanTitle(answer);
    } catch (error) {
      debugPrint('[gaia] title: $error');
      return null;
    }
  }

  /// A summary of [transcript] for an agent taking the chat over (§7.4),
  /// or null to leave the older turns out.
  Future<String?> summarize(String transcript) async {
    try {
      final answer = await _runner
          .generate(
            'Summarise the conversation in <input> in under 300 words for '
            'an assistant taking it over. Keep the facts, decisions and '
            'open questions; leave out pleasantries.',
            _clip(transcript, 200000),
          )
          .timeout(_summaryTimeout);
      return answer.trim().isEmpty ? null : answer.trim();
    } catch (error) {
      debugPrint('[gaia] summary: $error');
      return null;
    }
  }

  /// A description of [image] for an agent that can't see it (§7.4), or
  /// null to go without one.
  Future<String?> caption(GaiaImageInput image) async {
    try {
      final answer = await _runner
          .generate(
            'Describe the image in <input> in under 80 words for an '
            "assistant that can't see it. Copy out any text in it that "
            'matters, and say what any arrows, circles, highlights or other '
            'marks point at. Reply with the description only.',
            gaiaImageToken(image.label),
            images: [image],
          )
          .timeout(_captionTimeout);
      return answer.trim().isEmpty ? null : _clip(answer.trim(), 1000);
    } catch (error) {
      debugPrint('[gaia] caption: $error');
      return null;
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
