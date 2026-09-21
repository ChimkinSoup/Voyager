import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_draft.dart';
import 'package:voyager/features/leetcode/leetcode_scratch_starter.dart';

/// Every scratch pad typed during one Study or Cram run.
///
/// Owned by the session page rather than a provider, the same way cram's
/// buckets are: this state is the run, and it goes when the run does. Nothing
/// here is a repository write — the problems it is keyed by never learn that a
/// pad existed.
///
/// Reaching disk is the session checkpoint's job. Every change calls
/// [onChanged], and what to write is read back off [snapshot]: an unfinished
/// run keeps its pads, and only a finish or a Start over throws them away.
class LeetCodeScratchSessionController {
  LeetCodeScratchSessionController({required this.onChanged});

  /// Told that there is something new to write down.
  final void Function() onChanged;

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

  /// Bumped whenever the buffers are replaced wholesale rather than typed
  /// into — a resumed session, or a Start over. The pad keys off it so the
  /// editor remounts on the new text instead of going on showing the starter
  /// it was built with.
  int get generation => _generation;
  int _generation = 0;

  /// What the checkpoint writes down.
  LeetCodeScratchSession snapshot() => LeetCodeScratchSession(
    lastLanguage: _lastLanguage,
    scratches: Map.of(_scratches),
  );

  /// Takes the pads of the run being resumed. Queue position is the
  /// checkpoint's to restore; this is only what was typed.
  void restore(LeetCodeScratchSession blob) {
    _scratches.addAll(blob.scratches);
    _lastLanguage ??= blob.lastLanguage;
    for (final entry in blob.scratches.entries) {
      _controllerFor(entry.key, entry.value).fullText = entry.value.code;
    }
    _generation++;
  }

  /// Drops everything typed, for a Start over: the run it belonged to is not
  /// one the user is coming back to.
  void reset() {
    _scratches.clear();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _lastLanguage = null;
    _generation++;
    onChanged();
  }

  /// This problem's pad, created on its first visit in the session.
  ///
  /// Called from build: an entry that already exists — a revisit, an undo, a
  /// resumed run — comes back untouched, so the starter is only ever derived
  /// once and can never overwrite what the user typed.
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
    onChanged();
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
    onChanged();
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
  /// pad stops being written to the checkpoint.
  void retainOnly(Set<String> liveIds) {
    final gone = _scratches.keys.where((id) => !liveIds.contains(id)).toList();
    if (gone.isEmpty) return;
    for (final id in gone) {
      _scratches.remove(id);
      _controllers.remove(id)?.dispose();
    }
    onChanged();
  }

  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }
}
