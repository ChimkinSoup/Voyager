import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
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
import 'package:voyager/features/leetcode/leetcode_track_draft.dart';
import 'package:voyager/features/leetcode/leetcode_track_draft_store.dart';

/// What the Track flow found in the local draft slot, and so what the modal
/// has to say about it on arrival. Decided by the caller, which is the only
/// place that knows both the draft and the question the lookup returned.
enum LeetCodeTrackDraftOutcome {
  /// No draft, or nothing worth mentioning — the modal opens silently.
  none,

  /// The draft is for the question that was just looked up, and the form was
  /// built from it. Offers to throw it away and start over.
  resumed,

  /// A draft exists for some other question; the form was built from the fresh
  /// lookup instead. Offers to switch to the draft.
  mismatch,

  /// The lookup couldn't answer, so the draft was opened in its place.
  resumedAfterFetchFailure,
}

/// Opens the "track a problem" modal. When [prefill] is given, the form
/// starts populated with that API result (e.g. the user's most recently
/// accepted submission) but every field stays manually editable. When
/// [existing] is given, the modal edits that problem in place instead of
/// creating a new one.
///
/// [draft] is the locally saved, never-synced create form from a previous
/// visit. Depending on [draftOutcome] the modal either opens *as* that draft
/// or keeps it aside to offer. An edit ignores both outright: a draft belongs
/// to the create flow only, and must never read or write the slot from here.
Future<bool> showLeetCodeTrackModal(
  BuildContext context,
  WidgetRef ref, {
  LeetCodeApiQuestion? prefill,
  LeetCodeProblem? existing,
  LeetCodeTrackDraft? draft,
  LeetCodeTrackDraftOutcome draftOutcome = LeetCodeTrackDraftOutcome.none,
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
      child: _TrackModal(
        prefill: prefill,
        existing: existing,
        // An edit never carries a draft, whatever the caller passed.
        draft: existing == null ? draft : null,
        draftOutcome: existing == null
            ? draftOutcome
            : LeetCodeTrackDraftOutcome.none,
      ),
    ),
  );
  return saved ?? false;
}

class _TrackModal extends ConsumerStatefulWidget {
  const _TrackModal({
    this.prefill,
    this.existing,
    this.draft,
    this.draftOutcome = LeetCodeTrackDraftOutcome.none,
  });

  final LeetCodeApiQuestion? prefill;
  final LeetCodeProblem? existing;
  final LeetCodeTrackDraft? draft;
  final LeetCodeTrackDraftOutcome draftOutcome;

  @override
  ConsumerState<_TrackModal> createState() => _TrackModalState();
}

class _TrackModalState extends ConsumerState<_TrackModal> {
  /// Long enough that a burst of typing writes once, short enough that a
  /// window closed straight after a keystroke has already been captured.
  static const _draftDebounce = Duration(milliseconds: 400);

  /// Draft toasts carry an offer, so they sit a little longer than the
  /// 2.6s failure toasts — and hovering holds them open indefinitely.
  static const _draftToastDwell = Duration(milliseconds: 4200);

  late TextEditingController _titleController;
  final _titleFocusNode = FocusNode();
  String? _titleError;
  late TextEditingController _questionFrontendIdController;
  late TextEditingController _tagsController;
  late TextEditingController _descriptionController;

  /// One controller per example, in display order. The "Example N" headings
  /// come from each controller's index, so removing one renumbers the rest.
  final List<TextEditingController> _exampleControllers = [];

  /// One group of boxes per solution, in display order — numbered by position
  /// the same way the examples are, and unnumbered while there's only one.
  final List<_SolutionEditors> _solutionEditors = [];
  late LeetCodeDifficulty _difficulty;
  String? _titleSlug;

  /// The name that was in the title field when [_titleSlug] was adopted.
  ///
  /// A slug says which LeetCode question this record *is*, so it only keeps
  /// saying that while the name it arrived with is the name being saved.
  /// Renaming the entry to a different problem leaves the old slug describing
  /// somebody else's question — see [_effectiveTitleSlug].
  String? _slugTitle;
  String? _questionId;
  bool _saving = false;
  bool _retracking = false;

  late final LeetCodeTrackDraftStore _draftStore;
  late final Future<void> Function() _lifecycleFlushCallback;

  /// The form as it stood once this open had finished populating. Everything
  /// the draft slot does is decided by comparing against this.
  late LeetCodeTrackDraft _baseline;

  /// Set once the form has diverged from [_baseline], and never unset for this
  /// populate: after the first divergence there is nothing left to compare
  /// for, so typing costs a timer reset and no snapshot at all.
  bool _started = false;

  /// What is on disk, so an autosave that would rewrite the same bytes doesn't.
  LeetCodeTrackDraft? _lastWritten;

  /// Stops touching the slot for good — set when a successful save has already
  /// cleared it, so the close flush can't put it back.
  bool _draftClosed = false;

  /// The draft the flow found but didn't open, kept for "Continue with draft".
  LeetCodeTrackDraft? _draftOffer;

  Timer? _draftTimer;
  VoidCallback? _dismissDraftToast;

  bool get _isCreate => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    final opensAsDraft =
        draft != null &&
        (widget.draftOutcome == LeetCodeTrackDraftOutcome.resumed ||
            widget.draftOutcome ==
                LeetCodeTrackDraftOutcome.resumedAfterFetchFailure);
    if (opensAsDraft) {
      _populateFromDraft(draft);
      _lastWritten = draft;
    } else {
      _draftOffer = draft;
      _populateFromForm(existing: widget.existing, prefill: widget.prefill);
      if (draft != null) _lastWritten = draft;
    }

    if (_isCreate) {
      _draftStore = ref.read(leetCodeTrackDraftStoreProvider);
      _lifecycleFlushCallback = _flushDraft;
      PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
      _attachDraftListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showDraftToast(widget.draftOutcome);
      });
    }
    _baseline = _snapshot();
  }

  /// Builds every editor from a saved problem, an API result, or neither.
  void _populateFromForm({
    LeetCodeProblem? existing,
    LeetCodeApiQuestion? prefill,
  }) {
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
    _exampleControllers.addAll([
      for (final example in existing?.examples ?? prefill?.examples ?? const [])
        TextEditingController(text: example),
    ]);
    // An edit keeps whatever was saved; a fresh entry prefilled from the
    // user's last accepted submission starts on the language they solved it
    // in. Anything else — a language the selector doesn't offer, a search hit
    // that never came from a submission — falls back to the first option.
    final defaultLanguage =
        leetCodeLanguageKeyFor(prefill?.submissionLanguage) ??
        leetCodeCodeLanguages.first;
    // A problem with nothing written down still opens on one empty group, so
    // the fields are there to type into rather than behind an "Add solution".
    _solutionEditors.addAll([
      for (final solution in existing?.solutions ?? const <LeetCodeSolution>[])
        _SolutionEditors.from(solution),
      if ((existing?.solutions ?? const []).isEmpty)
        _SolutionEditors.empty(language: defaultLanguage),
    ]);
    _difficulty =
        existing?.difficulty ??
        prefill?.difficulty ??
        LeetCodeDifficulty.medium;
    if (existing?.titleSlug != null) {
      _titleSlug = existing!.titleSlug;
      _slugTitle = existing.title;
    } else if (prefill?.titleSlug != null) {
      _titleSlug = prefill!.titleSlug;
      _slugTitle = prefill.title;
    }
    _questionId = existing?.questionId ?? prefill?.questionId;
  }

  /// Rebuilds the form the draft was taken from, field for field and row for
  /// row — blank boxes the user had added included, since those are part of
  /// the form they left behind.
  void _populateFromDraft(LeetCodeTrackDraft draft) {
    _titleController = TextEditingController(text: draft.title);
    _questionFrontendIdController = TextEditingController(
      text: draft.questionFrontendId,
    );
    _tagsController = TextEditingController(text: draft.tags);
    _descriptionController = TextEditingController(text: draft.description);
    _exampleControllers.addAll([
      for (final example in draft.examples) TextEditingController(text: example),
    ]);
    _solutionEditors.addAll([
      for (final solution in draft.solutions) _SolutionEditors.fromDraft(solution),
      if (draft.solutions.isEmpty)
        _SolutionEditors.empty(language: leetCodeCodeLanguages.first),
    ]);
    _difficulty = draft.difficulty;
    _titleSlug = draft.titleSlug;
    _slugTitle = draft.title;
    _questionId = draft.questionId;
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (_isCreate) {
      PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
      // Reads the controllers synchronously and hands the finished snapshot
      // to an async write, so the disposal below can't race it.
      unawaited(_flushDraft());
    }
    _dismissDraftToast?.call();
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

  // ───────────────────────── local draft ─────────────────────────
  //
  // Create-mode only, device-only. Nothing here ever reaches the problems
  // table, the outbox, or `remoteSyncService` — the slot holds one unsaved
  // form so closing the sheet by accident doesn't cost the user their typing.

  Iterable<TextEditingController> get _draftControllers sync* {
    yield _titleController;
    yield _questionFrontendIdController;
    yield _tagsController;
    yield _descriptionController;
    yield* _exampleControllers;
    for (final editors in _solutionEditors) {
      yield* editors.controllers;
    }
  }

  void _attachDraftListeners() {
    for (final controller in _draftControllers) {
      controller.addListener(_handleDraftEdit);
    }
  }

  /// Every keystroke lands here, so it does as little as possible: cancel a
  /// timer, start a timer. Snapshotting and comparing wait for the debounce.
  void _handleDraftEdit() {
    if (!_isCreate || _draftClosed) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(_draftDebounce, () => unawaited(_flushDraft()));
  }

  /// The slug to file with this record, or null once the name has moved off
  /// the question the slug came from.
  ///
  /// Identity is decided by the stored slug when there is one, so a lookup's
  /// slug left behind on a renamed entry would file it as the same question as
  /// whatever else carries that slug — a new problem typed over a prefilled
  /// name would read as a duplicate of the problem it was prefilled from.
  /// Dropping it falls identity back to the name the user actually typed.
  String? get _effectiveTitleSlug {
    final slug = _titleSlug;
    if (slug == null || slug.isEmpty) return null;
    final source = _slugTitle;
    if (source == null) return null;
    return source.trim().toLowerCase() ==
            _titleController.text.trim().toLowerCase()
        ? slug
        : null;
  }

  /// The whole form as it stands, ready to persist or to compare.
  LeetCodeTrackDraft _snapshot() => LeetCodeTrackDraft(
    title: _titleController.text,
    questionFrontendId: _questionFrontendIdController.text,
    tags: _tagsController.text,
    description: _descriptionController.text,
    examples: [for (final c in _exampleControllers) c.text],
    difficulty: _difficulty,
    titleSlug: _effectiveTitleSlug,
    questionId: _questionId,
    solutions: [for (final e in _solutionEditors) e.readDraft()],
    savedAt: utcNow(),
  );

  /// Writes, clears, or leaves the one slot alone, whichever the current form
  /// calls for. Runs on the debounce, on close, and on app termination.
  Future<void> _flushDraft() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    if (!_isCreate || _draftClosed) return;

    final snapshot = _snapshot();
    if (!_started) {
      // Opened and closed untouched: whatever is in the slot stays there.
      if (snapshot.sameContentAs(_baseline)) return;
      _started = true;
    }
    // Blank rows, a difficulty pill and a language selector are not work worth
    // keeping. A form with no text left in it clears the slot instead.
    if (!snapshot.hasText) {
      if (_lastWritten == null) return;
      _lastWritten = null;
      await _draftStore.clear();
      return;
    }
    if (_lastWritten != null && snapshot.sameContentAs(_lastWritten!)) return;
    _lastWritten = snapshot;
    await _draftStore.save(snapshot);
  }

  /// Re-snapshots the baseline after a search or retrack has written API
  /// metadata over the form. What the user typed is still there, so the
  /// question "has anything changed" restarts from the merged state — but an
  /// apply that changed anything counts as having started the form.
  void _rebaselineAfterApply() {
    if (!_isCreate) return;
    final snapshot = _snapshot();
    if (!_started && !snapshot.sameContentAs(_baseline)) _started = true;
    _baseline = snapshot;
    if (_started) _handleDraftEdit();
  }

  /// Throws the form away and rebuilds it from [draft], or from [prefill] (or
  /// empty). Every editor is replaced rather than reassigned: the code boxes
  /// reconstruct an assigned value from a diff, which mangles a wholesale
  /// replacement — see [LeetCodeCodeController].
  void _replaceContents({
    LeetCodeTrackDraft? draft,
    LeetCodeApiQuestion? prefill,
  }) {
    setState(() {
      for (final controller in _draftControllers) {
        controller.removeListener(_handleDraftEdit);
      }
      _titleController.dispose();
      _questionFrontendIdController.dispose();
      _tagsController.dispose();
      _descriptionController.dispose();
      for (final controller in _exampleControllers) {
        controller.dispose();
      }
      for (final editors in _solutionEditors) {
        editors.dispose();
      }
      _exampleControllers.clear();
      _solutionEditors.clear();
      _titleError = null;

      if (draft != null) {
        _populateFromDraft(draft);
      } else {
        _populateFromForm(prefill: prefill);
      }
      _attachDraftListeners();
      _baseline = _snapshot();
      _started = false;
    });
  }

  void _showDraftToast(LeetCodeTrackDraftOutcome outcome) {
    _dismissDraftToast?.call();
    _dismissDraftToast = null;
    switch (outcome) {
      case LeetCodeTrackDraftOutcome.none:
        return;
      case LeetCodeTrackDraftOutcome.resumed:
        _dismissDraftToast = showLeetCodeToast(
          context,
          message: 'Picked up your draft',
          icon: PhosphorIconsRegular.arrowCounterClockwise,
          dwell: _draftToastDwell,
          actions: [
            LeetCodeToastAction(
              label: 'Clear draft',
              onPressed: () => unawaited(_clearDraftAndStartNew()),
            ),
          ],
        );
      case LeetCodeTrackDraftOutcome.resumedAfterFetchFailure:
        _dismissDraftToast = showLeetCodeToast(
          context,
          message: "Couldn't refresh — showing your draft",
          icon: PhosphorIconsRegular.warning,
          dwell: _draftToastDwell,
          actions: [
            LeetCodeToastAction(
              label: 'Clear draft',
              onPressed: () => unawaited(_clearDraftAndStartNew()),
            ),
          ],
        );
      case LeetCodeTrackDraftOutcome.mismatch:
        final offer = _draftOffer;
        if (offer == null) return;
        final name = offer.title.trim();
        _dismissDraftToast = showLeetCodeToast(
          context,
          message: name.isEmpty
              ? 'Unsaved draft available'
              : 'Draft saved for "$name"',
          icon: PhosphorIconsRegular.pencilSimple,
          dwell: _draftToastDwell,
          actions: [
            LeetCodeToastAction(
              label: 'Continue with draft',
              onPressed: () => _continueWithDraft(offer),
            ),
          ],
        );
    }
  }

  /// Swaps the fresh form out for the draft the flow set aside. The slot is
  /// left exactly as it is — this is opening what's already saved, not saving.
  void _continueWithDraft(LeetCodeTrackDraft draft) {
    if (!mounted) return;
    _draftOffer = null;
    _lastWritten = draft;
    _replaceContents(draft: draft);
    _showDraftToast(LeetCodeTrackDraftOutcome.resumed);
  }

  /// Drops the draft and refills the form from a fresh lookup — the same one
  /// the Track button ran, so a failure leaves an empty form and says why.
  Future<void> _clearDraftAndStartNew() async {
    if (!_isCreate || _retracking || _saving) return;
    _draftTimer?.cancel();
    // The lookup below is async, but these controllers stay mounted and
    // visible until _replaceContents swaps them out. Detaching now, rather
    // than after the await, is what stops a keystroke landing in that window
    // from re-autosaving the very draft this just cleared.
    for (final controller in _draftControllers) {
      controller.removeListener(_handleDraftEdit);
    }
    _draftOffer = null;
    _lastWritten = null;
    _started = false;
    await _draftStore.clear();
    if (!mounted) return;
    setState(() => _retracking = true);
    try {
      final detail = await _fetchLatestSubmission();
      if (!mounted) return;
      _replaceContents(prefill: detail);
    } finally {
      if (mounted) setState(() => _retracking = false);
    }
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

  /// A new row is a change to the form even while its boxes are still blank,
  /// so every one of these marks the draft dirty as well as rebuilding.
  void _addExample() {
    setState(() => _exampleControllers.add(_newExampleController()));
    _handleDraftEdit();
  }

  void _removeExample(int index) {
    setState(() => _exampleControllers.removeAt(index).dispose());
    _handleDraftEdit();
  }

  void _addSolution() {
    setState(() {
      // The new group starts on the language the one above it is in: a
      // second solution is usually the same language, and when it isn't,
      // the selector is right there.
      final editors = _SolutionEditors.empty(
        language: _solutionEditors.last.language,
      );
      _solutionEditors.add(editors);
      _attachSolutionListeners(editors);
    });
    _handleDraftEdit();
  }

  void _removeSolution(int index) {
    setState(() => _solutionEditors.removeAt(index).dispose());
    _handleDraftEdit();
  }

  void _moveSolution(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _solutionEditors.length) return;
    setState(() {
      final editors = _solutionEditors.removeAt(index);
      _solutionEditors.insert(target, editors);
    });
    _handleDraftEdit();
  }

  /// An example box that feeds the draft from the moment it exists.
  TextEditingController _newExampleController([String text = '']) {
    final controller = TextEditingController(text: text);
    if (_isCreate) controller.addListener(_handleDraftEdit);
    return controller;
  }

  void _attachSolutionListeners(_SolutionEditors editors) {
    if (!_isCreate) return;
    for (final controller in editors.controllers) {
      controller.addListener(_handleDraftEdit);
    }
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
      _slugTitle = _titleController.text;
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
              _newExampleController(example),
          ]);
      }
    });
    _rebaselineAfterApply();
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
      // On an edit the name stays as typed and the lookup was made *by* it,
      // so the slug belongs to that name rather than to the hit's own.
      if (detail.titleSlug.isNotEmpty) {
        _titleSlug = detail.titleSlug;
        _slugTitle = _titleController.text;
      }
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
              _newExampleController(example),
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
    _rebaselineAfterApply();
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
    final repo = ref.read(leetCodeRepositoryProvider);

    // Whatever the row holds *now*, not what it held when the sheet opened. A
    // sync tick can land another device's grade underneath an open modal, and
    // the write below sets every column — so rebasing onto the live row is
    // what stops the save from rolling that grade back (and from writing a
    // version number that goes backwards, which the next pull would then
    // resolve *against* this very edit).
    final captured = widget.existing;
    LeetCodeProblem? existing = captured;
    if (captured != null) {
      try {
        // A row that has since been purged outright leaves `captured` as the
        // only base there is, which is also what a failed read falls back to.
        existing = await repo.getProblem(captured.id) ?? captured;
      } catch (_) {
        existing = captured;
      }
      if (!mounted) return;
    }

    final problem = LeetCodeProblem(
      id: existing?.id ?? newId(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      version: existing == null ? 0 : existing.version + 1,
      // Omitting this resurrected a problem tombstoned while the sheet was
      // open, since the upsert writes the column either way.
      deletedAt: existing?.deletedAt,
      title: title,
      questionId: _questionId,
      questionFrontendId: _questionFrontendIdController.text.trim().isEmpty
          ? null
          : _questionFrontendIdController.text.trim(),
      titleSlug: _effectiveTitleSlug,
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

    try {
      await repo.upsertProblem(problem);
    } catch (_) {
      // The latch has to come off here or the Save button is dead for the life
      // of the sheet — and in edit mode there is no draft, so closing it would
      // be the only way out and would take the changes with it.
      if (mounted) setState(() => _saving = false);
      _reportRetrackFailure("Couldn't save — your changes are still here");
      return;
    }
    ref.read(remoteSyncServiceProvider).pushLeetCodeProblem(problem);
    ref.invalidate(leetcodeProblemsProvider);

    // The work is filed; there is nothing left to recover. Closing the slot
    // before the pop is what stops the dispose flush from writing it back.
    // Only reached once the write has landed: clearing the draft on a failed
    // save would discard the one remaining copy of the work.
    if (_isCreate) {
      _draftClosed = true;
      _draftTimer?.cancel();
      unawaited(_draftStore.clear());
    }

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
                                    onTap: () {
                                      setState(() => _difficulty = d);
                                      _handleDraftEdit();
                                    },
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
                      for (var i = 0; i < _solutionEditors.length; i++) ...[
                        const SizedBox(height: 12),
                        _SolutionFields(
                          // Keyed on the group rather than the index, so
                          // removing or reordering one carries each surviving
                          // group's field state along with its text — see
                          // [_ExampleField].
                          key: ObjectKey(_solutionEditors[i]),
                          editors: _solutionEditors[i],
                          accentColor: accent,
                          // A lone solution needs no name to tell it apart
                          // from the others, so it doesn't get one — and with
                          // no name there's nothing to remove or reorder it
                          // from either.
                          number: _solutionEditors.length > 1 ? i + 1 : null,
                          canMoveUp: i > 0,
                          canMoveDown: i < _solutionEditors.length - 1,
                          onMoveUp: () => _moveSolution(i, -1),
                          onMoveDown: () => _moveSolution(i, 1),
                          onRemove: () => _removeSolution(i),
                          onLanguageChanged: (lang) {
                            setState(() => _solutionEditors[i].language = lang);
                            _handleDraftEdit();
                          },
                        ),
                      ],
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

  factory _SolutionEditors.fromDraft(LeetCodeTrackDraftSolution solution) =>
      _SolutionEditors._(
        algorithm: TextEditingController(text: solution.algorithm),
        timeComplexity: TextEditingController(text: solution.timeComplexity),
        spaceComplexity: TextEditingController(text: solution.spaceComplexity),
        explanation: TextEditingController(text: solution.explanation),
        code: LeetCodeCodeController(text: solution.code),
        notes: TextEditingController(text: solution.notes),
        language: solution.codeLanguage,
      );

  final TextEditingController algorithm;
  final TextEditingController timeComplexity;
  final TextEditingController spaceComplexity;
  final TextEditingController explanation;
  final LeetCodeCodeController code;
  final TextEditingController notes;
  String language;

  /// Every box in the group, for anything that has to watch the lot of them.
  Iterable<TextEditingController> get controllers => [
    algorithm,
    timeComplexity,
    spaceComplexity,
    explanation,
    code,
    notes,
  ];

  /// The group exactly as typed — untrimmed, blanks kept. What a saved
  /// solution drops, a draft has to restore.
  LeetCodeTrackDraftSolution readDraft() => LeetCodeTrackDraftSolution(
    algorithm: algorithm.text,
    timeComplexity: timeComplexity.text,
    spaceComplexity: spaceComplexity.text,
    explanation: explanation.text,
    codeLanguage: language,
    code: code.text,
    notes: notes.text,
  );

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
/// to tell it apart from, so it gets neither a heading nor move/remove buttons
/// and the form reads exactly as it did before problems could hold alternatives.
class _SolutionFields extends StatelessWidget {
  const _SolutionFields({
    super.key,
    required this.editors,
    required this.accentColor,
    required this.number,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
    required this.onLanguageChanged,
  });

  final _SolutionEditors editors;
  final Color accentColor;
  final int? number;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onRemove;
  final ValueChanged<String> onLanguageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(
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
                onPressed: canMoveUp ? onMoveUp : null,
                icon: const Icon(PhosphorIconsRegular.arrowUp, size: 16),
                visualDensity: VisualDensity.compact,
                tooltip: 'Move solution up',
              ),
              IconButton(
                onPressed: canMoveDown ? onMoveDown : null,
                icon: const Icon(PhosphorIconsRegular.arrowDown, size: 16),
                visualDensity: VisualDensity.compact,
                tooltip: 'Move solution down',
              ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(PhosphorIconsRegular.trash, size: 16),
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove solution',
              ),
            ],
          ),
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

    // A lone solution is already unambiguous, so it stays on the modal's own
    // background. Once there are several, each gets a panel behind all of its
    // boxes — alternating between two tints, so however many there are, no two
    // touching groups share one and the seam between them is visible without
    // having to read the headings. Editor-only: the flashcard and detail views
    // build their own solution layout and are untouched by this.
    if (number == null) return body;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(
          alpha: number!.isOdd ? 0.03 : 0.06,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: body,
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
