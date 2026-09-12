import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/job_constants.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_actions.dart';
import 'package:voyager/features/jobs/job_clipboard_parser.dart';
import 'package:voyager/features/jobs/jobs_company_field.dart';
import 'package:voyager/features/jobs/jobs_option_list.dart';
import 'package:voyager/features/jobs/jobs_track_draft.dart';
import 'package:voyager/features/jobs/jobs_track_draft_store.dart';

/// Opens the "track an application" form and returns what it created, or null
/// if the user closed it without saving.
///
/// Nothing is written until Save: company, title, stage, date, season, URL and
/// notes are all collected on one page first. [draft] is the locally saved,
/// never-synced form from a previous visit — when non-null the form opens *as*
/// that draft, with the option to throw it away and start over.
///
/// A floating window rather than a bottom sheet. A sheet is pinned to the
/// bottom edge and sized by the constraints it is given, so a form shorter
/// than that left a band of empty surface below Save with nothing to put in
/// it. Centred and shrink-wrapped, the surface ends where the form ends.
Future<JobApplication?> showJobsTrackModal(
  BuildContext context,
  WidgetRef ref, {
  JobsTrackDraft? draft,
}) async {
  final screenSize = MediaQuery.sizeOf(context);
  return showVoyagerDialog<JobApplication>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              // Wide enough to read as a page rather than a drawer, capped so
              // the fields do not stretch across a large monitor. The height
              // is a ceiling only: the form scrolls once it needs to, and
              // stops short of it when it does not.
              constraints: BoxConstraints(
                maxWidth: screenSize.width < 720 ? screenSize.width : 640,
                maxHeight: screenSize.height * 0.9,
              ),
              child: GlassSurface(
                weight: GlassWeight.heavy,
                borderRadius: BorderRadius.circular(20),
                // A bottom sheet brings its own Material; showGeneralDialog
                // does not, and the form is full of widgets that need one.
                child: Material(
                  type: MaterialType.transparency,
                  child: _TrackModal(draft: draft),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Held across the draft read below and released the moment the form goes up —
/// from there the dialog's own barrier covers the button. Without it a second
/// press landing in the read's gap opened a second form over the first, and
/// both were reading and writing the one draft slot, so whichever closed last
/// overwrote the other.
bool _trackFlowInFlight = false;

/// Loads the draft slot, then opens the form on it. The one entry point the
/// Add button uses.
Future<JobApplication?> startJobsTrackFlow(
  BuildContext context,
  WidgetRef ref,
) async {
  if (_trackFlowInFlight) return null;
  _trackFlowInFlight = true;
  final JobsTrackDraft? draft;
  try {
    draft = await ref.read(jobsTrackDraftStoreProvider).load();
  } finally {
    // Nothing awaits between here and the push below, so the button is never
    // live and unguarded: the form is up in the same turn of the event loop.
    _trackFlowInFlight = false;
  }
  if (!context.mounted) return null;
  return showJobsTrackModal(context, ref, draft: draft);
}

/// The two boxes clipboard sniff and smart paste may write.
enum _PasteTarget { title, url }

class _TrackModal extends ConsumerStatefulWidget {
  const _TrackModal({this.draft});

  final JobsTrackDraft? draft;

  @override
  ConsumerState<_TrackModal> createState() => _TrackModalState();
}

class _TrackModalState extends ConsumerState<_TrackModal> {
  /// Long enough that a burst of typing writes once, short enough that a
  /// window closed straight after a keystroke has already been captured.
  static const _draftDebounce = Duration(milliseconds: 400);

  final _companyController = TextEditingController();
  final _titleController = TextEditingController();
  final _urlController = TextEditingController();
  final _notesController = TextEditingController();
  final _companyFocusNode = FocusNode();
  final _titleFocusNode = FocusNode();
  final _urlFocusNode = FocusNode();
  final _notesFocusNode = FocusNode();

  String _status = '';
  List<String> _seasonIds = const [];
  DateTime? _dateApplied;
  String? _companyError;
  String? _titleError;
  bool _saving = false;

  /// True while the form is showing a draft it picked up, so the banner
  /// offering to discard it stays up until the user acts or types past it.
  bool _resumedDraft = false;

  /// What the clipboard put in the Title and URL boxes and the user has not
  /// touched since — null for a field this feature never wrote, or wrote and
  /// has since been edited past (JOBS_SMART_PASTE_HLD.md §7.3).
  ///
  /// Both the "From clipboard" chip and what dismissing it clears are read off
  /// these two: a value the user has typed over is theirs, not the
  /// clipboard's, and dismissing must never take it away.
  String? _clipboardTitle;
  String? _clipboardUrl;

  bool get _filledFromClipboard =>
      _clipboardTitle != null || _clipboardUrl != null;

  late final JobsTrackDraftStore _draftStore;
  late final Future<void> Function() _lifecycleFlushCallback;

  /// The form as it stood once this open had finished populating. Everything
  /// the draft slot does is decided by comparing against this.
  late JobsTrackDraft _baseline;

  /// Set once the form has diverged from [_baseline], and never unset: after
  /// the first divergence there is nothing left to compare for.
  bool _started = false;

  /// What is on disk, so an autosave that would rewrite the same bytes doesn't.
  JobsTrackDraft? _lastWritten;

  /// Stops touching the slot for good — set when a successful save has already
  /// cleared it, so the close flush can't put it back.
  bool _draftClosed = false;

  Timer? _draftTimer;

  Iterable<TextEditingController> get _draftControllers => [
    _companyController,
    _titleController,
    _urlController,
    _notesController,
  ];

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    if (draft != null) {
      _populateFromDraft(draft);
      _lastWritten = draft;
      _resumedDraft = true;
    }
    _draftStore = ref.read(jobsTrackDraftStoreProvider);
    _lifecycleFlushCallback = _flushDraft;
    PendingFlushRegistry.instance.register(_lifecycleFlushCallback);
    for (final controller in _draftControllers) {
      controller.addListener(_handleDraftEdit);
    }
    _baseline = _snapshot();
    // After the draft has populated the form, so the empty-field rule below
    // is judged against what the user already has rather than a blank form.
    unawaited(_sniffClipboard());
  }

  void _populateFromDraft(JobsTrackDraft draft) {
    _companyController.text = draft.company;
    _titleController.text = draft.title;
    _urlController.text = draft.applicationUrl;
    _notesController.text = draft.notes;
    _status = draft.status;
    _dateApplied = draft.dateApplied;
    // Resolved against the live season list on first build, once the seasons
    // have actually loaded — a season retired or deleted while the draft sat
    // on disk is not one to file a new application under.
    _seasonIds = draft.seasonIds;
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    PendingFlushRegistry.instance.unregister(_lifecycleFlushCallback);
    // Reads the controllers synchronously and hands the finished snapshot to
    // an async write, so the disposal below can't race it.
    unawaited(_flushDraft());
    for (final controller in _draftControllers) {
      controller.removeListener(_handleDraftEdit);
      controller.dispose();
    }
    _companyFocusNode.dispose();
    _titleFocusNode.dispose();
    _urlFocusNode.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }

  /// The whole form as it stands, ready to persist or to compare.
  JobsTrackDraft _snapshot() => JobsTrackDraft(
    company: _companyController.text,
    title: _titleController.text,
    status: _status,
    applicationUrl: _urlController.text,
    notes: _notesController.text,
    seasonIds: _seasonIds,
    dateApplied: _dateApplied,
    savedAt: utcNow(),
  );

  void _handleDraftEdit() {
    _releaseEditedClipboardFills();
    _draftTimer?.cancel();
    _draftTimer = Timer(_draftDebounce, () => unawaited(_flushDraft()));
  }

  /// Writes, clears, or leaves the one slot alone, whichever the current form
  /// calls for. Runs on the debounce, on close, and on app termination.
  Future<void> _flushDraft() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    if (_draftClosed) return;

    final snapshot = _snapshot();
    if (!_started) {
      // Opened and closed untouched: whatever is in the slot stays there.
      if (snapshot.sameContentAs(_baseline)) return;
      _started = true;
    }
    // A stage pill and a date are not work worth keeping. A form with no text
    // left in it clears the slot instead.
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

  Future<void> _discardDraft() async {
    _draftTimer?.cancel();
    // Cleared before the controllers, so the clear below is not read as the
    // user editing past a clipboard fill.
    _clipboardTitle = null;
    _clipboardUrl = null;
    setState(() {
      for (final controller in _draftControllers) {
        controller.clear();
      }
      _status = '';
      _seasonIds = const [];
      _dateApplied = null;
      _companyError = null;
      _titleError = null;
      _resumedDraft = false;
      _started = false;
    });
    _lastWritten = null;
    _baseline = _snapshot();
    await _draftStore.clear();
  }

  /// Reads the clipboard once, as the form opens, and fills whichever of
  /// Title and URL are still empty (§7).
  ///
  /// Silent about everything: a clipboard holding an image, a platform with no
  /// clipboard at all, and a string that parses to nothing all leave the form
  /// exactly as it was. The read happens only here — never on a timer, and
  /// never on merely looking at the Jobs page (§7.4).
  Future<void> _sniffClipboard() async {
    if (_titleController.text.trim().isNotEmpty &&
        _urlController.text.trim().isNotEmpty) {
      return;
    }
    String? raw;
    try {
      // Plain text only, which is also the image case: a clipboard holding a
      // screenshot has no text flavour to hand back.
      raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (error) {
      debugPrint('Jobs clipboard could not be read: $error');
      return;
    }
    if (!mounted || raw == null) return;
    _applyFromClipboard(parseJobClipboard(raw));
  }

  /// Writes [parsed] into whichever fields are empty, and never over one that
  /// is not (§6.6).
  void _applyFromClipboard(JobClipboardParse parsed) {
    var filled = false;
    if (parsed.title case final title?
        when _titleController.text.trim().isEmpty) {
      _writeFromClipboard(_PasteTarget.title, title);
      filled = true;
    }
    if (parsed.url case final url? when _urlController.text.trim().isEmpty) {
      _writeFromClipboard(_PasteTarget.url, url);
      filled = true;
    }
    // The chip, and a "role title is required" that no longer applies.
    if (filled) {
      setState(() {
        if (_titleController.text.trim().isNotEmpty) _titleError = null;
      });
    }
  }

  /// Puts [value] in [target]'s box and records that the clipboard, not the
  /// user, is what put it there.
  ///
  /// [editable] is the field's live state when the write goes into the field
  /// the user is actually pasting into: routed through it, the paste lands on
  /// the undo stack and Ctrl+Z takes it back. The other field is written
  /// through its controller, since it is not focused and has no caret to move.
  void _writeFromClipboard(
    _PasteTarget target,
    String value, {
    EditableTextState? editable,
  }) {
    // Before the write, so the listener the write fires sees the value it is
    // about to compare against rather than the one being replaced.
    switch (target) {
      case _PasteTarget.title:
        _clipboardTitle = value;
      case _PasteTarget.url:
        _clipboardUrl = value;
    }
    if (editable != null) {
      editable.userUpdateTextEditingValue(
        TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        ),
        SelectionChangedCause.keyboard,
      );
      return;
    }
    _controllerFor(target).text = value;
  }

  TextEditingController _controllerFor(_PasteTarget target) => switch (target) {
    _PasteTarget.title => _titleController,
    _PasteTarget.url => _urlController,
  };

  /// Drops the clipboard's claim on any field whose text no longer matches
  /// what it wrote. Runs on every edit, which is what makes a sniff-filled
  /// field the user has typed in immune to the chip's dismiss.
  void _releaseEditedClipboardFills() {
    var changed = false;
    if (_clipboardTitle != null && _titleController.text != _clipboardTitle) {
      _clipboardTitle = null;
      changed = true;
    }
    if (_clipboardUrl != null && _urlController.text != _clipboardUrl) {
      _clipboardUrl = null;
      changed = true;
    }
    // The chip goes with the last field it still speaks for.
    if (changed && mounted) setState(() {});
  }

  /// The chip's dismiss: empties the fields the clipboard filled and left
  /// untouched, and nothing else.
  void _clearClipboardFill() {
    // Nulled first for the same reason as the write: the clears below fire the
    // edit listener, which would otherwise release them one at a time.
    final title = _clipboardTitle;
    final url = _clipboardUrl;
    _clipboardTitle = null;
    _clipboardUrl = null;
    setState(() {
      if (title != null) _titleController.clear();
      if (url != null) _urlController.clear();
    });
  }

  /// One paste into Title or URL, split between the two (§8).
  ///
  /// Only a paste that replaces the whole field is treated as a new posting;
  /// pasting into the middle of a title already being typed is an ordinary
  /// paste, and so is one whose text holds nothing this field can use.
  Future<void> _smartPaste(
    EditableTextState editable,
    _PasteTarget target,
  ) async {
    final value = editable.textEditingValue;
    final selection = value.selection;
    final replacesField =
        value.text.isEmpty ||
        (selection.isValid &&
            selection.start == 0 &&
            selection.end == value.text.length);
    if (!replacesField) {
      await editable.pasteText(SelectionChangedCause.keyboard);
      return;
    }

    String? raw;
    try {
      raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (error) {
      debugPrint('Jobs clipboard could not be read: $error');
    }
    if (!mounted || !editable.mounted) return;
    if (raw == null || raw.trim().isEmpty) {
      await editable.pasteText(SelectionChangedCause.keyboard);
      return;
    }

    final parsed = parseJobClipboard(raw);
    final mine = target == _PasteTarget.title ? parsed.title : parsed.url;
    final otherTarget = target == _PasteTarget.title
        ? _PasteTarget.url
        : _PasteTarget.title;
    final otherValue = target == _PasteTarget.title ? parsed.url : parsed.title;
    final movesOther =
        otherValue != null && _controllerFor(otherTarget).text.trim().isEmpty;

    // Nothing was pasted into the URL box that reads as a link: keep it
    // literal there rather than moving the user's text to another field. Only
    // a URL ever leaves the box it was pasted into.
    final literal = target == _PasteTarget.url && parsed.url == null;
    if (literal || (mine == null && !movesOther)) {
      await editable.pasteText(SelectionChangedCause.keyboard);
      return;
    }

    if (mine != null) _writeFromClipboard(target, mine, editable: editable);
    if (movesOther) _writeFromClipboard(otherTarget, otherValue);
    editable.hideToolbar();
    setState(() {
      if (_titleController.text.trim().isNotEmpty) _titleError = null;
    });
  }

  Future<void> _save(List<JobStage> stages) async {
    if (_saving) return;
    final company = _companyController.text.trim();
    final title = _titleController.text.trim();
    // Save stays enabled so pressing it can say *why* nothing happened — a
    // greyed-out button on its own left the missing field unnamed.
    if (company.isEmpty || title.isEmpty) {
      setState(() {
        _companyError = company.isEmpty ? 'A company is required' : null;
        _titleError = title.isEmpty ? 'A role title is required' : null;
      });
      (company.isEmpty ? _companyFocusNode : _titleFocusNode).requestFocus();
      return;
    }
    setState(() => _saving = true);

    final url = _urlController.text.trim();
    final notes = _notesController.text.trim();
    final JobApplication created;
    try {
      created = await JobsActions(ref).createApplication(
        company: company,
        title: title,
        status: _status.isNotEmpty
            ? _status
            : (stages.isNotEmpty ? stages.first.name : jobDefaultStage),
        dateApplied: _dateApplied,
        applicationUrl: url.isEmpty ? null : url,
        notes: notes.isEmpty ? null : notes,
        seasonIds: _seasonIds,
      );
    } catch (_) {
      // The latch has to come off or the Save button is dead for the life of
      // the sheet, and closing would be the only way out — taking the form
      // with it.
      if (mounted) setState(() => _saving = false);
      return;
    }

    // The work is filed; there is nothing left to recover. Closing the slot
    // before the pop is what stops the dispose flush from writing it back.
    // Only reached once the write has landed: clearing the draft on a failed
    // save would discard the one remaining copy of the work.
    _draftClosed = true;
    _draftTimer?.cancel();
    unawaited(_draftStore.clear());

    if (mounted) Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final stages =
        ref.watch(jobStagesProvider).valueOrNull ?? const <JobStage>[];
    final companies =
        ref.watch(jobCompaniesProvider).valueOrNull ?? const <JobCompany>[];
    final applications =
        ref.watch(jobApplicationsProvider).valueOrNull ??
        const <JobApplication>[];
    final seasonsAsync = ref.watch(jobSeasonsProvider);
    final seasons = seasonsAsync.valueOrNull ?? const <JobSeason>[];
    final selectableSeasons = jobSelectableSeasons(seasons);

    // A draft can name a season that has since been retired or deleted, and
    // the picker below would then have nothing to show for the id it holds.
    // Only once the seasons have actually loaded, though — clamping against a
    // cold read's empty list would throw away a perfectly good draft.
    if (seasonsAsync.hasValue && _seasonIds.isNotEmpty) {
      final selectableIds = {for (final s in selectableSeasons) s.id};
      final resolved = [
        for (final id in _seasonIds)
          if (selectableIds.contains(id)) id,
      ];
      if (resolved.length != _seasonIds.length) _seasonIds = resolved;
    }

    final effectiveStatus = _status.isNotEmpty
        ? _status
        : (stages.isNotEmpty ? stages.first.name : jobDefaultStage);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      // No reserved header strip — the form scrolls to the window's edge.
      // Close stays pinned as a light overlay so it never scrolls away and
      // never clips content behind a bar.
      //
      // The scroll view is the stack's *unpositioned* child, so the stack
      // takes its height. Positioning it filled the stack to the largest size
      // allowed instead, which is what left dead surface under Save on a form
      // shorter than the window.
      child: Stack(
        children: [
          VoyagerScrollView(
            child: Padding(
                // Top inset clears the overlaid close on first paint; once the
                // user scrolls, content runs under it to the top edge.
                padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Track an application',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_resumedDraft) ...[
                      const SizedBox(height: 10),
                      _DraftBanner(onDiscard: () => unawaited(_discardDraft())),
                    ],
                    if (_filledFromClipboard) ...[
                      const SizedBox(height: 10),
                      _ClipboardBanner(onClear: _clearClipboardFill),
                    ],
                    const SizedBox(height: 16),
                    JobsCompanyField(
                      controller: _companyController,
                      focusNode: _companyFocusNode,
                      companies: companies,
                      recentKeys: jobRecentCompanyKeys(applications),
                      accentColor: accent,
                      contentPadding: jobsFieldContentPadding,
                      autofocus: true,
                      // The form is filled top to bottom, so Enter walks it:
                      // company to role title, role title to the URL box. The
                      // pills in between are picked, not typed, and stopping
                      // on one would break the run of keystrokes.
                      onSubmitted: (_) => _titleFocusNode.requestFocus(),
                      onChanged: (_) {
                        if (_companyError != null) {
                          setState(() => _companyError = null);
                        }
                      },
                    ),
                    if (_companyError case final error?) _FieldError(error),
                    const SizedBox(height: 12),
                    _SmartPasteScope(
                      onPaste: (editable) => unawaited(
                        _smartPaste(editable, _PasteTarget.title),
                      ),
                      child: LabeledTextField(
                        label: 'Role title',
                        controller: _titleController,
                        focusNode: _titleFocusNode,
                        accentColor: accent,
                        dense: true,
                        contentPadding: jobsFieldContentPadding,
                        onSubmitted: (_) => _urlFocusNode.requestFocus(),
                        onChanged: (_) {
                          if (_titleError != null) {
                            setState(() => _titleError = null);
                          }
                        },
                      ),
                    ),
                    if (_titleError case final error?) _FieldError(error),
                    const SizedBox(height: 12),
                    // The same pair the editor leads with: what this
                    // application *is* — where it stands and which run of
                    // applications it belongs to — half the row each. The date
                    // it was sent is a fact about its history and sits at the
                    // foot of the form.
                    Row(
                      children: [
                        Expanded(
                          child: Builder(
                            builder: (pillContext) => SelectorPill(
                              label: effectiveStatus.isEmpty
                                  ? 'No status'
                                  : effectiveStatus,
                              icon: PhosphorIconsRegular.flowArrow,
                              dense: true,
                              accentColor: accent,
                              isActive: true,
                              onTap: () => _pickStatus(
                                pillContext,
                                stages,
                                effectiveStatus,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Builder(
                            builder: (pillContext) => SelectorPill(
                              label: _seasonLabel(selectableSeasons),
                              icon: PhosphorIconsRegular.calendarCheck,
                              dense: true,
                              accentColor: accent,
                              isActive: _seasonIds.isNotEmpty,
                              onTap: selectableSeasons.isEmpty
                                  ? () {}
                                  : () => _pickSeasons(
                                      pillContext,
                                      selectableSeasons,
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _SmartPasteScope(
                      onPaste: (editable) => unawaited(
                        _smartPaste(editable, _PasteTarget.url),
                      ),
                      child: LabeledTextField(
                        label: 'Application URL',
                        controller: _urlController,
                        focusNode: _urlFocusNode,
                        accentColor: accent,
                        dense: true,
                        contentPadding: jobsFieldContentPadding,
                        keyboardType: TextInputType.url,
                      ),
                    ),
                    _DuplicateUrlHint(
                      controller: _urlController,
                      applications: applications,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 180,
                      child: TagHighlightedTextField(
                        controller: _notesController,
                        focusNode: _notesFocusNode,
                        label: 'Notes',
                        accentColor: accent,
                        expands: true,
                        maxLines: null,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Builder(
                        builder: (pillContext) => SelectorPill(
                          label: DateFormat.yMMMd().format(
                            (_dateApplied ?? DateTime.now()).toLocal(),
                          ),
                          icon: PhosphorIconsRegular.calendarBlank,
                          dense: true,
                          // The edit panel's twin of this capsule is drawn in
                          // the company's category colour, which is the grey
                          // outline for an uncategorised company — the case
                          // this form is always in. It takes that grey rather
                          // than the app accent, so the two read alike.
                          accentColor: theme.colorScheme.outline,
                          isActive: true,
                          onTap: () => _pickDate(pillContext),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    GlassButton(
                      onPressed: _saving ? null : () => _save(stages),
                      label: 'Save',
                      color: accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ],
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
    );
    // _save guards itself, and names a missing field rather than no-opping.
    return CtrlEnterToSubmitScope(onSubmit: () => _save(stages), child: sheet);
  }

  String _seasonLabel(List<JobSeason> selectable) {
    if (selectable.isEmpty) return 'No seasons yet';
    final names = [
      for (final season in selectable)
        if (_seasonIds.contains(season.id)) season.name,
    ];
    // The count once there is more than one to name: several season names do
    // not fit the pill, and the picker is one tap away for the detail.
    return switch (names.length) {
      0 => 'No season',
      1 => names.single,
      _ => '${names.length} seasons',
    };
  }

  Future<void> _pickStatus(
    BuildContext pillContext,
    List<JobStage> stages,
    String current,
  ) async {
    final picked = await showContextualPopover<String>(
      context: context,
      buttonContext: pillContext,
      accentColor: Theme.of(context).colorScheme.primary,
      tapThroughContext: context,
      builder: (context) => JobsOptionList(
        options: [
          for (final stage in stages) (value: stage.name, label: stage.name),
        ],
        selected: current,
      ),
    );
    if (picked == null || picked == current) return;
    setState(() => _status = picked);
    _handleDraftEdit();
  }

  Future<void> _pickDate(BuildContext pillContext) async {
    final initial = (_dateApplied ?? DateTime.now()).toLocal();
    final picked = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: pillContext,
      // Both are needed: the calendar hangs its grid off an Expanded, so a
      // popover left to size itself gives that grid no height at all and the
      // sheet paints as an empty box.
      width: 320,
      height: 380,
      accentColor: Theme.of(context).colorScheme.primary,
      tapThroughContext: context,
      builder: (context) => DateSelectorPopover(
        initialStartDate: initial,
        initialEndDate: initial,
        singleDateMode: true,
        inlineMode: true,
        accentColor: Theme.of(context).colorScheme.primary,
        onDateSelected: (date) => Navigator.of(context).pop(date),
      ),
    );
    if (picked == null) return;
    // Date-only: the sparkline buckets by calendar day, and carrying a
    // wall-clock time here would make "the same day" depend on the hour the
    // picker happened to return.
    setState(
      () => _dateApplied = DateTime(picked.year, picked.month, picked.day),
    );
    _handleDraftEdit();
  }

  Future<void> _pickSeasons(
    BuildContext pillContext,
    List<JobSeason> selectable,
  ) async {
    // Stays open while the user ticks cycles off, so filing one application
    // under two seasons is two taps rather than two trips through the menu.
    // Closing it is therefore a click somewhere else, and [tapThroughContext]
    // makes that click land: pressing Save with the menu open saves, rather
    // than being spent on dismissing the menu first. Every pick is already
    // applied on the spot, so there is nothing left to confirm.
    await showContextualPopover<void>(
      context: context,
      buttonContext: pillContext,
      accentColor: Theme.of(context).colorScheme.primary,
      tapThroughContext: context,
      builder: (context) => JobsMultiOptionList(
        emptyLabel: 'No season',
        options: [
          for (final season in selectable)
            (value: season.id, label: season.name),
        ],
        selected: _seasonIds.toSet(),
        onChanged: (seasonIds) {
          // Kept in the user's own season order, which is the order the
          // Seasons tab and the table's column both read in.
          setState(() {
            _seasonIds = [
              for (final season in selectable)
                if (seasonIds.contains(season.id)) season.id,
            ];
          });
          _handleDraftEdit();
        },
      ),
    );
  }
}

class _FieldError extends StatelessWidget {
  const _FieldError(this.message, {this.soft = false});

  final String message;

  /// A remark rather than a refusal: the duplicate-URL hint is informational
  /// and Save works either way (§9), so it is not drawn in the error colour.
  final bool soft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: soft
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}

/// Says another application already points at the URL being typed.
///
/// Listens to the field itself rather than lifting the text into the form's
/// state: the hint is the only thing on the page that changes as the URL is
/// typed, and rebuilding the whole modal per keystroke to show one line of
/// text is not a trade worth making.
class _DuplicateUrlHint extends StatelessWidget {
  const _DuplicateUrlHint({
    required this.controller,
    required this.applications,
  });

  final TextEditingController controller;
  final List<JobApplication> applications;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final key = jobUrlKey(value.text);
        if (key == null) return const SizedBox.shrink();
        final seen = applications.any(
          (application) => jobDuplicateKey(application) == key,
        );
        if (!seen) return const SizedBox.shrink();
        return const _FieldError(
          'You have already tracked this posting',
          soft: true,
        );
      },
    );
  }
}

/// Sends this field's paste through [parseJobClipboard] instead of straight
/// into the box.
///
/// [EditableText] publishes its paste action as overridable, so an [Actions]
/// wrapped around one field claims Ctrl+V for that field alone — the company
/// and notes boxes inside the same form paste as they always have.
class _SmartPasteScope extends StatelessWidget {
  const _SmartPasteScope({required this.onPaste, required this.child});

  final void Function(EditableTextState editable) onPaste;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) {
            // The field being pasted into is the focused one, which is also
            // the only way to reach its state from above it.
            final editable = FocusManager.instance.primaryFocus?.context
                ?.findAncestorStateOfType<EditableTextState>();
            if (editable != null) onPaste(editable);
            return null;
          },
        ),
      },
      child: child,
    );
  }
}

/// The dismissible mark that the clipboard, rather than the user, filled a
/// field in. Sits with the draft banner at the head of the form.
class _ClipboardBanner extends StatelessWidget {
  const _ClipboardBanner({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIconsRegular.clipboardText,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'From clipboard',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            onPressed: onClear,
            icon: const Icon(PhosphorIconsRegular.x, size: 14),
            visualDensity: VisualDensity.compact,
            tooltip: 'Clear what the clipboard filled in',
          ),
        ],
      ),
    );
  }
}

class _DraftBanner extends StatelessWidget {
  const _DraftBanner({required this.onDiscard});

  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            PhosphorIconsRegular.arrowCounterClockwise,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Picked up where you left off',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          GlassButton(
            dense: true,
            label: 'Start over',
            tooltip: 'Throw the saved draft away and start from a blank form',
            onPressed: onDiscard,
          ),
        ],
      ),
    );
  }
}
