import 'dart:async';
import 'dart:convert';

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
const _curateTimeout = Duration(seconds: 60);

/// A memory the curator found (§11).
typedef GaiaFoundMemory = ({String text, List<String> tags});

/// Gaia's small internal jobs on the utility model (GAIA_HLD.md §5.1): the
/// tier router, chat titles, handoff summaries and image captions, and the
/// memory curator (§11). Haiku on Claude Code, on the Claude account Gaia's
/// chats are on (§6.5).
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
      configDir: gaiaCurrentAccount(
        kGaiaClaudeCodeAdapter,
        gaiaAccountsFromJson(settings['accounts']),
        gaiaCurrentAccountsFromJson(settings['currentAccounts']),
        settings['claudeConfigDir'] as String? ?? '',
      ).dir,
    );
    autoRoute = settings['autoRoute'] != false;
    rubric = settings['routerRubric'] as String? ?? '';
    defaultTier = gaiaTierFromName(settings['defaultTier']);
  }

  /// A new chat is being written: the router will be asked soon, and memory
  /// recall too with [recall] (GAIA_MEMORY_TOPICS_HLD.md §4.3).
  void warm({bool recall = false}) {
    final count = (autoRoute ? 1 : 0) + (recall ? 1 : 0);
    if (count == 0) return;
    unawaited(
      _runner.warm(count).catchError((Object error) {
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
      final answer = await _runner.generate(
        "Route the user's message in <input> to one of three model "
        'tiers.\n\n'
        '${rubric.trim().isEmpty ? kGaiaDefaultRouterRubric : rubric}'
        '${defaultTier == null ? '' : '\n\nIf unsure, choose ${defaultTier!.name}.'}'
        '\n\nReply with exactly one word: quick, standard or deep.',
        _clip(prompt, 4000),
        timeout: _routeTimeout,
      );
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

  /// Stage 2 of memory recall (GAIA_MEMORY_TOPICS_HLD.md §4.3): which of
  /// stage 1's [candidates] fit [message], in the chat titled [title] if it
  /// has one. Null when it failed or timed out, so stage 1's picks go. It
  /// has the router's timeout: both hold up a message.
  Future<List<GaiaRecalledMemory>?> recall(
    String message,
    String? title,
    List<GaiaRecalledMemory> candidates,
  ) async {
    final elapsed = Stopwatch()..start();
    try {
      final answer = await _runner.generate(
        'Pick the memories about the user that an assistant answering '
            "the user's message should know. Pick only those that bear on "
            'this message, at most $kGaiaMaxRecalled, usually fewer, and '
            'none when none do.\n\n'
            'Reply with only a JSON array of the picked ids, [] for none.',
        '${title == null ? '' : 'Chat: ${_clip(title, 200)}\n\n'}'
            'Message:\n${_clip(message, 4000)}\n\n'
            'Memories (id · topic · text):\n'
            '${[for (final memory in candidates) '${memory.id} · ${memory.topic ?? 'Unsorted'} · ${_clip(memory.text, 1000)}'].join('\n')}',
        usage: 'memory recall',
        timeout: _routeTimeout,
      );
      final picks = parseRecallAnswer(answer, candidates);
      debugPrint(
        '[gaia] memory recall: picked ${picks.length} of '
        '${candidates.length} in ${elapsed.elapsedMilliseconds} ms',
      );
      return picks;
    } catch (error) {
      debugPrint(
        '[gaia] memory recall: failed after ${elapsed.elapsedMilliseconds} '
        'ms, using stage 1: $error',
      );
      return null;
    }
  }

  /// A title for a chat from its first exchange, or null to keep the
  /// first-line one.
  Future<String?> title(String question, String reply) async {
    try {
      final answer = await _runner.generate(
        'Write a title of at most six words for a chat that starts '
            'with the exchange in <input>. Reply with the title only.',
        'User: ${_clip(question, 2000)}\n\n'
            'Assistant: ${_clip(reply, 2000)}',
        timeout: _titleTimeout,
      );
      return cleanTitle(answer);
    } catch (error) {
      debugPrint('[gaia] title: $error');
      return null;
    }
  }

  /// A title for the chapter [message] starts (GAIA_CHAPTERS_HLD.md §4),
  /// from it and [partner], the other half of its turn; null to keep the
  /// first-line one.
  Future<String?> chapterTitle(
    GaiaMessage message,
    GaiaMessage? partner,
  ) async {
    String line(GaiaMessage m) =>
        '${m.role == GaiaMessageRole.user ? 'User' : 'Assistant'}: '
        '${_clip(m.text, 2000)}';
    final turn = [
      if (partner != null && partner.seq < message.seq) partner,
      message,
      if (partner != null && partner.seq > message.seq) partner,
    ];
    try {
      final answer = await _runner.generate(
        'Write a title of at most five words for the part of a '
        'conversation that starts with the exchange in <input>. '
        'Reply with the title only.',
        turn.map(line).join('\n\n'),
        timeout: _titleTimeout,
      );
      return cleanTitle(answer);
    } catch (error) {
      debugPrint('[gaia] chapter title: $error');
      return null;
    }
  }

  /// A summary of [transcript] for an agent taking the chat over (§7.4),
  /// or null to leave the older turns out.
  Future<String?> summarize(String transcript) async {
    try {
      final answer = await _runner.generate(
        'Summarise the conversation in <input> in under 300 words for '
        'an assistant taking it over. Keep the facts, decisions and '
        'open questions; leave out pleasantries.',
        _clip(transcript, 200000),
        timeout: _summaryTimeout,
      );
      return answer.trim().isEmpty ? null : answer.trim();
    } catch (error) {
      debugPrint('[gaia] summary: $error');
      return null;
    }
  }

  /// What a project chat is about, in a sentence or two, for the other chats
  /// in its project (GAIA_PROJECTS_HLD.md §5.5): [previous], its summary so
  /// far, brought up to date with [transcript], its turns since. Null when
  /// it failed, so the turns are read again next time.
  Future<String?> chatSummary(String? previous, String transcript) async {
    // The newest kept: the summary covers up to the last turn.
    final turns = transcript.length <= 100000
        ? transcript
        : transcript.substring(transcript.length - 100000);
    try {
      final answer = await _runner.generate(
        'Write one or two sentences, under 60 words, saying what the chat '
        'in <input> is about and where it stands, for an assistant '
        'deciding whether to read it. Reply with the summary only.',
        previous == null
            ? 'Chat:\n$turns'
            : 'Summary so far: $previous\n\nNew turns:\n$turns',
        timeout: _summaryTimeout,
      );
      final summary = answer.trim();
      return summary.isEmpty ? null : _clip(summary, 500);
    } catch (error) {
      debugPrint('[gaia] chat summary: $error');
      return null;
    }
  }

  /// A description of [image] for an agent that can't see it (§7.4), or
  /// null to go without one.
  Future<String?> caption(GaiaImageInput image) async {
    try {
      final answer = await _runner.generate(
        'Describe the image in <input> in under 80 words for an '
        "assistant that can't see it. Copy out any text in it that "
        'matters, and say what any arrows, circles, highlights or other '
        'marks point at. Reply with the description only.',
        gaiaImageToken(image.label),
        images: [image],
        timeout: _captionTimeout,
      );
      return answer.trim().isEmpty ? null : _clip(answer.trim(), 1000);
    } catch (error) {
      debugPrint('[gaia] caption: $error');
      return null;
    }
  }

  /// At most three memories worth keeping from a chat's new turns in
  /// [transcript], none of them in [index], the memories already kept
  /// (§11); null when it failed, so the turns are read again next time.
  Future<List<GaiaFoundMemory>?> curate(String transcript, String index) async {
    try {
      final answer = await _runner.generate(
        'You keep a short list of lasting facts about the user for '
            'their assistant, Gaia. Read the new turns of a chat in <input> '
            'and pick at most 3 facts about the user worth remembering in '
            'future, unrelated chats: lasting preferences, people, places '
            'and projects in their life, decisions they made, how they like '
            'to work. Leave out anything that only matters to this chat, '
            'anything only the assistant said, anything already among the '
            'memories kept, and secrets such as passwords or account '
            'numbers. Usually there is nothing worth keeping.\n\n'
            'Reply with only a JSON array, [] for nothing: each item '
            '{"text": "...", "tags": ["..."]}, the text one fact in one '
            'sentence under 200 characters that makes sense on its own, '
            'in the first person as the user would put it ("I prefer '
            'metric units", "My sister lives in Lisbon"), the tags one or '
            'two one-word topics.',
        'Memories kept:\n${index.trim().isEmpty ? '(none)' : index}\n\n'
            // The newest kept: the chat is marked read up to its last.
            'New turns:\n${transcript.length <= 100000 ? transcript : transcript.substring(transcript.length - 100000)}',
        timeout: _curateTimeout,
      );
      return parseCuratorAnswer(answer);
    } catch (error) {
      debugPrint('[gaia] curator: $error');
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

/// The memories in a curator [answer]: its JSON array, wherever it is in
/// the text, at most three. Throws a [FormatException] when there's none.
@visibleForTesting
List<GaiaFoundMemory> parseCuratorAnswer(String answer) {
  final start = answer.indexOf('[');
  final end = answer.lastIndexOf(']');
  if (start < 0 || end < start) {
    throw FormatException('no JSON array', answer);
  }
  final list = jsonDecode(answer.substring(start, end + 1));
  if (list is! List) throw FormatException('not a JSON array', answer);
  return [
    for (final item in list)
      if (item case {'text': final String text} when text.trim().isNotEmpty)
        (
          text: text.trim(),
          tags: [
            if (item['tags'] case final List tags)
              for (final tag in tags)
                if (tag is String) tag,
          ],
        ),
  ].take(3).toList();
}

/// The [candidates] a recall [answer] picks (GAIA_MEMORY_TOPICS_HLD.md
/// §4.3): its JSON array of ids, wherever it is in the text, in its order,
/// unknown and repeated ids dropped, within the caps of §4.4. Throws a
/// [FormatException] when there's no array.
@visibleForTesting
List<GaiaRecalledMemory> parseRecallAnswer(
  String answer,
  List<GaiaRecalledMemory> candidates,
) {
  final start = answer.indexOf('[');
  final end = answer.lastIndexOf(']');
  if (start < 0 || end < start) {
    throw FormatException('no JSON array', answer);
  }
  final list = jsonDecode(answer.substring(start, end + 1));
  if (list is! List) throw FormatException('not a JSON array', answer);
  final byId = {for (final memory in candidates) memory.id: memory};
  final picks = <GaiaRecalledMemory>[];
  var length = 0;
  for (final id in list) {
    if (picks.length == kGaiaMaxRecalled) break;
    final memory = byId.remove(id);
    if (memory == null) continue;
    final size = memory.text.trim().length;
    if (length + size > kGaiaMaxRecalledLength) continue;
    length += size;
    picks.add(memory);
  }
  return picks;
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
