import 'dart:async';

import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft_store.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_starter.dart';

/// Debounce before scratch reaches disk. The same 400 ms the Track draft uses —
/// long enough that ordinary typing writes once per pause, short enough that a
/// crash costs at most the last few characters.
const kLeetCodeScratchDebounce = Duration(milliseconds: 400);

/// Every scratch pad typed during one Study or Cram run.
///
/// Owned by the session page rather than a provider, the same way cram's
/// buckets are: this state is the run, and it goes when the run does. Nothing
/// here is a repository write — the problems it is keyed by never learn that a
/// pad existed.
///
/// The disk file is only ever a crash net. [start] takes the slot over the
/// moment a session opens and [end] deletes it, so a file still sitting there
/// when the next session opens means the last one died mid-run.
class LeetCodeScratchSessionController {
  LeetCodeScratchSessionController({
    required this.store,
    required this.problemIds,
  }) : sessionId = newId(),
       startedAt = DateTime.now().toUtc();

  final LeetCodeScratchDraftStore store;

  /// The problems this run opened over — carried into the file so a recovery
  /// offer can say which session it is about.
  final Set<String> problemIds;

  final String sessionId;
  final DateTime startedAt;

  final _scratches = <String, LeetCodeScratchEntry>{};

  /// One editor buffer per problem, kept here rather than in the pad widget so
  /// text survives the pad being expanded, collapsed, or scrolled out of the
  /// tree by an advance and an undo back.
  final _controllers = <String, LeetCodeCodeController>{};

  String? _lastLanguage;

  /// The language the pad is in, once the user has chosen one this session.
  /// Null until then, which is what makes the *first* pad take its language
  /// from the problem's own solution instead.
  String? get lastLanguage => _lastLanguage;

  LeetCodeScratchSession? _recoverable;

  /// Scratch from a run that never ended cleanly, held in memory until the
  /// user answers the recovery offer. Never left on disk: this session claimed
  /// the file at [start], so the orphan's only copy is this one.
  LeetCodeScratchSession? get recoverable => _recoverable;

  /// Bumped whenever the buffers are replaced wholesale rather than typed
  /// into — today only a recovery restore. The pad keys off it so the editor
  /// remounts on the restored text instead of going on showing the starter it
  /// was built with.
  int get generation => _generation;
  int _generation = 0;

  Timer? _debounce;
  bool _ended = false;

  /// Reads what the last run left behind, then takes the file over.
  ///
  /// Claiming it up front is deliberate: from here on the live session is what
  /// is protected against a crash, and the orphan is safe in memory either
  /// way. It also means a recovery offer the user ignores resolves to
  /// "discard", which is the right default — a fresh session never silently
  /// inherits yesterday's work.
  Future<LeetCodeScratchSession?> start() async {
    final previous = await store.load();
    if (_ended) return null;
    _recoverable = previous != null && previous.isOrphan ? previous : null;
    await _flush();
    return _recoverable;
  }

  /// Copies the orphan's pads into this session. Queue position is not
  /// replayed — only what was typed carries over.
  void restoreRecoverable() {
    final orphan = _recoverable;
    if (orphan == null) return;
    _scratches.addAll(orphan.scratches);
    _lastLanguage ??= orphan.lastLanguage;
    for (final entry in orphan.scratches.entries) {
      _controllerFor(entry.key, entry.value).fullText = entry.value.code;
    }
    _recoverable = null;
    _generation++;
    _scheduleFlush();
  }

  void discardRecoverable() => _recoverable = null;

  /// This problem's pad, created on its first visit in the session.
  ///
  /// Called from build: an entry that already exists — a revisit, an undo, a
  /// restored orphan — comes back untouched, so the starter is only ever
  /// derived once and can never overwrite what the user typed.
  LeetCodeScratchEntry entryFor(LeetCodeProblem problem) {
    final held = _scratches[problem.id];
    if (held != null) return held;

    final language =
        _lastLanguage ?? leetCodeFirstSolutionLanguage(problem) ?? 'python';
    final entry = LeetCodeScratchEntry(
      code: deriveLeetCodeStarter(problem, language),
      language: language,
    );
    _scratches[problem.id] = entry;
    _controllerFor(problem.id, entry);
    _scheduleFlush();
    return entry;
  }

  LeetCodeCodeController controllerFor(LeetCodeProblem problem) =>
      _controllerFor(problem.id, entryFor(problem));

  /// The buffer for [problemId], created on first use and highlighted in the
  /// entry's language.
  ///
  /// [CodeController] only tokenizes when it has been given a grammar, so a
  /// controller built without one paints the whole pad in the root colour —
  /// which is what the pad did before, while the Track modal's box (which sets
  /// the grammar in its own `initState`) highlighted normally.
  LeetCodeCodeController _controllerFor(
    String problemId,
    LeetCodeScratchEntry entry,
  ) => _controllers.putIfAbsent(
    problemId,
    () => LeetCodeCodeController(
      text: entry.code,
      language: leetCodeHighlightMode(entry.language),
    ),
  );

  /// Records what the pad now holds. [code] comes from the editor's own
  /// buffer, so this never writes back into the controller — that would fight
  /// the caret.
  void update(
    String problemId, {
    String? code,
    String? language,
    bool? expanded,
  }) {
    final held = _scratches[problemId];
    if (held == null) return;
    _scratches[problemId] = held.copyWith(
      code: code,
      language: language,
      expanded: expanded,
    );
    if (language != null) {
      _lastLanguage = language;
      // The pad re-tokenizes in the language it is now in. Assigned rather
      // than rebuilt: the buffer stays exactly as typed, only its grammar
      // changes.
      _controllers[problemId]?.language = leetCodeHighlightMode(language);
    }
    _scheduleFlush();
  }

  /// Resets the pad to the starter it opened on. Deterministic, so there is no
  /// "original" to keep around: the same problem and language derive the same
  /// skeleton every time.
  String clear(LeetCodeProblem problem) {
    final entry = entryFor(problem);
    final starter = deriveLeetCodeStarter(problem, entry.language);
    _controllerFor(problem.id, entry).fullText = starter;
    update(problem.id, code: starter);
    return starter;
  }

  /// Drops a problem that has been deleted out from under the session, so its
  /// pad stops being written to the recovery file.
  void retainOnly(Set<String> liveIds) {
    final gone = _scratches.keys.where((id) => !liveIds.contains(id)).toList();
    if (gone.isEmpty) return;
    for (final id in gone) {
      _scratches.remove(id);
      _controllers.remove(id)?.dispose();
    }
    _scheduleFlush();
  }

  /// The session ended the way it was meant to, so there is nothing to
  /// recover — the file goes. Chained behind any pending write, so a debounce
  /// that already fired cannot land after the delete and resurrect it.
  Future<void> end() async {
    if (_ended) return;
    _ended = true;
    _debounce?.cancel();
    _debounce = null;
    await store.clear();
  }

  void dispose() {
    _debounce?.cancel();
    _debounce = null;
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }

  void _scheduleFlush() {
    _debounce?.cancel();
    _debounce = Timer(kLeetCodeScratchDebounce, _flush);
  }

  Future<void> _flush() {
    _debounce?.cancel();
    _debounce = null;
    if (_ended) return Future<void>.value();
    return store.save(
      LeetCodeScratchSession(
        sessionId: sessionId,
        problemIds: problemIds,
        startedAt: startedAt,
        lastLanguage: _lastLanguage,
        scratches: Map.of(_scratches),
      ),
    );
  }

  /// Writes whatever is pending right now, ahead of the debounce. Used at the
  /// moments the user has visibly finished with a pad — closing the expanded
  /// editor, moving to the next problem.
  Future<void> flushNow() => _ended ? Future<void>.value() : _flush();
}
