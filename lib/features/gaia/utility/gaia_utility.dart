import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart'
    show GaiaSweepLine, GaiaSweepTopic;
import 'package:voyager/features/gaia/utility/claude_utility_runner.dart';

/// How long the router may hold up a new chat's first message before the
/// last used tier takes it (§7.2). Haiku answers in about a second from a
/// process started ahead ([warm]); a cold start took 2.6–4.2 s.
const _routeTimeout = Duration(seconds: 5);
const _titleTimeout = Duration(seconds: 15);
const _summaryTimeout = Duration(seconds: 30);
const _captionTimeout = Duration(seconds: 30);
const _curateTimeout = Duration(seconds: 60);
const _placeTimeout = Duration(seconds: 30);
const _sortTimeout = Duration(seconds: 90);

/// What the placement and curator jobs say about the topics.
const _placementRules =
    'Pick the existing topics it belongs in, at most 3, usually 1, or none '
    'when none fits. Only when none fits well, offer one new topic, with a '
    'short name, under the existing topic it would belong in or at the '
    'root (parent null).';

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
    final account = gaiaCurrentAccount(
      kGaiaClaudeCodeAdapter,
      gaiaAccountsFromJson(settings['accounts']),
      gaiaCurrentAccountsFromJson(settings['currentAccounts']),
      settings['claudeConfigDir'] as String? ?? '',
    );
    _runner.configure(
      model: model.isEmpty ? kGaiaDefaultUtilityModel : model,
      configDir: account.dir,
      account: account.key,
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
        source: 'routing',
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
        source: 'memory recall',
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

  /// A title for a chat from its first exchange, or from its first message
  /// alone without [reply]; null to keep the first-line one.
  Future<String?> title(String question, [String? reply]) async {
    try {
      final answer = await _runner.generate(
        'Write a title of at most six words for a chat that starts '
            'with the ${reply == null ? 'message' : 'exchange'} in <input>. '
            'Reply with the title only.',
        'User: ${_clip(question, 2000)}'
            '${reply == null ? '' : '\n\nAssistant: ${_clip(reply, 2000)}'}',
        timeout: _titleTimeout,
        source: 'chat title',
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
        source: 'chapter title',
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
        source: 'handoff summary',
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
        source: 'chat summary',
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
        source: 'image caption',
      );
      return answer.trim().isEmpty ? null : _clip(answer.trim(), 1000);
    } catch (error) {
      debugPrint('[gaia] caption: $error');
      return null;
    }
  }

  /// Where memory [text] is filed (GAIA_MEMORY_TOPICS_HLD.md §5): which of
  /// [topics] it goes in, a new topic if none fits, and tags to match it by.
  /// Null when it failed, so it stays where it is.
  Future<GaiaPlacement?> place(String text, List<GaiaTopicLine> topics) async {
    try {
      final answer = await _runner.generate(
        'File a fact about the user, kept by their assistant Gaia, under '
            'the topics listed in <input>. $_placementRules Also give up to '
            '3 tags: one-word keywords someone might use when this fact '
            "matters that aren't among its own words (for \"Biscuit's "
            'vaccine booster is due in May": vet, shots).\n\n'
            'Reply with only a JSON object: {"topics": ["<id>"], "new": null '
            'or {"name": "...", "parent": "<id>" or null}, "tags": ["..."]}.',
        'Fact: ${_clip(text, 1000)}\n\n${_topicLines(topics)}',
        timeout: _placeTimeout,
        source: 'memory filing',
      );
      final placement = parsePlacementAnswer(answer, topics);
      debugPrint(
        '[gaia] memory placement: ${placement.topicIds.length} topics'
        '${placement.suggested == null ? '' : ', new "${placement.suggested!.name}"'}',
      );
      return placement;
    } catch (error) {
      debugPrint('[gaia] memory placement: $error');
      return null;
    }
  }

  /// Where each of [memories] is filed, for the Gaia page's Sort these
  /// (GAIA_MEMORY_TOPICS_HLD.md §6): one call for the batch, at most
  /// [kGaiaSortBatch]. By memory id, only those the answer places; null when
  /// it failed. Nothing is applied: the user accepts each.
  Future<Map<String, GaiaPlacement>?> placeMany(
    List<({String id, String text})> memories,
    List<GaiaTopicLine> topics, {
    String? usage,
  }) async {
    final elapsed = Stopwatch()..start();
    try {
      final answer = await _runner.generate(
        'File each fact about the user in <input>, kept by their assistant '
            'Gaia, under the topics listed. For each fact: $_placementRules '
            'Offer the same new topic, with the same name, for facts that '
            'belong together. Leave a fact with no topics and no new topic when '
            "it doesn't belong in any group, such as a one-off detail. "
            'Also give up to 3 tags: one-word keywords '
            "someone might use when the fact matters that aren't among its "
            'own words.\n\n'
            'Reply with only a JSON array, one item per fact: {"n": <its '
            'number>, "topics": ["<id>"], "new": null or {"name": "...", '
            '"parent": "<id>" or null}, "tags": ["..."]}.',
        'Facts:\n'
            '${[for (final (i, memory) in memories.indexed) '${i + 1}. ${_clip(memory.text.replaceAll(RegExp(r'\s+'), ' ').trim(), 1000)}'].join('\n')}'
            '\n\n${_topicLines(topics)}',
        usage: usage,
        timeout: _sortTimeout,
        source: 'memory filing',
      );
      final placements = parseSortAnswer(answer, memories, topics);
      debugPrint(
        '[gaia] memory sort: placed ${placements.length} of '
        '${memories.length} in ${elapsed.elapsedMilliseconds} ms',
      );
      return placements;
    } catch (error) {
      debugPrint(
        '[gaia] memory sort: failed after ${elapsed.elapsedMilliseconds} ms: '
        '$error',
      );
      return null;
    }
  }

  /// At most three memories worth keeping from a chat's new turns in
  /// [transcript], none of them among [kept], the memories kept, in the
  /// inbox or set aside that are nearest to it (§11), each filed in [topics]
  /// (GAIA_MEMORY_TOPICS_HLD.md §5); null when it failed, so the turns are
  /// read again next time. [keptIds] are the ids of [kept]'s numbered
  /// lines, in order: one a fact updates is named by its number (§27.3).
  Future<List<GaiaFoundMemory>?> curate(
    String transcript,
    String kept,
    List<GaiaTopicLine> topics, [
    List<String> keptIds = const [],
  ]) async {
    try {
      final answer = await _runner.generate(
        'You keep a short list of lasting facts about the user for '
            'their assistant, Gaia. Read the new turns of a chat in <input> '
            'and pick at most 3 facts about the user worth remembering in '
            'future, unrelated chats: lasting preferences, people, places '
            'and projects in their life, decisions they made, how they like '
            'to work. Leave out anything that only matters to this chat, '
            'anything only the assistant said, anything already among the '
            'memories listed, however worded, and secrets such as '
            'passwords or account numbers. Usually there is nothing worth '
            'keeping.\n\n'
            'Reply with only a JSON array, [] for nothing: each item '
            '{"text": "...", "tags": ["..."]}, the text one fact in one '
            'sentence under 200 characters that makes sense on its own, '
            'in the first person as the user would put it ("I prefer '
            'metric units", "My sister lives in Lisbon"), the tags one or '
            'two one-word topics.\n\n'
            'File each under the topics listed. $_placementRules Give them '
            'as "topics": ["<id>"] and "new": null or {"name": "...", '
            '"parent": "<id>" or null} in its item. Add "pin": true to an '
            'item only when the fact is about the user in general rather '
            'than one subject: who they are, or how they like answers given '
            '("I\'m a CS student at Waterloo", "I prefer short answers").\n\n'
            'The memories kept are numbered. When a fact corrects or updates '
            'one of them, so both can\'t be true at once (the user moved, or '
            'changed their mind), add "replaces": <its number> to its item, '
            'still giving the fact in full. Not when it only adds detail.',
        'Memories kept (numbered), then those waiting for the user to '
            'approve or set aside by the user (-), that may overlap:\n'
            '${kept.trim().isEmpty ? '(none)' : kept}\n\n'
            '${_topicLines(topics)}\n\n'
            // The newest kept: the chat is marked read up to its last.
            'New turns:\n${transcript.length <= 100000 ? transcript : transcript.substring(transcript.length - 100000)}',
        timeout: _curateTimeout,
        source: 'memory curation',
      );
      return parseCuratorAnswer(answer, topics, keptIds);
    } catch (error) {
      debugPrint('[gaia] curator: $error');
      return null;
    }
  }

  /// The save check for new memory [text] (GAIA_MEMORY_TOPICS_HLD.md
  /// §27.3): whether one of [near], the kept memories nearest it, says it
  /// already or is corrected by it, and, given [topics], where it's filed,
  /// so it needs no second call. Null when it failed or timed out (the
  /// router's 5 seconds): it's saved as it would be with no check.
  Future<GaiaSaveCheck?> check(
    String text,
    List<({String id, String text})> near, {
    List<GaiaTopicLine>? topics,
  }) async {
    final elapsed = Stopwatch()..start();
    try {
      final answer = await _runner.generate(
        'A new fact about the user is about to be saved among the memories '
            'their assistant, Gaia, keeps. Compare it with the saved '
            'memories in <input>, numbered. Answer "same" with the number of '
            'one that already says it, however worded; "replaces" with the '
            "number of one it corrects or updates, so both can't be true at "
            'once (the user moved, or changed their mind), not one it only '
            'adds detail to; otherwise "new".'
            '${topics == null ? '' : '\n\nAlso file the new fact under the topics listed. $_placementRules Also give up to 3 tags: one-word keywords someone might use when it matters that aren\'t among its own words.'}'
            '\n\nReply with only a JSON object: {"check": "new", "same" or '
            '"replaces", "n": <its number, or null for new>'
            '${topics == null ? '' : ', "topics": ["<id>"], "new": null or {"name": "...", "parent": "<id>" or null}, "tags": ["..."]'}}.',
        'New fact: ${_clip(text, 1000)}\n\n'
            'Saved memories:\n'
            '${[for (final (i, memory) in near.indexed) '${i + 1}. ${_clip(memory.text.replaceAll(RegExp(r'\s+'), ' ').trim(), 1000)}'].join('\n')}'
            '${topics == null ? '' : '\n\n${_topicLines(topics)}'}',
        usage: 'memory save check',
        timeout: _routeTimeout,
        source: 'memory save check',
      );
      final check = parseSaveCheck(answer, near, topics);
      final said = check.sameId != null
          ? 'same'
          : check.replacesId != null
          ? 'replaces'
          : 'new';
      debugPrint(
        '[gaia] memory save check: $said of ${near.length} in '
        '${elapsed.elapsedMilliseconds} ms',
      );
      return check;
    } catch (error) {
      debugPrint(
        '[gaia] memory save check: failed after '
        '${elapsed.elapsedMilliseconds} ms, saving as it is: $error',
      );
      return null;
    }
  }

  /// One call of the weekly sweep (GAIA_MEMORY_TOPICS_HLD.md §27.4): what
  /// [lines], a group of memories, hold that says one thing, disagrees or
  /// has expired by [today], and with [topics], topics to merge or rename.
  /// Null when it failed or timed out.
  Future<List<GaiaSweepFound>?> sweep(
    List<GaiaSweepLine> lines,
    DateTime today, {
    List<GaiaSweepTopic>? topics,
  }) async {
    final elapsed = Stopwatch()..start();
    String day(DateTime at) => at.toLocal().toIso8601String().substring(0, 10);
    try {
      final answer = await _runner.generate(
        "You tidy the memories a user's assistant, Gaia, keeps about them. "
        'Today is ${day(today)}. The memories in <input> are numbered, each '
        'with its topics and the day it was saved. Find only clear '
        'cases of:\n'
        '- "same": two or more memories that say one thing, however '
        'worded. Give one text that says it all, every detail kept, in '
        'the first person as the user would put it.\n'
        '- "conflict": two memories that can\'t both be true (the user '
        'moved, or changed their mind). Not two true things about '
        'different subjects.\n'
        '- "expired": a memory about a time that has passed, read '
        'against the day it was saved ("My exam is next week" saved '
        'months ago). Not one that still holds a day to come, and not '
        'a habit that repeats ("every November").\n'
        '${topics == null ? '' : '- "topicMerge": two topics that mean the same thing; "into" is the one to keep.\n- "topicRename": a topic named unlike its siblings ("cs246" beside "CS245 Course"), with the name it should have, without its parents. Never a topic marked (project).\n'}'
        'Most memories are fine, so usually there is little or nothing to '
        'suggest. Memories that look alike but are about different '
        'things are not the same.\n\n'
        'Reply with only a JSON array, [] for nothing. Items: '
        '{"kind": "same", "n": [<numbers>], "text": "...", "why": "..."}, '
        '{"kind": "conflict", "n": [<a>, <b>], "why": "..."}, '
        '{"kind": "expired", "n": <number>, "why": "..."}'
        '${topics == null ? '' : ', {"kind": "topicMerge", "from": "T<n>", "into": "T<n>", "why": "..."}, {"kind": "topicRename", "topic": "T<n>", "name": "...", "why": "..."}'}'
        '. Each why is one short line that names memories and topics by '
        'what they say, never by their numbers.',
        [
          if (lines.isNotEmpty) ...[
            'Memories:',
            for (final (i, line) in lines.indexed)
              '${i + 1}. ${_clip(line.text.replaceAll(RegExp(r'\s+'), ' ').trim(), 1000)}'
                  ' · topics: ${line.topics.isEmpty ? 'Unsorted' : line.topics.join('; ')}'
                  ' · saved ${day(line.saved)}${line.pinned ? ' · pinned' : ''}',
          ],
          if (topics != null) ...[
            if (lines.isNotEmpty) '',
            'Topics:',
            if (topics.isEmpty) '(none)',
            for (final (i, topic) in topics.indexed)
              'T${i + 1}. ${topic.path} (${topic.count})'
                  '${topic.project ? ' (project)' : ''}',
          ],
        ].join('\n'),
        usage: 'memory sweep',
        timeout: _curateTimeout,
        source: 'memory sweep',
      );
      final found = parseSweepAnswer(
        answer,
        [for (final line in lines) line.id],
        [for (final topic in topics ?? const <GaiaSweepTopic>[]) topic.id],
      );
      debugPrint(
        '[gaia] memory sweep: ${found.length} found in ${lines.length} lines'
        '${topics == null ? '' : ' and ${topics.length} topics'} in '
        '${elapsed.elapsedMilliseconds} ms',
      );
      return found;
    } catch (error) {
      debugPrint(
        '[gaia] memory sweep: a call failed after '
        '${elapsed.elapsedMilliseconds} ms: $error',
      );
      return null;
    }
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : text.substring(0, max);

  static String _topicLines(List<GaiaTopicLine> topics) =>
      'Topics (id · path):\n${topics.isEmpty ? '(none yet)' : [for (final topic in topics) '${topic.id} · ${topic.path}'].join('\n')}';
}

/// What one sweep call found (GAIA_MEMORY_TOPICS_HLD.md §27.4): its kind,
/// the memories and topics it names (a merge's from then into), the merged
/// text or new name, and why.
typedef GaiaSweepFound = ({
  GaiaSuggestionKind kind,
  List<String> memoryIds,
  List<String> topicIds,
  String? text,
  String? why,
});

/// The suggestions in a sweep [answer]: its JSON array, wherever it is in
/// the text, each naming memories by number from 1 ([memoryIds]) and topics
/// as "T" and a number ([topicIds]). One with a number out of range, or
/// the wrong count of them (same takes two or more, conflict two, expired
/// one), is dropped. Throws a [FormatException] when there's no array.
@visibleForTesting
List<GaiaSweepFound> parseSweepAnswer(
  String answer,
  List<String> memoryIds,
  List<String> topicIds,
) {
  final start = answer.indexOf('[');
  final end = answer.lastIndexOf(']');
  if (start < 0 || end < start) {
    throw FormatException('no JSON array', answer);
  }
  final list = jsonDecode(answer.substring(start, end + 1));
  if (list is! List) throw FormatException('not a JSON array', answer);
  String? topic(Object? n) => switch (n) {
    final String n when n.trim().toUpperCase().startsWith('T') => _numbered(
      n.trim().substring(1),
      topicIds,
    ),
    _ => _numbered(n, topicIds),
  };
  final found = <GaiaSweepFound>[];
  for (final item in list) {
    if (item is! Map) continue;
    final kind = GaiaSuggestionKind.values
        .where((kind) => kind.name == item['kind'])
        .firstOrNull;
    final numbers = switch (item['n']) {
      final List n => n,
      final Object n => [n],
      null => const [],
    };
    final memories = [
      ...{for (final n in numbers) ?_numbered(n, memoryIds)},
    ];
    final whole = memories.length == numbers.length;
    String? said(Object? text) => switch (text) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => null,
    };
    final why = said(item['why']);
    // A new name given as a path ("School › CS341 Course") keeps its last part.
    final name = said(item['name'])?.split('›').last.trim();
    final GaiaSweepFound? made = switch (kind) {
      GaiaSuggestionKind.same
          when whole && memories.length >= 2 && said(item['text']) != null =>
        (
          kind: kind!,
          memoryIds: memories,
          topicIds: const [],
          text: said(item['text']),
          why: why,
        ),
      GaiaSuggestionKind.conflict when whole && memories.length == 2 => (
        kind: kind!,
        memoryIds: memories,
        topicIds: const [],
        text: null,
        why: why,
      ),
      GaiaSuggestionKind.expired when whole && memories.length == 1 => (
        kind: kind!,
        memoryIds: memories,
        topicIds: const [],
        text: null,
        why: why,
      ),
      GaiaSuggestionKind.topicMerge
          when topic(item['from']) != null &&
              topic(item['into']) != null &&
              topic(item['from']) != topic(item['into']) =>
        (
          kind: kind!,
          memoryIds: const [],
          topicIds: [topic(item['from'])!, topic(item['into'])!],
          text: null,
          why: why,
        ),
      GaiaSuggestionKind.topicRename
          when topic(item['topic']) != null &&
              name != null &&
              name.isNotEmpty =>
        (
          kind: kind!,
          memoryIds: const [],
          topicIds: [topic(item['topic'])!],
          text: name,
          why: why,
        ),
      _ => null,
    };
    if (made != null) found.add(made);
  }
  return found;
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

/// What the save check found (GAIA_MEMORY_TOPICS_HLD.md §27.3): the
/// memory that says it already, or the one it updates, neither for a new
/// one, and where it's filed when that was asked.
typedef GaiaSaveCheck = ({
  String? sameId,
  String? replacesId,
  GaiaPlacement? placement,
});

/// The memories in a curator [answer]: its JSON array, wherever it is in
/// the text, at most three, each filed in those of [topics] it names, and
/// updating the one of [keptIds] its `replaces` numbers (from 1), if any.
/// Throws a [FormatException] when there's none.
@visibleForTesting
List<GaiaFoundMemory> parseCuratorAnswer(
  String answer, [
  List<GaiaTopicLine> topics = const [],
  List<String> keptIds = const [],
]) {
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
        if (_placementOf(item, topics) case final placement)
          (
            text: text.trim(),
            tags: [
              if (item['tags'] case final List tags)
                for (final tag in tags)
                  if (tag is String) tag,
            ],
            topicIds: placement.topicIds,
            suggested: placement.suggested,
            pin: item['pin'] == true,
            replacesId: _numbered(item['replaces'], keptIds),
          ),
  ].take(3).toList();
}

/// What a save check [answer] says of a new memory and [near]
/// (GAIA_MEMORY_TOPICS_HLD.md §27.3): its JSON object, wherever it is in
/// the text. A number missing or out of range reads as new. Filed in
/// [topics] when they're given. Throws a [FormatException] when there's no
/// object.
@visibleForTesting
GaiaSaveCheck parseSaveCheck(
  String answer,
  List<({String id, String text})> near, [
  List<GaiaTopicLine>? topics,
]) {
  final start = answer.indexOf('{');
  final end = answer.lastIndexOf('}');
  if (start < 0 || end < start) {
    throw FormatException('no JSON object', answer);
  }
  final json = jsonDecode(answer.substring(start, end + 1));
  if (json is! Map) throw FormatException('not a JSON object', answer);
  final id = _numbered(json['n'], [for (final memory in near) memory.id]);
  return (
    sameId: json['check'] == 'same' ? id : null,
    replacesId: json['check'] == 'replaces' ? id : null,
    placement: topics == null ? null : _placementOf(json, topics),
  );
}

/// The one of [ids] that [n] numbers, from 1; null for none.
String? _numbered(Object? n, List<String> ids) {
  final i = switch (n) {
    final int n => n,
    final String n => int.tryParse(n.trim()),
    _ => null,
  };
  return i == null || i < 1 || i > ids.length ? null : ids[i - 1];
}

/// Where a placement [answer] files a memory (GAIA_MEMORY_TOPICS_HLD.md
/// §5): its JSON object, wherever it is in the text. Throws a
/// [FormatException] when there's none.
@visibleForTesting
GaiaPlacement parsePlacementAnswer(String answer, List<GaiaTopicLine> topics) {
  final start = answer.indexOf('{');
  final end = answer.lastIndexOf('}');
  if (start < 0 || end < start) {
    throw FormatException('no JSON object', answer);
  }
  final json = jsonDecode(answer.substring(start, end + 1));
  if (json is! Map) throw FormatException('not a JSON object', answer);
  return _placementOf(json, topics);
}

/// The topics and new topic [json] names, only those of [topics] it
/// knows, at most 3; its tags too.
GaiaPlacement _placementOf(
  Map<Object?, Object?> json,
  List<GaiaTopicLine> topics,
) {
  final known = {for (final topic in topics) topic.id};
  final suggested = switch (json['new']) {
    {'name': final String name} when name.trim().isNotEmpty => (
      name: name.trim().length <= 60
          ? name.trim()
          : name.trim().substring(0, 60).trim(),
      parentId: switch (json['new']) {
        {'parent': final String parent} when known.contains(parent) => parent,
        _ => null,
      },
    ),
    _ => null,
  };
  return (
    topicIds: [
      ...{
        if (json['topics'] case final List ids)
          for (final id in ids)
            if (id is String && known.contains(id)) id,
      },
    ].take(3).toList(),
    suggested: suggested,
    tags: gaiaMemoryTags(json['tags']).take(3).toList(),
  );
}

/// Where a Sort these [answer] files each of [memories]
/// (GAIA_MEMORY_TOPICS_HLD.md §6): its JSON array, wherever it is in the
/// text, each item naming a fact by its number from 1. By memory id; a
/// number out of range or repeated is dropped, as is an item that places
/// nothing. Throws a [FormatException] when there's no array.
@visibleForTesting
Map<String, GaiaPlacement> parseSortAnswer(
  String answer,
  List<({String id, String text})> memories,
  List<GaiaTopicLine> topics,
) {
  final start = answer.indexOf('[');
  final end = answer.lastIndexOf(']');
  if (start < 0 || end < start) {
    throw FormatException('no JSON array', answer);
  }
  final list = jsonDecode(answer.substring(start, end + 1));
  if (list is! List) throw FormatException('not a JSON array', answer);
  final placements = <String, GaiaPlacement>{};
  for (final item in list) {
    if (item is! Map) continue;
    final n = switch (item['n']) {
      final int n => n,
      final String n => int.tryParse(n),
      _ => null,
    };
    if (n == null || n < 1 || n > memories.length) continue;
    final id = memories[n - 1].id;
    if (placements.containsKey(id)) continue;
    final placement = _placementOf(item, topics);
    if (placement.topicIds.isEmpty && placement.suggested == null) continue;
    placements[id] = placement;
  }
  return placements;
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
