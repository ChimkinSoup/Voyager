import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_loading_toast.dart';
import 'package:voyager/features/leetcode/leetcode_search_popover.dart';

/// Opens the "track a problem" modal. When [prefill] is given, the form
/// starts populated with that API result (e.g. the user's most recently
/// accepted submission) but every field stays manually editable. When
/// [existing] is given, the modal edits that problem in place instead of
/// creating a new one.
Future<bool> showLeetCodeTrackModal(
  BuildContext context,
  WidgetRef ref, {
  LeetCodeApiQuestion? prefill,
  LeetCodeProblem? existing,
}) async {
  // Modal bottom sheets cap out at 640px wide by default (Material 3's
  // BottomSheetThemeData default), which reads as a narrow drawer on a
  // desktop-sized window. This form has a lot of fields plus a code editor,
  // so it gets almost the full screen instead.
  final screenSize = MediaQuery.sizeOf(context);
  final saved = await showVoyagerSheet<bool>(
    context: context,
    constraints: BoxConstraints(
      maxWidth: screenSize.width * 0.96,
      maxHeight: screenSize.height * 0.96,
    ),
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _TrackModal(prefill: prefill, existing: existing),
    ),
  );
  return saved ?? false;
}

class _TrackModal extends ConsumerStatefulWidget {
  const _TrackModal({this.prefill, this.existing});

  final LeetCodeApiQuestion? prefill;
  final LeetCodeProblem? existing;

  @override
  ConsumerState<_TrackModal> createState() => _TrackModalState();
}

class _TrackModalState extends ConsumerState<_TrackModal> {
  late final TextEditingController _titleController;
  final _titleFocusNode = FocusNode();
  String? _titleError;
  late final TextEditingController _questionFrontendIdController;
  late final TextEditingController _tagsController;
  late final TextEditingController _descriptionController;

  /// One controller per example, in display order. The "Example N" headings
  /// come from each controller's index, so removing one renumbers the rest.
  late final List<TextEditingController> _exampleControllers;

  /// One group of boxes per solution, in display order — numbered by position
  /// the same way the examples are, and unnumbered while there's only one.
  late final List<_SolutionEditors> _solutionEditors;
  late LeetCodeDifficulty _difficulty;
  String? _titleSlug;
  String? _questionId;
  bool _saving = false;
  bool _retracking = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final prefill = widget.prefill;

    _titleController = TextEditingController(
      text: existing?.title ?? prefill?.title ?? '',
    );
    _questionFrontendIdController = TextEditingController(
      text: existing?.questionFrontendId ?? prefill?.questionFrontendId ?? '',
    );
    _tagsController = TextEditingController(
      // Saved tags are already single tokens; only the API's are prose.
      text: existing != null
          ? existing.tags.map((t) => '#$t').join(' ')
          : _tagFieldText(prefill?.topicTags ?? const []),
    );
    _descriptionController = TextEditingController(
      text: existing?.description ?? prefill?.description ?? '',
    );
    _exampleControllers = [
      for (final example in existing?.examples ?? prefill?.examples ?? const [])
        TextEditingController(text: example),
    ];
    // An edit keeps whatever was saved; a fresh entry prefilled from the
    // user's last accepted submission starts on the language they solved it
    // in. Anything else — a language the selector doesn't offer, a search hit
    // that never came from a submission — falls back to the first option.
    final defaultLanguage =
        leetCodeLanguageKeyFor(prefill?.submissionLanguage) ??
        leetCodeCodeLanguages.first;
    // A problem with nothing written down still opens on one empty group, so
    // the fields are there to type into rather than behind an "Add solution".
    _solutionEditors = [
      for (final solution in existing?.solutions ?? const <LeetCodeSolution>[])
        _SolutionEditors.from(solution),
      if ((existing?.solutions ?? const []).isEmpty)
        _SolutionEditors.empty(language: defaultLanguage),
    ];
    _difficulty =
        existing?.difficulty ??
        prefill?.difficulty ??
        LeetCodeDifficulty.medium;
    _titleSlug = existing?.titleSlug ?? prefill?.titleSlug;
    _questionId = existing?.questionId ?? prefill?.questionId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _titleFocusNode.dispose();
    _questionFrontendIdController.dispose();
    _tagsController.dispose();
    _descriptionController.dispose();
    for (final controller in _exampleControllers) {
      controller.dispose();
    }
    for (final editors in _solutionEditors) {
      editors.dispose();
    }
    super.dispose();
  }

  /// The tags field's text for a set of LeetCode topic tags, whichever lookup
  /// they came from. Each topic becomes exactly one token — see
  /// [leetCodeTagToken] — so what [_parsedTags] reads back is one tag per topic
  /// rather than one per word of a topic's name.
  static String _tagFieldText(List<String> topicTags) =>
      topicTags.map((t) => '#${leetCodeTagToken(t)}').join(' ');

  List<String> get _parsedTags {
    final raw = _tagsController.text.split(RegExp(r'[\s,]+'));
    final seen = <String>{};
    for (final token in raw) {
      final tag = token.replaceAll('#', '').trim();
      if (tag.isNotEmpty) seen.add(tag);
    }
    return seen.toList();
  }

  /// Blank boxes are dropped rather than saved as empty examples — an "Add
  /// example" the user never filled in leaves nothing behind.
  List<String> get _parsedExamples => [
    for (final controller in _exampleControllers)
      if (controller.text.trim().isNotEmpty) controller.text.trim(),
  ];

  /// Blank groups are dropped rather than saved as empty solutions — the same
  /// rule the examples follow, which is also what keeps a problem the user
  /// only ever wrote a statement for from gaining a solution it doesn't have.
  List<LeetCodeSolution> get _parsedSolutions => _solutionEditors
      .map((editors) => editors.read())
      .where((solution) => !solution.isEmpty)
      .toList();

  void _addExample() {
    setState(() => _exampleControllers.add(TextEditingController()));
  }

  void _removeExample(int index) {
    setState(() => _exampleControllers.removeAt(index).dispose());
  }

  void _addSolution() {
    setState(
      () => _solutionEditors.add(
        // The new group starts on the language the one above it is in: a
        // second solution is usually the same language, and when it isn't,
        // the selector is right there.
        _SolutionEditors.empty(language: _solutionEditors.last.language),
      ),
    );
  }

  void _removeSolution(int index) {
    setState(() => _solutionEditors.removeAt(index).dispose());
  }

  Future<void> _openSearch(BuildContext buttonContext) async {
    final picked = await showLeetCodeSearchPopover(context, buttonContext, ref);
    if (picked == null || !mounted) return;
    // Search list hits omit body text; pull the full question so description
    // can auto-fill the same way title/difficulty already do.
    var detail = picked;
    if (picked.titleSlug.isNotEmpty) {
      try {
        detail = await ref
            .read(leetCodeApiClientProvider)
            .fetchBySlug(picked.titleSlug);
      } catch (_) {
        // Keep the search-list metadata if the follow-up fails.
      }
    }
    if (!mounted) return;
    setState(() {
      _titleController.text = detail.title;
      _questionFrontendIdController.text = detail.questionFrontendId;
      _tagsController.text = _tagFieldText(detail.topicTags);
      _difficulty = detail.difficulty;
      _titleSlug = detail.titleSlug;
      _questionId = detail.questionId.isEmpty
          ? picked.questionId
          : detail.questionId;
      if (detail.description != null) {
        _descriptionController.text = detail.description!;
      }
      if (detail.examples.isNotEmpty) {
        for (final controller in _exampleControllers) {
          controller.dispose();
        }
        _exampleControllers
          ..clear()
          ..addAll([
            for (final example in detail.examples)
              TextEditingController(text: example),
          ]);
      }
    });
  }

  /// Re-pulls this problem's metadata from LeetCode, overwriting only what the
  /// Track flow fills in for itself — name, ID, tags, difficulty, description,
  /// examples, and the language of any solution with no code in it yet.
  /// Everything the user wrote — algorithms, explanations, code, notes — and
  /// everything the deck tracks about their reviews is left untouched.
  ///
  /// Where the metadata comes from depends on which flow the modal is in. A new
  /// entry re-runs the Track button's own lookup, the user's latest accepted
  /// submission, because that's what filled the form the first time. An edit has
  /// no submission to go back to, so it looks the problem up by the name
  /// currently in the field instead — which is what makes retrack a way to
  /// repair a record whose name the user has just corrected, and why the name
  /// itself is the one field an edit's retrack leaves alone.
  Future<void> _retrack() async {
    if (_retracking || _saving) return;
    setState(() => _retracking = true);
    try {
      final detail = widget.existing == null
          ? await _fetchLatestSubmission()
          : await _fetchByTypedTitle();
      if (detail == null || !mounted) return;
      _applyRetrack(detail, overwriteTitle: widget.existing == null);
    } finally {
      if (mounted) setState(() => _retracking = false);
    }
  }

  Future<LeetCodeApiQuestion?> _fetchLatestSubmission() async {
    final username = ref.read(settingsProvider).value?.leetcodeUsername?.trim();
    if (username == null || username.isEmpty) {
      _reportRetrackFailure('Add your LeetCode username in Settings first');
      return null;
    }
    final dismissToast = showLeetCodeToast(
      context,
      message: 'Fetching your latest submission…',
    );
    try {
      final recent = await ref
          .read(leetCodeApiClientProvider)
          .fetchMostRecentAcceptedSubmission(username);
      dismissToast();
      if (recent == null) {
        _reportRetrackFailure('No accepted submissions found for $username');
      }
      return recent;
    } catch (_) {
      dismissToast();
      _reportRetrackFailure('Could not reach LeetCode');
      return null;
    }
  }

  Future<LeetCodeApiQuestion?> _fetchByTypedTitle() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = 'A problem name is required');
      _titleFocusNode.requestFocus();
      return null;
    }

    final dismissToast = showLeetCodeToast(
      context,
      message: 'Looking up "$title"…',
    );
    LeetCodeApiQuestion? hit;
    try {
      final client = ref.read(leetCodeApiClientProvider);
      final results = await client.searchByTitle(title, limit: 1);
      hit = results.isEmpty ? null : results.first;
      // Search-list hits carry no body text. Pulling the full question before
      // anything is overwritten is what keeps retrack from blanking the very
      // description and examples it was meant to refresh. A hit that already
      // has a statement came from the search's own slug fallback, which fetched
      // the full question itself — there's nothing left to ask for.
      if (hit != null && hit.description == null && hit.titleSlug.isNotEmpty) {
        hit = await client.fetchBySlug(hit.titleSlug);
      }
      dismissToast();
    } catch (_) {
      dismissToast();
      _reportRetrackFailure('Could not reach LeetCode');
      return null;
    }

    if (hit == null) {
      _reportRetrackFailure('No LeetCode problem matches "$title"');
      return null;
    }
    if (!mounted) return null;
    // Title search is fuzzy, and an edit keeps whatever name is in the field —
    // so a wrong top hit would quietly file another problem's ID, tags and
    // difficulty under this problem's name, with nothing on screen to say so.
    // A hit that isn't the name typed has to be confirmed by name first.
    if (hit.title.trim().toLowerCase() != title.toLowerCase()) {
      final confirmed = await showConfirmDialog(
        context,
        title: 'Use "${hit.title}"?',
        message:
            'LeetCode\'s closest match for "$title" is "${hit.title}". '
            'Retracking pulls that problem\'s ID, tags, difficulty, '
            'description and examples in, and leaves the name as you typed it.',
        confirmLabel: 'Retrack',
      );
      if (!confirmed || !mounted) return null;
    }
    return hit;
  }

  /// Overwrites the API-derived fields with [detail] and nothing else.
  ///
  /// [overwriteTitle] is false on an edit, where the name is the lookup key
  /// rather than a result of it.
  void _applyRetrack(
    LeetCodeApiQuestion detail, {
    required bool overwriteTitle,
  }) {
    final language = leetCodeLanguageKeyFor(detail.submissionLanguage);
    setState(() {
      if (overwriteTitle && detail.title.isNotEmpty) {
        _titleController.text = detail.title;
        _titleError = null;
      }
      _questionFrontendIdController.text = detail.questionFrontendId;
      _tagsController.text = _tagFieldText(detail.topicTags);
      _difficulty = detail.difficulty;
      if (detail.titleSlug.isNotEmpty) _titleSlug = detail.titleSlug;
      if (detail.questionId.isNotEmpty) _questionId = detail.questionId;
      // A null description means the lookup came back with no body text at all,
      // not that the problem ships none — so the statement and examples already
      // on screen are left standing rather than blanked. When there *is* body
      // text, the examples are replaced wholesale: they're one list, and
      // merging them against hand-edited boxes would duplicate rather than
      // refresh.
      if (detail.description != null) {
        _descriptionController.text = detail.description!;
        for (final controller in _exampleControllers) {
          controller.dispose();
        }
        _exampleControllers
          ..clear()
          ..addAll([
            for (final example in detail.examples)
              TextEditingController(text: example),
          ]);
      }
      if (language != null) {
        // Only the groups with nothing typed in them: the language a solution
        // was actually written in belongs to the user, not to the submission
        // this lookup happened to land on.
        for (final editors in _solutionEditors) {
          if (editors.code.text.trim().isEmpty) editors.language = language;
        }
      }
    });
  }

  /// Says why a retrack changed nothing, in the same toast the fetch itself
  /// used — a button that silently does nothing reads as a broken button.
  void _reportRetrackFailure(String message) {
    if (!mounted) return;
    final dismissToast = showLeetCodeToast(
      context,
      message: message,
      icon: PhosphorIconsRegular.warning,
    );
    Future.delayed(const Duration(milliseconds: 2600), dismissToast);
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _titleController.text.trim();
    // Save stays enabled so pressing it can say *why* nothing happened —
    // a greyed-out button on its own left the missing field unnamed.
    if (title.isEmpty) {
      setState(() => _titleError = 'A problem name is required');
      _titleFocusNode.requestFocus();
      return;
    }
    setState(() => _saving = true);

    final now = utcNow();
    final existing = widget.existing;
    final problem = LeetCodeProblem(
      id: existing?.id ?? newId(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      version: existing == null ? 0 : existing.version + 1,
      title: title,
      questionId: _questionId,
      questionFrontendId: _questionFrontendIdController.text.trim().isEmpty
          ? null
          : _questionFrontendIdController.text.trim(),
      titleSlug: _titleSlug,
      difficulty: _difficulty,
      tags: _parsedTags,
      description: _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
      examples: _parsedExamples,
      solutions: _parsedSolutions,
      solvedAt: existing?.solvedAt ?? now,
      interval: existing?.interval ?? 0,
      ease: existing?.ease ?? 2.5,
      dueAt: existing?.dueAt,
      reviewCount: existing?.reviewCount ?? 0,
    );

    final repo = ref.read(leetCodeRepositoryProvider);
    await repo.upsertProblem(problem);
    ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(problem);
    ref.invalidate(leetcodeProblemsProvider);

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final canSave = !_saving;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;

    return SizedBox(
      height: screenHeight * 0.94,
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets),
        // No reserved header strip — form scrolls to the sheet edge. Close
        // stays pinned as a light overlay so it never scrolls away and never
        // clips content behind a bar.
        child: Stack(
          children: [
            Positioned.fill(
              child: VoyagerScrollView(
                child: Padding(
                  // Top inset clears the overlaid close on first paint; once
                  // the user scrolls, content runs under it to the top edge.
                  padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: VoyagerTextField(
                              controller: _titleController,
                              focusNode: _titleFocusNode,
                              accentColor: accent,
                              onChanged: (_) {
                                if (_titleError != null) {
                                  setState(() => _titleError = null);
                                }
                              },
                              decoration: const InputDecoration(
                                labelText: 'Problem name',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: VoyagerTextField(
                              controller: _questionFrontendIdController,
                              accentColor: accent,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'ID',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Builder(
                            builder: (buttonContext) => IconButton(
                              onPressed: () => _openSearch(buttonContext),
                              icon: const Icon(
                                PhosphorIconsRegular.magnifyingGlass,
                                size: 20,
                              ),
                              tooltip: 'Search LeetCode',
                            ),
                          ),
                        ],
                      ),
                      if (_titleError != null) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _titleError!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              children: [
                                for (final d in LeetCodeDifficulty.values)
                                  SelectorPill(
                                    dense: true,
                                    label: labelForLeetCodeDifficulty(d),
                                    isActive: _difficulty == d,
                                    accentColor: colorForLeetCodeDifficulty(d),
                                    fillWhenActive: true,
                                    onTap: () =>
                                        setState(() => _difficulty = d),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          GlassButton(
                            dense: true,
                            label: 'Retrack',
                            icon: const Icon(
                              PhosphorIconsRegular.arrowClockwise,
                              size: 14,
                            ),
                            onPressed: _retracking ? null : _retrack,
                            tooltip: widget.existing == null
                                ? 'Refill from your latest LeetCode submission'
                                : 'Refill from LeetCode using this name',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      VoyagerTextField(
                        controller: _tagsController,
                        accentColor: accent,
                        tagScope: TagScope.leetcode,
                        decoration: const InputDecoration(
                          labelText: 'Tags',
                          hintText: '#array #hash-table',
                        ),
                      ),
                      const SizedBox(height: 16),
                      VoyagerTextField(
                        controller: _descriptionController,
                        accentColor: accent,
                        maxLines: 8,
                        minLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          hintText:
                              'Problem statement shown on the flashcard front',
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Text('Examples', style: theme.textTheme.labelLarge),
                          const Spacer(),
                          GlassButton(
                            dense: true,
                            label: 'Add example',
                            icon: const Icon(
                              PhosphorIconsRegular.plus,
                              size: 14,
                            ),
                            onPressed: _addExample,
                          ),
                        ],
                      ),
                      for (var i = 0; i < _exampleControllers.length; i++) ...[
                        const SizedBox(height: 10),
                        _ExampleField(
                          // Keyed on the controller, not the index, so removing an
                          // example moves each surviving field's state along with
                          // its text instead of leaving it on the shifted index.
                          key: ObjectKey(_exampleControllers[i]),
                          controller: _exampleControllers[i],
                          number: i + 1,
                          accentColor: accent,
                          onRemove: () => _removeExample(i),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Text('Solutions', style: theme.textTheme.labelLarge),
                          const Spacer(),
                          GlassButton(
                            dense: true,
                            label: 'Add solution',
                            icon: const Icon(
                              PhosphorIconsRegular.plus,
                              size: 14,
                            ),
                            onPressed: _addSolution,
                          ),
                        ],
                      ),
                      for (var i = 0; i < _solutionEditors.length; i++)
                        _SolutionFields(
                          // Keyed on the group rather than the index, so
                          // removing one carries each surviving group's field
                          // state along with its text — see [_ExampleField].
                          key: ObjectKey(_solutionEditors[i]),
                          editors: _solutionEditors[i],
                          accentColor: accent,
                          // A lone solution needs no name to tell it apart
                          // from the others, so it doesn't get one — and with
                          // no name there's nothing to remove it from either.
                          number: _solutionEditors.length > 1 ? i + 1 : null,
                          onRemove: () => _removeSolution(i),
                          onLanguageChanged: (lang) => setState(
                            () => _solutionEditors[i].language = lang,
                          ),
                        ),
                      const SizedBox(height: 24),
                      GlassButton(
                        onPressed: canSave ? _save : null,
                        label: widget.existing == null
                            ? 'Save'
                            : 'Save changes',
                        color: accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                onPressed: Navigator.of(context).pop,
                icon: const Icon(PhosphorIconsRegular.x, size: 18),
                visualDensity: VisualDensity.compact,
                tooltip: 'Close',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The controllers behind one solution's boxes, kept together so a group can
/// be added, removed, and disposed as a unit.
///
/// The chosen language lives here rather than in widget state: the code field
/// is rebuilt with the rest of the form, and a group that moved up the list
/// has to keep the language it was written in.
class _SolutionEditors {
  _SolutionEditors._({
    required this.algorithm,
    required this.timeComplexity,
    required this.spaceComplexity,
    required this.explanation,
    required this.code,
    required this.notes,
    required this.language,
  });

  factory _SolutionEditors.empty({required String language}) =>
      _SolutionEditors._(
        algorithm: TextEditingController(),
        timeComplexity: TextEditingController(),
        spaceComplexity: TextEditingController(),
        explanation: TextEditingController(),
        code: LeetCodeCodeController(text: ''),
        notes: TextEditingController(),
        language: language,
      );

  factory _SolutionEditors.from(LeetCodeSolution solution) =>
      _SolutionEditors._(
        algorithm: TextEditingController(text: solution.algorithm),
        timeComplexity: TextEditingController(
          text: solution.timeComplexity ?? '',
        ),
        spaceComplexity: TextEditingController(
          text: solution.spaceComplexity ?? '',
        ),
        explanation: TextEditingController(text: solution.explanation),
        code: LeetCodeCodeController(text: solution.code),
        notes: TextEditingController(text: solution.notes ?? ''),
        language: solution.codeLanguage,
      );

  final TextEditingController algorithm;
  final TextEditingController timeComplexity;
  final TextEditingController spaceComplexity;
  final TextEditingController explanation;
  final LeetCodeCodeController code;
  final TextEditingController notes;
  String language;

  LeetCodeSolution read() => LeetCodeSolution(
    algorithm: algorithm.text.trim(),
    timeComplexity: timeComplexity.text.trim().isEmpty
        ? null
        : timeComplexity.text.trim(),
    spaceComplexity: spaceComplexity.text.trim().isEmpty
        ? null
        : spaceComplexity.text.trim(),
    explanation: explanation.text.trim(),
    codeLanguage: language,
    code: code.text,
    notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
  );

  void dispose() {
    algorithm.dispose();
    timeComplexity.dispose();
    spaceComplexity.dispose();
    explanation.dispose();
    code.dispose();
    notes.dispose();
  }
}

/// One solution's boxes: approach, complexity pair, explanation, code, notes.
///
/// [number] is null while the problem has a single solution — there is nothing
/// to tell it apart from, so it gets neither a heading nor a remove button and
/// the form reads exactly as it did before problems could hold alternatives.
class _SolutionFields extends StatelessWidget {
  const _SolutionFields({
    super.key,
    required this.editors,
    required this.accentColor,
    required this.number,
    required this.onRemove,
    required this.onLanguageChanged,
  });

  final _SolutionEditors editors;
  final Color accentColor;
  final int? number;
  final VoidCallback onRemove;
  final ValueChanged<String> onLanguageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (number != null)
          Row(
            children: [
              Text(
                'Solution $number',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(PhosphorIconsRegular.trash, size: 16),
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove solution',
              ),
            ],
          )
        else
          const SizedBox(height: 10),
        VoyagerTextField(
          controller: editors.algorithm,
          accentColor: accentColor,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Algorithm',
            hintText: 'Core approach in a sentence or two',
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: VoyagerTextField(
                controller: editors.timeComplexity,
                accentColor: accentColor,
                decoration: const InputDecoration(
                  labelText: 'Time',
                  hintText: 'O(n)',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: VoyagerTextField(
                controller: editors.spaceComplexity,
                accentColor: accentColor,
                decoration: const InputDecoration(
                  labelText: 'Space',
                  hintText: 'O(1)',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        VoyagerTextField(
          controller: editors.explanation,
          accentColor: accentColor,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            labelText: 'Explanation',
            hintText: 'Walk through the logic in plain language',
          ),
        ),
        const SizedBox(height: 16),
        Text('Code', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        LeetCodeCodeInput(
          controller: editors.code,
          language: editors.language,
          onLanguageChanged: onLanguageChanged,
        ),
        const SizedBox(height: 16),
        VoyagerTextField(
          controller: editors.notes,
          accentColor: accentColor,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Notes',
            hintText: 'Anything to remember for next time',
          ),
        ),
      ],
    );
  }
}

/// One example's editor: an auto-numbered heading, a remove button, and a
/// plain multi-line box holding the Input/Output lines and the example's own
/// explanation together.
///
/// The box is fixed-pitch — not the syntax-highlighting code editor, just the
/// same face the detail view and flashcard render examples in, so what the
/// user types is laid out the way they'll later read it.
class _ExampleField extends StatelessWidget {
  const _ExampleField({
    super.key,
    required this.controller,
    required this.number,
    required this.accentColor,
    required this.onRemove,
  });

  final TextEditingController controller;
  final int number;
  final Color accentColor;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Example $number',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(PhosphorIconsRegular.trash, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Remove example',
            ),
          ],
        ),
        VoyagerTextField(
          controller: controller,
          accentColor: accentColor,
          maxLines: 8,
          minLines: 3,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: AppFonts.monoFamily,
          ),
          decoration: const InputDecoration(
            hintText: 'Input: nums = [2,7,11,15], target = 9\nOutput: [0,1]',
          ),
        ),
      ],
    );
  }
}
