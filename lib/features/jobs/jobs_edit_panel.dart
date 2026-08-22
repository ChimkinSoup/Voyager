import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_actions.dart';
import 'package:voyager/features/jobs/jobs_company_field.dart';

const jobsEditPanelWidth = 420.0;

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
    required this.accentColor,
    required this.onClose,
    required this.onDeleted,
    required this.onDuplicated,
    this.categoryColorFor,
  });

  final JobApplication application;
  final List<JobStage> stages;
  final List<JobCompany> companies;
  final List<JobSeason> seasons;
  final Color accentColor;
  final VoidCallback onClose;
  final VoidCallback onDeleted;
  final ValueChanged<JobApplication> onDuplicated;
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
    if (oldWidget.application.id == widget.application.id) return;
    // A different application: flush whatever the old one had pending before
    // the controllers are pointed at new text.
    _saveTimer?.cancel();
    _commit();
    _current = widget.application;
    _companyController.text = _current.company;
    _titleController.text = _current.title;
    _urlController.text = _current.applicationUrl ?? '';
    _notesController.text = _current.notes ?? '';
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
          _PanelHeader(
            onClose: widget.onClose,
            onDuplicate: _handleDuplicate,
            onDelete: _handleDelete,
          ),
          Expanded(
            child: VoyagerScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  JobsCompanyField(
                    controller: _companyController,
                    companies: widget.companies,
                    accentColor: accent,
                    categoryColorFor: widget.categoryColorFor,
                    onChanged: (_) => _scheduleSave(),
                  ),
                  const SizedBox(height: 12),
                  LabeledTextField(
                    label: 'Title',
                    controller: _titleController,
                    accentColor: accent,
                    dense: true,
                    onChanged: (_) => _scheduleSave(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _statusPill(accent)),
                      const SizedBox(width: 8),
                      Expanded(child: _datePill(accent)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _seasonPill(accent),
                  const SizedBox(height: 12),
                  LabeledTextField(
                    label: 'Application URL',
                    controller: _urlController,
                    accentColor: accent,
                    dense: true,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => _scheduleSave(),
                  ),
                  if (_current.applicationUrl case final url?)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _openUrl(url),
                        icon: const Icon(
                          PhosphorIconsRegular.arrowSquareOut,
                          size: 13,
                        ),
                        label: const Text('Open'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: theme.textTheme.labelSmall,
                        ),
                      ),
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
                      onChanged: (_) => _scheduleSave(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _StatusTimeline(applicationId: _current.id),
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
    final names = [
      for (final stage in widget.stages) stage.name,
      if (_current.status.isNotEmpty &&
          !widget.stages.any((s) => s.name == _current.status))
        _current.status,
    ];
    final picked = await showContextualPopover<String>(
      context: context,
      buttonContext: pillContext,
      accentColor: widget.accentColor,
      builder: (context) => _OptionList(
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
        label: DateFormat.yMMMd().format(_current.dateApplied.toLocal()),
        icon: PhosphorIconsRegular.calendarBlank,
        dense: true,
        accentColor: accent,
        isActive: true,
        onTap: () => _pickDate(pillContext),
      ),
    );
  }

  Future<void> _pickDate(BuildContext pillContext) async {
    final initial = _current.dateApplied.toLocal();
    final picked = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: pillContext,
      width: 280,
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
    // Date-only: the sparkline buckets by calendar day, and carrying a
    // wall-clock time here would make "the same day" depend on the hour the
    // picker happened to return.
    await _save(
      _current.copyWith(
        dateApplied: DateTime(picked.year, picked.month, picked.day),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _seasonPill(Color accent) {
    final season = widget.seasons.cast<JobSeason?>().firstWhere(
      (s) => s!.id == _current.seasonId,
      orElse: () => null,
    );
    return Builder(
      builder: (pillContext) => SelectorPill(
        label: season?.name ?? 'Active (not archived)',
        icon: PhosphorIconsRegular.archive,
        dense: true,
        accentColor: accent,
        isActive: _current.isArchived,
        onTap: () => _pickSeason(pillContext),
      ),
    );
  }

  Future<void> _pickSeason(BuildContext pillContext) async {
    final picked = await showContextualPopover<String>(
      context: context,
      buttonContext: pillContext,
      accentColor: widget.accentColor,
      builder: (context) => _OptionList(
        options: [
          (value: '', label: 'Active (not archived)'),
          for (final season in widget.seasons)
            (value: season.id, label: season.name),
        ],
        selected: _current.seasonId ?? '',
      ),
    );
    if (picked == null) return;
    final seasonId = picked.isEmpty ? null : picked;
    if (seasonId == _current.seasonId) return;
    final previous = _current;
    _current = _current.copyWith(
      seasonId: seasonId,
      clearSeasonId: seasonId == null,
    );
    await JobsActions(ref).saveApplication(_current, previous: previous);
    if (mounted) setState(() {});
  }

  Future<void> _handleDuplicate() async {
    await _commit();
    final copy = await JobsActions(ref).duplicateApplication(_current);
    widget.onDuplicated(copy);
  }

  Future<void> _handleDelete() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete application?',
      message:
          '${_current.title} at ${_current.company} and its status history '
          'will be permanently deleted. This cannot be undone.',
    );
    if (!confirmed) return;
    // Cancelled before the delete, not after: a debounced save landing on a
    // tombstone would write the content straight back.
    _saveTimer?.cancel();
    await JobsActions(ref).deleteApplication(_current);
    widget.onDeleted();
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.onClose,
    required this.onDuplicate,
    required this.onDelete,
  });

  final VoidCallback onClose;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(PhosphorIconsRegular.x),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Duplicate application',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onDuplicate,
            icon: const Icon(PhosphorIconsRegular.copy),
          ),
          IconButton(
            tooltip: 'Delete application',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            icon: Icon(
              PhosphorIconsRegular.trash,
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}

typedef _Option = ({String value, String label});

class _OptionList extends StatelessWidget {
  const _OptionList({required this.options, required this.selected});

  final List<_Option> options;
  final String selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: VoyagerScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              InkWell(
                onTap: () => Navigator.of(context).pop(option.value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          option.label,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (option.value == selected)
                        Icon(
                          PhosphorIconsRegular.check,
                          size: 13,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The application's status history (§4.2), oldest first.
class _StatusTimeline extends ConsumerWidget {
  const _StatusTimeline({required this.applicationId});

  final String applicationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final eventsAsync = ref.watch(jobStatusEventsProvider(applicationId));
    final events = eventsAsync.valueOrNull ?? const <JobStatusEvent>[];
    if (events.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'History',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
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
