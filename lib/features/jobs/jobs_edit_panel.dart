import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/edit_side_panel_host.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_actions.dart';
import 'package:voyager/features/jobs/jobs_company_field.dart';
import 'package:voyager/features/jobs/jobs_option_list.dart';

/// Default editor panel width — see [EditSidePanelMetrics.defaultWidth].
const jobsEditPanelWidth = EditSidePanelMetrics.defaultWidth;

/// Editor for one application, in the todo page's side-panel idiom.
///
/// Text fields autosave on a debounce; everything picked from a control saves
/// immediately. Both routes go through [JobsActions.saveApplication], which is
/// what appends the status timeline entry when the stage changes.
class JobsEditPanel extends ConsumerStatefulWidget {
  const JobsEditPanel({
    super.key,
    required this.application,
    required this.stages,
    required this.companies,
    required this.seasons,
    required this.recentCompanyKeys,
    required this.accentColor,
    required this.onClose,
    this.categoryColorFor,
  });

  final JobApplication application;
  final List<JobStage> stages;
  final List<JobCompany> companies;

  /// Every season, retired ones included: the picker only *offers* the ones
  /// still running, but it has to be able to name the ones this application is
  /// already filed under.
  final List<JobSeason> seasons;

  /// Company keys most-recently-applied-to first, for the typeahead's ranking.
  final List<String> recentCompanyKeys;
  final Color accentColor;
  final VoidCallback onClose;
  final Color? Function(JobCompany company)? categoryColorFor;

  @override
  ConsumerState<JobsEditPanel> createState() => _JobsEditPanelState();
}

class _JobsEditPanelState extends ConsumerState<JobsEditPanel> {
  static const _saveDebounce = Duration(milliseconds: 400);

  late TextEditingController _companyController;
  late TextEditingController _titleController;
  late TextEditingController _urlController;
  late TextEditingController _notesController;
  late FocusNode _notesFocusNode;
  Timer? _saveTimer;

  /// The last version this panel wrote, which is what the next save diffs
  /// against. Kept separately from `widget.application` because the provider
  /// refresh that carries a save back can land a frame or two later, and
  /// diffing against a stale copy would record the same status change twice.
  late JobApplication _current;

  @override
  void initState() {
    super.initState();
    _current = widget.application;
    _companyController = TextEditingController(text: _current.company);
    _titleController = TextEditingController(text: _current.title);
    _urlController = TextEditingController(text: _current.applicationUrl ?? '');
    _notesController = TextEditingController(text: _current.notes ?? '');
    _notesFocusNode = FocusNode();
  }

  @override
  void didUpdateWidget(JobsEditPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.application.id != widget.application.id) {
      // A different application: flush whatever the old one had pending
      // before the controllers are pointed at new text.
      _saveTimer?.cancel();
      _commit();
      _current = widget.application;
      _companyController.text = _current.company;
      _titleController.text = _current.title;
      _urlController.text = _current.applicationUrl ?? '';
      _notesController.text = _current.notes ?? '';
      return;
    }

    // The same application, changed by something other than this panel — the
    // table's status capsule, a row menu, a pull from another device. Adopted,
    // or the capsules keep showing the old values. An older copy, or this
    // panel's own save coming back, is not newer and is left alone.
    final incoming = widget.application;
    if (incoming.version < _current.version ||
        (incoming.version == _current.version &&
            !incoming.updatedAt.isAfter(_current.updatedAt))) {
      return;
    }
    // A box the user has typed past keeps their text; its pending save only
    // writes the fields they changed.
    void adopt(TextEditingController controller, String before, String after) {
      if (controller.text == before && before != after) controller.text = after;
    }

    adopt(_companyController, _current.company, incoming.company);
    adopt(_titleController, _current.title, incoming.title);
    adopt(
      _urlController,
      _current.applicationUrl ?? '',
      incoming.applicationUrl ?? '',
    );
    adopt(_notesController, _current.notes ?? '', incoming.notes ?? '');
    _current = incoming;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Fire-and-forget rather than awaited: dispose cannot be async, and the
    // repository write does not need this widget to still exist.
    unawaited(_commit());
    _companyController.dispose();
    _titleController.dispose();
    _urlController.dispose();
    _notesFocusNode.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(_commit()));
  }

  /// Writes the fields back if any of them differ. Title falls back to the
  /// last non-empty value: an application must have one (§3.3), and clearing
  /// the box mid-edit should not persist as a blank row.
  Future<void> _commit() async {
    final company = _companyController.text.trim();
    final title = _titleController.text.trim();
    final url = _urlController.text.trim();
    final notes = _notesController.text;

    final updated = _current.copyWith(
      company: company.isEmpty ? _current.company : company,
      title: title.isEmpty ? _current.title : title,
      applicationUrl: url.isEmpty ? null : url,
      clearApplicationUrl: url.isEmpty,
      notes: notes.isEmpty ? null : notes,
      clearNotes: notes.isEmpty,
      bumpVersion: false,
    );
    if (updated.company == _current.company &&
        updated.title == _current.title &&
        updated.applicationUrl == _current.applicationUrl &&
        updated.notes == _current.notes) {
      return;
    }
    await _save(
      _current.copyWith(
        company: updated.company,
        title: updated.title,
        applicationUrl: updated.applicationUrl,
        clearApplicationUrl: updated.applicationUrl == null,
        notes: updated.notes,
        clearNotes: updated.notes == null,
      ),
    );
  }

  Future<void> _save(JobApplication updated) async {
    final previous = _current;
    _current = updated;
    await JobsActions(ref).saveApplication(updated, previous: previous);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeader(onClose: widget.onClose),
          Expanded(
            child: VoyagerScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  JobsCompanyField(
                    controller: _companyController,
                    companies: widget.companies,
                    recentKeys: widget.recentCompanyKeys,
                    accentColor: accent,
                    categoryColorFor: widget.categoryColorFor,
                    contentPadding: jobsFieldContentPadding,
                    onChanged: (_) => _scheduleSave(),
                  ),
                  const SizedBox(height: 12),
                  LabeledTextField(
                    label: 'Title',
                    controller: _titleController,
                    accentColor: accent,
                    dense: true,
                    contentPadding: jobsFieldContentPadding,
                    onChanged: (_) => _scheduleSave(),
                  ),
                  const SizedBox(height: 12),
                  // The two capsules that say what this application *is* —
                  // where it stands and which run of applications it belongs
                  // to — share the row, half each. The date it was sent is a
                  // fact about its history, so it sits with the history.
                  Row(
                    children: [
                      Expanded(child: _statusPill(accent)),
                      const SizedBox(width: 8),
                      Expanded(child: _seasonPill(accent)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LabeledTextField(
                    label: 'Application URL',
                    controller: _urlController,
                    accentColor: accent,
                    dense: true,
                    contentPadding: jobsFieldContentPadding,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _scheduleSave(),
                  ),
                  if (_current.applicationUrl case final url?)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: GlassButton(
                          dense: true,
                          // No colour override and no icon-size override: the
                          // panel's accent is the company's *category* colour,
                          // which falls back to the theme's grey outline for
                          // an uncategorised company and left this reading as
                          // a flat grey button rather than a glass one. It
                          // takes the app accent and the dense icon size every
                          // other glass button in the app has.
                          icon: const Icon(PhosphorIconsRegular.arrowSquareOut),
                          label: 'Open',
                          tooltip: 'Open the application URL in your browser',
                          onPressed: () => _openUrl(url),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    // The todo panel's notes box is the canonical one, and
                    // both editors now read at the same size.
                    height: 120,
                    child: TagHighlightedTextField(
                      controller: _notesController,
                      focusNode: _notesFocusNode,
                      label: 'Notes',
                      accentColor: accent,
                      style: theme.textTheme.bodySmall,
                      expands: true,
                      maxLines: null,
                      onChanged: (_) => _scheduleSave(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _StatusTimeline(
                    applicationId: _current.id,
                    trailing: _datePill(accent),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(Color accent) {
    return Builder(
      builder: (pillContext) => SelectorPill(
        label: _current.status.isEmpty ? 'No status' : _current.status,
        icon: PhosphorIconsRegular.flowArrow,
        dense: true,
        accentColor: accent,
        isActive: true,
        onTap: () => _pickStatus(pillContext),
      ),
    );
  }

  Future<void> _pickStatus(BuildContext pillContext) async {
    // Orphans included: a status whose stage was deleted still has to be
    // selectable back onto itself, and it has to be visible as an option so the
    // user can see what the application is actually on.
    final names = {
      for (final stage in widget.stages) stage.name,
      if (_current.status.isNotEmpty) _current.status,
    };
    final picked = await showContextualPopover<String>(
      context: context,
      buttonContext: pillContext,
      accentColor: widget.accentColor,
      builder: (context) => JobsOptionList(
        options: [for (final name in names) (value: name, label: name)],
        selected: _current.status,
      ),
    );
    if (picked == null || picked == _current.status) return;
    await _save(_current.copyWith(status: picked));
    if (mounted) setState(() {});
  }

  Widget _datePill(Color accent) {
    return Builder(
      builder: (pillContext) => SelectorPill(
        label: DateFormat.yMMMd().format(jobDayKey(_current.dateApplied)),
        icon: PhosphorIconsRegular.calendarBlank,
        dense: true,
        accentColor: accent,
        isActive: true,
        onTap: () => _pickDate(pillContext),
      ),
    );
  }

  Future<void> _pickDate(BuildContext pillContext) async {
    final initial = jobDayKey(_current.dateApplied);
    final picked = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: pillContext,
      // Both are needed: the calendar hangs its grid off an Expanded, so a
      // popover left to size itself gives that grid no height at all and the
      // sheet paints as an empty box.
      width: 320,
      height: 380,
      accentColor: widget.accentColor,
      builder: (context) => DateSelectorPopover(
        initialStartDate: initial,
        initialEndDate: initial,
        singleDateMode: true,
        inlineMode: true,
        accentColor: widget.accentColor,
        onDateSelected: (date) => Navigator.of(context).pop(date),
      ),
    );
    if (picked == null) return;
    // Date-only, at UTC midnight: the sparkline buckets by calendar day, and
    // any other instant reads as a different day somewhere — see
    // [jobCalendarDay].
    await _save(
      _current.copyWith(
        dateApplied: DateTime.utc(picked.year, picked.month, picked.day),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _seasonPill(Color accent) {
    final names = _seasonNames();
    return Builder(
      builder: (pillContext) => SelectorPill(
        // The count once there is more than one to name: three season names
        // do not fit the half-row the pill gets, and the picker is one tap
        // away for the detail.
        label: switch (names.length) {
          0 => 'No season',
          1 => names.single,
          _ => '${names.length} seasons',
        },
        icon: PhosphorIconsRegular.calendarCheck,
        dense: true,
        accentColor: accent,
        isActive: names.isNotEmpty,
        onTap: () => _pickSeasons(pillContext),
      ),
    );
  }

  /// The application's seasons as they read, in the user's own season order.
  /// Retired ones carry the marker, because that — not the application's own
  /// fields — is what has it hidden from the list.
  List<String> _seasonNames() => [
    for (final season in widget.seasons)
      if (_current.seasonIds.contains(season.id))
        season.isArchived ? '${season.name} (archived)' : season.name,
  ];

  Future<void> _pickSeasons(BuildContext pillContext) async {
    await showContextualPopover<void>(
      context: context,
      buttonContext: pillContext,
      accentColor: widget.accentColor,
      builder: (context) => JobsMultiOptionList(
        emptyLabel: 'No season',
        selected: _current.seasonIds.toSet(),
        options: [
          for (final season in jobSelectableSeasons(widget.seasons))
            (value: season.id, label: season.name),
          // A retired season is not offered for anything new, but one this
          // application is already in has to stay visible — and removable, so
          // the user can take it back out.
          for (final season in widget.seasons)
            if (season.isArchived && _current.seasonIds.contains(season.id))
              (value: season.id, label: '${season.name} (archived)'),
        ],
        // Saved on every toggle rather than when the list closes: the popover
        // is dismissed by tapping away, which returns nothing to save from.
        onChanged: (seasonIds) => unawaited(_saveSeasons(seasonIds)),
      ),
    );
  }

  Future<void> _saveSeasons(Set<String> seasonIds) async {
    // Stored in the user's season order, so the table's join and the pill's
    // count both read off a list that matches the Seasons tab.
    final ordered = [
      for (final season in widget.seasons)
        if (seasonIds.contains(season.id)) season.id,
    ];
    await _save(_current.copyWith(seasonIds: ordered));
    if (mounted) setState(() {});
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Close, and nothing else, on the right. Duplicating and deleting are row
/// actions on the table's right-click menu: the panel edits the one
/// application it is showing, and a destructive button sitting beside the
/// fields being typed into is not where either belongs.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          const Spacer(),
          IconButton(
            tooltip: 'Close',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(PhosphorIconsRegular.x),
          ),
        ],
      ),
    );
  }
}

/// The application's status history (§4.2), oldest first.
///
/// [trailing] rides on the heading row, right-aligned — the date-applied
/// capsule, which belongs with the history rather than above it. It is shown
/// whether or not there are any events to head, so the date is never missing
/// from the form; the "History" word is what an empty log takes away.
class _StatusTimeline extends ConsumerWidget {
  const _StatusTimeline({required this.applicationId, this.trailing});

  final String applicationId;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final eventsAsync = ref.watch(jobStatusEventsProvider(applicationId));
    final events = eventsAsync.valueOrNull ?? const <JobStatusEvent>[];
    if (events.isEmpty && trailing == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (events.isNotEmpty)
              Text(
                'History',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const Spacer(),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        for (final event in events)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 8),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.5,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    // The strings as they read when the move happened —
                    // renaming a stage later does not rewrite this (§4.2).
                    event.fromStatus == null
                        ? 'Created as ${event.toStatus}'
                        : '${event.fromStatus} → ${event.toStatus}',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Text(
                  DateFormat.yMMMd().format(event.changedAt.toLocal()),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
