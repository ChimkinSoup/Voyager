import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sound/app_sounds.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_labels.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/report_height.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/services/finance_origins.dart';
import 'package:voyager/domain/services/reminder_schedule.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

/// Rows shown before the rest fold behind "Show N more", so a long list of
/// reminders cannot push the notification feed out of the popover.
///
/// A fold rather than a capped inner scroll view: the popover is deliberately
/// one scroll region, and a viewport inside it would catch drags meant for the
/// whole panel.
const int _kVisibleRules = 4;

const double _kRowRadius = 16;
const double _kLeadingSlot = 40;

/// How far the editor's On row reaches past the form on each side, so its
/// hover fill has room around the label and the switch.
const double _kTogglePadding = 12;

/// The editor's width, the same in the dialog and in the hotkey floater —
/// which sizes its window to it (see `kReminderFloaterSize`).
const double kReminderFormWidth = 460 + _kTogglePadding * 2;

/// The Inbox's Scheduled section (`SCHEDULED_REMINDERS_HLD.md` §6.2): create,
/// edit, switch off and delete reminders, and see where each one stands.
class ScheduledRemindersSection extends ConsumerStatefulWidget {
  const ScheduledRemindersSection({super.key});

  @override
  ConsumerState<ScheduledRemindersSection> createState() =>
      _ScheduledRemindersSectionState();
}

class _ScheduledRemindersSectionState
    extends ConsumerState<ScheduledRemindersSection> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules =
        ref.watch(scheduledReminderRulesProvider.settled).valueOrNull ??
        const <ScheduledReminderRule>[];
    final engine = ref.watch(reminderEngineProvider);
    // Soonest first, so the fold below keeps the reminders that are next.
    final ordered = [
      for (final rule in rules)
        (
          rule: rule,
          view: engine.view(
            reminderSourceKey(ReminderSourceKind.scheduledRule, rule.id),
          ),
        ),
    ]..sort(_bySoonest);
    final visible = _expanded ? ordered : ordered.take(_kVisibleRules).toList();
    final folded = ordered.length - visible.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Scheduled',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: 'Add scheduled reminder',
                child: GlassButton(
                  dense: true,
                  tooltip: 'Add scheduled reminder',
                  icon: const Icon(PhosphorIconsRegular.plus, size: 14),
                  onPressed: () {
                    final container = ProviderScope.containerOf(
                      context,
                      listen: false,
                    );
                    unawaited(
                      showScheduledReminderEditor(
                        context,
                        draft: ref.read(scheduledReminderDraftProvider),
                        onDraft: (draft) =>
                            storeScheduledReminderDraft(container, draft),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          if (rules.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Daily, weekly or one-time reminders at a set time.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 6),
          for (final entry in visible)
            _ScheduledRuleRow(
              key: ValueKey(entry.rule.id),
              rule: entry.rule,
              view: entry.view,
            ),
          if (folded > 0 || (_expanded && rules.length > _kVisibleRules))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Show less' : 'Show $folded more'),
              ),
            ),
        ],
      ),
    );
  }
}

/// When a rule next wants attention: a due one's moment has already passed,
/// so it sorts above anything still to come. Null for one that is off,
/// completed or out of occurrences — nothing is coming for those.
DateTime? _nextMoment(ReminderSourceView? view) {
  final evaluation = view?.evaluation;
  if (evaluation == null) return null;
  if (evaluation.phase == ReminderPhase.due) return evaluation.dueSince;
  return evaluation.nextFireAt;
}

/// Soonest first, with the rules that have no next moment after them.
///
/// Creation order breaks a tie: [List.sort] is not stable, and without it two
/// rules sharing a fire time could swap places on any rebuild — which is now
/// every minute.
int _bySoonest(
  ({ScheduledReminderRule rule, ReminderSourceView? view}) a,
  ({ScheduledReminderRule rule, ReminderSourceView? view}) b,
) {
  final at = _nextMoment(a.view);
  final bt = _nextMoment(b.view);
  if (at != null && bt != null) {
    final byTime = at.compareTo(bt);
    if (byTime != 0) return byTime;
  } else if (at != bt) {
    return at == null ? 1 : -1;
  }
  return a.rule.createdAt.compareTo(b.rule.createdAt);
}

enum _RuleAction { edit, toggle, history, delete }

class _ScheduledRuleRow extends ConsumerStatefulWidget {
  const _ScheduledRuleRow({super.key, required this.rule, required this.view});

  final ScheduledReminderRule rule;
  final ReminderSourceView? view;

  @override
  ConsumerState<_ScheduledRuleRow> createState() => _ScheduledRuleRowState();
}

class _ScheduledRuleRowState extends ConsumerState<_ScheduledRuleRow> {
  var _hovered = false;

  Future<void> _perform(_RuleAction action) async {
    switch (action) {
      case _RuleAction.edit:
        await showScheduledReminderEditor(context, existing: widget.rule);
      case _RuleAction.toggle:
        await _toggle();
      case _RuleAction.history:
        await showReminderHistoryDialog(
          context,
          sourceKey: reminderSourceKey(
            ReminderSourceKind.scheduledRule,
            widget.rule.id,
          ),
          title: widget.rule.title,
        );
      case _RuleAction.delete:
        await _delete();
    }
  }

  Future<void> _toggle() async {
    final rule = widget.rule;
    final now = utcNow();
    await ref
        .read(reminderRepositoryProvider)
        .upsertRule(
          rule.copyWith(
            enabled: !rule.enabled,
            // Switched back on, it starts from now: the occurrences it missed
            // while off are not owed.
            armedAt: rule.enabled ? null : now,
            updatedAt: now,
            version: rule.version + 1,
          ),
        );
    ref.invalidate(scheduledReminderRulesProvider);
  }

  Future<void> _delete() async {
    final rule = widget.rule;
    // Captured before the write: the row unmounts with the delete, and the
    // toast offering the undo has to outlive it.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(rule.title, fallback: 'reminder'),
      delete: () async {
        final now = utcNow();
        await container
            .read(reminderRepositoryProvider)
            .upsertRule(
              rule.copyWith(
                deletedAt: now,
                updatedAt: now,
                version: rule.version + 1,
              ),
            );
        container.invalidate(scheduledReminderRulesProvider);
      },
      restore: () async {
        final repository = container.read(reminderRepositoryProvider);
        // The version is resolved against disk rather than against the
        // snapshot — see [restoreVersionFrom].
        final current = await repository.getRule(rule.id);
        abortIfAlreadyRestored(
          found: current != null,
          deletedAt: current?.deletedAt,
        );
        await repository.upsertRule(
          rule.copyWith(
            clearDeletedAt: true,
            updatedAt: utcNow(),
            version: restoreVersionFrom(
              preDeleteVersion: rule.version,
              currentVersion: current?.version,
            ),
          ),
        );
        container.invalidate(scheduledReminderRulesProvider);
      },
    );
  }

  /// The row's actions, shared by the right-click menu and the overflow
  /// button touch screens need.
  List<({_RuleAction action, ContextMenuItem item})> _entries() {
    ContextMenuItem item(
      _RuleAction action,
      String label,
      IconData icon, {
      bool destructive = false,
    }) => ContextMenuItem(
      label: label,
      icon: icon,
      isDestructive: destructive,
      onTap: () => unawaited(_perform(action)),
    );
    final enabled = widget.rule.enabled;
    return [
      (
        action: _RuleAction.edit,
        item: item(_RuleAction.edit, 'Edit', PhosphorIconsRegular.pencilSimple),
      ),
      (
        action: _RuleAction.toggle,
        item: item(
          _RuleAction.toggle,
          enabled ? 'Turn off' : 'Turn on',
          enabled ? PhosphorIconsRegular.bellSlash : PhosphorIconsRegular.bell,
        ),
      ),
      (
        action: _RuleAction.history,
        item: item(
          _RuleAction.history,
          'History',
          PhosphorIconsRegular.clockCounterClockwise,
        ),
      ),
      (
        action: _RuleAction.delete,
        item: item(
          _RuleAction.delete,
          'Delete',
          PhosphorIconsRegular.trash,
          destructive: true,
        ),
      ),
    ];
  }

  Future<void> _openOverflow(BuildContext buttonContext) async {
    final action = await showContextualPopover<_RuleAction>(
      context: context,
      buttonContext: buttonContext,
      width: 180,
      builder: (popoverContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in _entries())
            _OverflowEntry(
              item: entry.item,
              onTap: () => Navigator.of(popoverContext).pop(entry.action),
            ),
        ],
      ),
    );
    if (action != null && mounted) await _perform(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = widget.rule;
    final devices = ref.watch(deviceRegistrationsProvider.settled).valueOrNull;
    final status = scheduledRuleStatus(
      rule,
      widget.view,
      DateTime.now(),
      registeredDeviceIds: devices == null
          ? null
          : {for (final device in devices) device.id},
    );
    final due = widget.view?.isDue ?? false;
    final muted = !rule.enabled || !(widget.view?.targetsThisDevice ?? true);

    return ContextMenuRegion(
      itemsBuilder: () => [for (final entry in _entries()) entry.item],
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Material(
            color: _hovered ? theme.hoverColor : Colors.transparent,
            borderRadius: BorderRadius.circular(_kRowRadius),
            child: InkWell(
              borderRadius: BorderRadius.circular(_kRowRadius),
              onTap: () => unawaited(_perform(_RuleAction.edit)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 5, 4, 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: _kLeadingSlot,
                      child: Icon(
                        !rule.enabled
                            ? PhosphorIconsRegular.bellSlash
                            : due
                            ? PhosphorIconsFill.bellRinging
                            : PhosphorIconsRegular.bell,
                        size: 18,
                        color: due
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: muted ? 0.5 : 1,
                              ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            rule.title.isEmpty ? '(untitled)' : rule.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted
                                  ? theme.colorScheme.onSurfaceVariant
                                  : null,
                            ),
                          ),
                          Text(
                            '${reminderCadenceLabel(rule)} · ${status.label}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: status.emphasized
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: status.emphasized
                                  ? FontWeight.w600
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    IgnorePointer(
                      ignoring: !(_hovered || isAndroid),
                      child: AnimatedOpacity(
                        opacity: _hovered || isAndroid ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        child: Builder(
                          builder: (buttonContext) => IconButton(
                            tooltip: 'More',
                            icon: const Icon(
                              PhosphorIconsRegular.dotsThree,
                              size: 16,
                            ),
                            padding: EdgeInsets.zero,
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            constraints: isAndroid
                                ? kMinTouchTarget
                                : const BoxConstraints.tightFor(
                                    width: 28,
                                    height: 28,
                                  ),
                            onPressed: () =>
                                unawaited(_openOverflow(buttonContext)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OverflowEntry extends StatelessWidget {
  const _OverflowEntry({required this.item, required this.onTap});

  final ContextMenuItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = item.isDestructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(item.icon, size: 16, color: color),
            const SizedBox(width: 10),
            Text(
              item.label,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// "[lead] 15 hours (Tomorrow 9:00 AM)" — the countdown to [at], with the
/// clock time after it only when [at] lands on another day. Today, the
/// countdown is the whole answer and the bracket only repeats the cadence.
String _countdown(String lead, DateTime at, DateTime now) {
  final local = at.toLocal();
  final today =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  final distance = reminderDistanceLabel(at, now);
  if (today) return '$lead $distance';
  return '$lead $distance (${reminderWhenLabel(at, now)})';
}

/// A rule's standing, for its Inbox row. [registeredDeviceIds] are the
/// devices not removed in Settings, when known.
({String label, bool emphasized}) scheduledRuleStatus(
  ScheduledReminderRule rule,
  ReminderSourceView? view,
  DateTime now, {
  Set<String>? registeredDeviceIds,
}) {
  final evaluation = view?.evaluation;
  if (!rule.enabled) {
    final completed =
        rule.scheduleKind == ReminderScheduleKind.once &&
        rule.onceLocalDate != null &&
        !atLocalMinutes(
          rule.onceLocalDate!,
          rule.localTimeMinutes,
        ).isAfter(now);
    return (label: completed ? 'Completed' : 'Off', emphasized: false);
  }
  // Aimed only at devices removed since, it fires nowhere until one is added
  // back, which read "Not on this device" like any rule for another device
  // (BUG-255).
  if (registeredDeviceIds != null &&
      rule.targetDeviceIds.isNotEmpty &&
      !rule.targetDeviceIds.any(registeredDeviceIds.contains)) {
    return (label: 'Its devices were removed', emphasized: true);
  }
  if (view != null && !view.targetsThisDevice) {
    return (label: 'Not on this device', emphasized: false);
  }
  if (evaluation == null) return (label: '', emphasized: false);
  switch (evaluation.phase) {
    case ReminderPhase.due:
      return (label: 'Due', emphasized: true);
    case ReminderPhase.snoozed:
      return (
        label: _countdown('Snoozed for', evaluation.snoozeUntil!, now),
        emphasized: false,
      );
    case ReminderPhase.pending:
    case ReminderPhase.acked:
      final next = evaluation.nextFireAt;
      if (next == null) return (label: 'Passed', emphasized: false);
      return (label: _countdown('Next in', next, now), emphasized: false);
  }
}

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

/// A new reminder's unsaved fields, kept when the editor closes without a
/// save, so the Inbox's dialog and the hotkey floater pick up where either
/// left off. A null field is one left as the form opened it: a fresh form
/// works those out again, since an untouched next-whole-hour kept as a draft
/// would reopen later pinned to an hour already gone.
class ScheduledReminderDraft {
  const ScheduledReminderDraft({
    this.title,
    this.body,
    this.kind,
    this.minutes,
    this.weekdays,
    this.onceDate,
    this.deviceIds,
    this.enabled,
  });

  final String? title;
  final String? body;
  final ReminderScheduleKind? kind;
  final int? minutes;
  final Set<int>? weekdays;
  final DateTime? onceDate;

  /// Null for all devices.
  final Set<String>? deviceIds;
  final bool? enabled;
}

/// Creates a scheduled reminder, or edits [existing]. [draft] prefills a new
/// one.
///
/// [onDraft] receives the unsaved fields when the editor closes without a
/// save (null when none moved off a fresh form's), and null once a save
/// starts.
Future<void> showScheduledReminderEditor(
  BuildContext context, {
  ScheduledReminderRule? existing,
  ScheduledReminderDraft? draft,
  ValueChanged<ScheduledReminderDraft?>? onDraft,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => _ScheduledReminderEditor(
      existing: existing,
      draft: draft,
      onDraft: onDraft,
    ),
  );
}

/// The editor without its dialog, for the reminder hotkey floater, which is
/// not a route: [onClose] stands in for the dialog's pop, from Cancel, the
/// close button and after a save alike, and [onSaved] runs in between once
/// the rule is written.
///
/// [leading] goes before the title. [onHeight] reports the form's height,
/// for the floater's window to be sized to it. [draft] and [onDraft] are as
/// for [showScheduledReminderEditor].
Widget scheduledReminderForm({
  required VoidCallback onClose,
  ScheduledReminderDraft? draft,
  VoidCallback? onSaved,
  ValueChanged<ScheduledReminderDraft?>? onDraft,
  Widget? leading,
  ValueChanged<double>? onHeight,
}) {
  return _ScheduledReminderEditor(
    draft: draft,
    onClose: onClose,
    onSaved: onSaved,
    onDraft: onDraft,
    leading: leading,
    onHeight: onHeight,
  );
}

class _ScheduledReminderEditor extends ConsumerStatefulWidget {
  const _ScheduledReminderEditor({
    this.existing,
    this.draft,
    this.onClose,
    this.onSaved,
    this.onDraft,
    this.leading,
    this.onHeight,
  });

  final ScheduledReminderRule? existing;

  /// See [showScheduledReminderEditor]. Ignored when editing [existing].
  final ScheduledReminderDraft? draft;

  /// See [scheduledReminderForm]. Null in the dialog, which pops instead.
  final VoidCallback? onClose;

  /// See [scheduledReminderForm].
  final VoidCallback? onSaved;

  /// See [showScheduledReminderEditor].
  final ValueChanged<ScheduledReminderDraft?>? onDraft;

  /// See [scheduledReminderForm].
  final Widget? leading;

  /// See [scheduledReminderForm]. Null in the dialog.
  final ValueChanged<double>? onHeight;

  @override
  ConsumerState<_ScheduledReminderEditor> createState() =>
      _ScheduledReminderEditorState();
}

class _ScheduledReminderEditorState
    extends ConsumerState<_ScheduledReminderEditor> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late ReminderScheduleKind _kind;
  late int _minutes;
  late Set<int> _weekdays;
  late DateTime _onceDate;
  late bool _allDevices;
  late Set<String> _deviceIds;
  late bool _enabled;
  String? _error;
  var _saving = false;

  /// What a fresh form opens with, for the draft to leave out.
  late final int _freshMinutes;
  late final DateTime _freshOnceDate;
  late final int _freshWeekday;

  /// Set once a save has written the rule, so closing keeps no draft of it.
  var _saved = false;

  /// Completes when the save in flight has finished, either way; null when no
  /// save is running.
  Future<void>? _saveSettled;

  @override
  void initState() {
    super.initState();
    final rule = widget.existing;
    final now = DateTime.now();
    // A new reminder starts on the next whole hour.
    _freshMinutes = ((now.hour + 1) % 24) * 60;
    _freshOnceDate = DateTime(
      now.year,
      now.month,
      now.day + (now.hour == 23 ? 1 : 0),
    );
    _freshWeekday = now.weekday;
    final draft = rule == null ? widget.draft : null;
    _title = TextEditingController(text: rule?.title ?? draft?.title ?? '');
    _body = TextEditingController(text: rule?.body ?? draft?.body ?? '');
    _kind = rule?.scheduleKind ?? draft?.kind ?? ReminderScheduleKind.once;
    _minutes = rule?.localTimeMinutes ?? draft?.minutes ?? _freshMinutes;
    _weekdays = {...?(rule?.weeklyWeekdays ?? draft?.weekdays)};
    if (_weekdays.isEmpty) _weekdays = {_freshWeekday};
    _onceDate = rule?.onceLocalDate ?? draft?.onceDate ?? _freshOnceDate;
    _allDevices = rule != null
        ? rule.targetDeviceIds.isEmpty
        : draft?.deviceIds == null;
    _deviceIds = {...?(rule?.targetDeviceIds ?? draft?.deviceIds)};
    _enabled = rule?.enabled ?? draft?.enabled ?? true;
    // A one-time draft's time can pass while it waits: it reopens on a fresh
    // form's time instead of one that can't be saved.
    if (draft != null &&
        _kind == ReminderScheduleKind.once &&
        atLocalMinutes(_onceDate, _minutes).isBefore(now)) {
      _minutes = _freshMinutes;
      _onceDate = _freshOnceDate;
    }
  }

  /// The form's fields that moved off a fresh form's, or null when none did.
  ScheduledReminderDraft? _unsavedDraft() {
    if (_saved) return null;
    final onceDate = DateTime(_onceDate.year, _onceDate.month, _onceDate.day);
    final draft = ScheduledReminderDraft(
      title: trimToNull(_title.text),
      body: trimToNull(_body.text),
      kind: _kind == ReminderScheduleKind.once ? null : _kind,
      minutes: _minutes == _freshMinutes ? null : _minutes,
      weekdays: _sameDays(_weekdays, {_freshWeekday}) ? null : {..._weekdays},
      onceDate: onceDate == _freshOnceDate ? null : onceDate,
      deviceIds: _allDevices ? null : {..._deviceIds},
      enabled: _enabled ? null : false,
    );
    if (draft.title == null &&
        draft.body == null &&
        draft.kind == null &&
        draft.minutes == null &&
        draft.weekdays == null &&
        draft.onceDate == null &&
        draft.deviceIds == null &&
        draft.enabled == null) {
      return null;
    }
    return draft;
  }

  @override
  void dispose() {
    final onDraft = widget.onDraft;
    final saveSettled = _saveSettled;
    if (onDraft != null && saveSettled != null) {
      // Closed while a save is in flight: the fields are a draft only if the
      // write fails.
      final draft = _unsavedDraft();
      unawaited(saveSettled.then((_) => onDraft(_saved ? null : draft)));
    } else {
      onDraft?.call(_unsavedDraft());
    }
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  DateTime get _timeAsDateTime => atLocalMinutes(DateTime.now(), _minutes);

  /// "Fires in 15 hours" for the schedule as the form has it — the Inbox
  /// row's countdown, before the rule exists. Null when there is nothing to
  /// count down to: a rule switched off, or a weekly one with no days yet.
  String? get _countdownLabel {
    if (!_enabled) return null;
    if (_kind == ReminderScheduleKind.weekly && _weekdays.isEmpty) return null;
    final now = DateTime.now();
    final next = _nextFireArmedAt(now);
    if (next == null) return 'That time has already passed';
    return 'Fires in ${reminderDistanceLabel(next, now)}';
  }

  /// When the schedule as the form has it next fires, for a rule armed at
  /// [now], whatever an existing rule was armed at. Null when it never does.
  DateTime? _nextFireArmedAt(DateTime now) {
    final draft = ScheduledReminderRule(
      id: '',
      createdAt: now,
      updatedAt: now,
      title: '',
      scheduleKind: _kind,
      localTimeMinutes: _minutes,
      weeklyWeekdays: _kind == ReminderScheduleKind.weekly
          ? _weekdays
          : const <int>{},
      onceLocalDate: _kind == ReminderScheduleKind.once
          ? DateTime(_onceDate.year, _onceDate.month, _onceDate.day)
          : null,
      armedAt: now,
    );
    return nextRuleFire(draft, now)?.fireAt;
  }

  /// The date picker's own size, in the dialog where there is room for it.
  static const _oncePickerSize = kDateTimeSelectorPopoverSize;

  Future<void> _pickTime(BuildContext buttonContext) async {
    if (_kind == ReminderScheduleKind.once) {
      // The hotkey floater's window is narrower than the picker wants, and
      // squeezed to fit it the quick-pick row wraps onto a second line —
      // which costs the calendar its last week of the month. Where the width
      // has to give, the height is taken back from the window, which has
      // nothing else on it to crowd.
      final viewport = MediaQuery.sizeOf(context);
      final narrowed = viewport.width - 16 < _oncePickerSize.width;
      final picked = (await showContextualPopover<DateTimePick>(
        context: context,
        buttonContext: buttonContext,
        width: _oncePickerSize.width,
        height: narrowed
            ? math.max(_oncePickerSize.height, viewport.height - 16)
            : _oncePickerSize.height,
        builder: (_) => DateTimeSelectorPopover(
          initialDateTime: atLocalMinutes(_onceDate, _minutes),
        ),
      ))?.dateTime;
      if (picked == null || !mounted) return;
      final local = picked.toLocal();
      setState(() {
        _onceDate = DateTime(local.year, local.month, local.day);
        _minutes = local.hour * 60 + local.minute;
        _error = null;
      });
      return;
    }
    final picked = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: buttonContext,
      width: 240,
      height: 300,
      builder: (_) => TimeSelectorPopover(initialTime: _timeAsDateTime),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _minutes = picked.hour * 60 + picked.minute;
      _error = null;
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give the reminder a title');
      return;
    }
    if (_kind == ReminderScheduleKind.weekly && _weekdays.isEmpty) {
      setState(() => _error = 'Pick at least one day');
      return;
    }
    // Removed devices have no chip, so ids left from them don't count.
    final registered = ref.read(deviceRegistrationsProvider).valueOrNull;
    if (!_allDevices &&
        (registered == null
            ? _deviceIds.isEmpty
            : !registered.any((device) => _deviceIds.contains(device.id)))) {
      setState(() => _error = 'Pick at least one device');
      return;
    }
    final existing = widget.existing;
    final onceDate = _kind == ReminderScheduleKind.once
        ? DateTime(_onceDate.year, _onceDate.month, _onceDate.day)
        : null;
    final weekdays = _kind == ReminderScheduleKind.weekly
        ? _weekdays
        : const <int>{};
    // A new time starts counting from now, as does a rule switched back on. A
    // rename leaves a due reminder due.
    final rearmed =
        existing == null ||
        existing.scheduleKind != _kind ||
        existing.localTimeMinutes != _minutes ||
        !_sameDays(existing.weeklyWeekdays, weekdays) ||
        existing.onceLocalDate != onceDate ||
        (!existing.enabled && _enabled);
    // Armed after its only time, a one-time reminder would never fire.
    if (_enabled && rearmed && _nextFireArmedAt(DateTime.now()) == null) {
      setState(() => _error = "Pick a time that hasn't passed yet");
      return;
    }
    if (_saving) return;
    _saving = true;

    final now = utcNow();
    final body = _body.text.trim();
    final targets = _allDevices ? const <String>[] : _deviceIds.toList();

    final ScheduledReminderRule rule;
    if (existing == null) {
      rule = ScheduledReminderRule(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        title: title,
        body: body.isEmpty ? null : body,
        enabled: _enabled,
        scheduleKind: _kind,
        localTimeMinutes: _minutes,
        weeklyWeekdays: weekdays,
        onceLocalDate: onceDate,
        targetDeviceIds: targets,
        armedAt: now,
      );
    } else {
      rule = existing.copyWith(
        title: title,
        body: body.isEmpty ? null : body,
        clearBody: body.isEmpty,
        enabled: _enabled,
        scheduleKind: _kind,
        localTimeMinutes: _minutes,
        weeklyWeekdays: weekdays,
        onceLocalDate: onceDate,
        clearOnceLocalDate: onceDate == null,
        targetDeviceIds: targets,
        armedAt: rearmed ? now : null,
        updatedAt: now,
        version: existing.version + 1,
      );
    }
    // Cleared up front, so a form opened while the write runs starts fresh; a
    // failed save hands the fields back when this form closes.
    widget.onDraft?.call(null);
    final settled = Completer<void>();
    _saveSettled = settled.future;
    try {
      await ref.read(reminderRepositoryProvider).upsertRule(rule);
      _saved = true;
    } finally {
      _saving = false;
      settled.complete();
    }
    ref.invalidate(scheduledReminderRulesProvider);
    unawaited(ref.read(reminderOsNotifierProvider).requestPermission());
    if (!mounted) return;
    ref.read(appSoundsProvider).play(AppSound.saved);
    widget.onSaved?.call();
    _close();
  }

  /// Wraps the floater's form in its height report.
  Widget _reportHeight(Widget child) {
    final onHeight = widget.onHeight;
    return onHeight == null
        ? child
        : ReportHeight(onHeight: onHeight, child: child);
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose == null) {
      Navigator.of(context).pop();
      return;
    }
    onClose();
  }

  static bool _sameDays(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existing = widget.existing;
    final loadedDevices = ref
        .watch(deviceRegistrationsProvider.settled)
        .valueOrNull;
    final devices = loadedDevices ?? const <DeviceRegistration>[];
    final thisDeviceId = ref.watch(deviceIdProvider);

    final timeLabel = _kind == ReminderScheduleKind.once
        ? '${DateFormat('EEE, MMM d').format(_onceDate)} at '
              '${formatTime12Hour(_timeAsDateTime)}'
        : formatTime12Hour(_timeAsDateTime);

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(text, style: theme.textTheme.labelLarge),
    );

    // The dialog's own padding is pulled in by [_kTogglePadding] and given
    // back to everything except the On row, whose hover fill is the one thing
    // meant to reach past the form — so its label can line up with the
    // headings above it without sitting against the fill's edge.
    final form = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kTogglePadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledTextField(
            label: 'Title',
            controller: _title,
            autofocus: existing == null,
            textInputAction: TextInputAction.next,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 12),
          LabeledTextField(
            label: 'Note (optional)',
            controller: _body,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => unawaited(_save()),
          ),
          label('Repeats'),
          SegmentedButton<ReminderScheduleKind>(
            segments: const [
              ButtonSegment(
                value: ReminderScheduleKind.once,
                label: Text('Once'),
              ),
              ButtonSegment(
                value: ReminderScheduleKind.daily,
                label: Text('Daily'),
              ),
              ButtonSegment(
                value: ReminderScheduleKind.weekly,
                label: Text('Weekly'),
              ),
            ],
            selected: {_kind},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => setState(() {
              _kind = selection.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 16),
          // The time, and for a weekly rule its days, share one row: the
          // pills say what they set, so a label above them only repeats it.
          Row(
            children: [
              Builder(
                builder: (buttonContext) => SelectorPill(
                  icon: PhosphorIconsRegular.clock,
                  label: timeLabel,
                  onTap: () => unawaited(_pickTime(buttonContext)),
                ),
              ),
              if (_kind == ReminderScheduleKind.weekly) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (
                        var day = DateTime.monday;
                        day <= DateTime.sunday;
                        day++
                      )
                        SelectorPill(
                          dense: true,
                          // 2024-01-01 was a Monday.
                          label: DateFormat.E().format(DateTime(2024, 1, day)),
                          isActive: _weekdays.contains(day),
                          fillWhenActive: true,
                          onTap: () => setState(() {
                            if (!_weekdays.remove(day)) {
                              _weekdays.add(day);
                            }
                            _error = null;
                          }),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (_countdownLabel case final countdown?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                countdown,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          label('Devices'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              SelectorPill(
                dense: true,
                label: 'All devices',
                isActive: _allDevices,
                fillWhenActive: true,
                onTap: () => setState(() {
                  _allDevices = true;
                  _error = null;
                }),
              ),
              for (final device in devices)
                SelectorPill(
                  dense: true,
                  label: device.id == thisDeviceId
                      ? '${device.displayName} (this device)'
                      : device.displayName,
                  isActive: !_allDevices && _deviceIds.contains(device.id),
                  fillWhenActive: true,
                  onTap: () => setState(() {
                    if (_allDevices) {
                      _allDevices = false;
                      _deviceIds = {device.id};
                    } else if (!_deviceIds.remove(device.id)) {
                      _deviceIds.add(device.id);
                    }
                    _error = null;
                  }),
                ),
            ],
          ),
          // Not while the list loads: shown for the frames before it
          // arrives, the line made the floater's window jump.
          if (loadedDevices != null && loadedDevices.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Devices appear here once they have signed in.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
    final footer = [
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: _kTogglePadding),
        title: const Text('On'),
        value: _enabled,
        onChanged: (value) => setState(() {
          _enabled = value;
          _error = null;
        }),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _kTogglePadding),
          child: Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
    ];

    final actions = [
      if (existing != null)
        GlassButton(
          dense: true,
          label: 'History',
          onPressed: () => unawaited(
            showReminderHistoryDialog(
              context,
              sourceKey: reminderSourceKey(
                ReminderSourceKind.scheduledRule,
                existing.id,
              ),
              title: existing.title,
            ),
          ),
        ),
      GlassButton(dense: true, label: 'Cancel', onPressed: _close),
      GlassButton(
        dense: true,
        label: existing == null ? 'Create' : 'Save',
        onPressed: () => unawaited(_save()),
      ),
    ];

    final Widget body;
    if (widget.onClose == null) {
      // In a window too short for the form only the form scrolls: the On row
      // and the error stay above the buttons, where a scrolled-off switch
      // would give no sign it was there. Half of the top padding goes inside
      // the scroll view, which clips at the Title field's top: its floating
      // label rises that far above the field.
      body = AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(
          _kTogglePadding,
          8,
          _kTogglePadding,
          24,
        ),
        title: Text(existing == null ? 'New reminder' : 'Edit reminder'),
        content: SizedBox(
          width: kReminderFormWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: VoyagerScrollView(
                  padding: const EdgeInsets.only(top: 8),
                  child: form,
                ),
              ),
              ...footer,
            ],
          ),
        ),
        actions: actions,
      );
    } else {
      // The floater window is the dialog's surface: same form at the same
      // width, with the title row and the actions the dialog draws for it
      // laid out flush to the window instead. The window is sized to the
      // form through [onHeight]; it only scrolls when the form outgrows the
      // screen.
      body = VoyagerScrollView(
        child: _reportHeight(
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _kTogglePadding,
              8,
              _kTogglePadding,
              14,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _kTogglePadding,
                  ),
                  child: Row(
                    children: [
                      if (widget.leading case final leading?) ...[
                        leading,
                        const SizedBox(width: 8),
                      ],
                      Text('New reminder', style: theme.textTheme.titleMedium),
                      const Spacer(),
                      IconButton(
                        onPressed: _close,
                        icon: const Icon(PhosphorIconsRegular.x, size: 18),
                        tooltip: 'Close',
                        padding: EdgeInsets.zero,
                        constraints: kMinTouchTarget,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 7),
                form,
                ...footer,
                Padding(
                  padding: const EdgeInsets.fromLTRB(_kTogglePadding, 8, 0, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (final action in actions)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: action,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return CtrlEnterToSubmitScope(
      onSubmit: () => unawaited(_save()),
      child: body,
    );
  }
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

/// A reminder source's firings, acknowledgements and snoozes, newest first
/// (§4.6) — for working out what happened on which device.
Future<void> showReminderHistoryDialog(
  BuildContext context, {
  required String sourceKey,
  required String title,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => _ReminderHistoryDialog(sourceKey: sourceKey, title: title),
  );
}

class _ReminderHistoryDialog extends ConsumerWidget {
  const _ReminderHistoryDialog({required this.sourceKey, required this.title});

  final String sourceKey;
  final String title;

  static String _eventLabel(ReminderLogEvent event) => switch (event) {
    ReminderLogEvent.osFired => 'Notification shown',
    ReminderLogEvent.stickyShown => 'Sticky shown',
    ReminderLogEvent.acked => 'Acknowledged',
    ReminderLogEvent.snoozed10m => 'Snoozed 10 min',
    ReminderLogEvent.snoozedTomorrow => 'Snoozed until tomorrow',
    ReminderLogEvent.supersededByNatural => 'Replaced by the next occurrence',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final logs = ref.watch(reminderLogsProvider(sourceKey).settled);
    final devices = {
      for (final device
          in ref.watch(deviceRegistrationsProvider.settled).valueOrNull ??
              const <DeviceRegistration>[])
        device.id: device.displayName,
    };
    final dateFormat = DateFormat('MMM d, h:mm a');

    return AlertDialog(
      title: Text('History · $title'),
      content: SizedBox(
        width: 460,
        height: 360,
        child: logs.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Text('Could not load history: $error'),
          data: (entries) {
            if (entries.isEmpty) {
              return Center(
                child: Text(
                  'Nothing has happened yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            }
            return ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final detail = [
                  devices[entry.deviceId] ?? 'Unknown device',
                  if (entry.occurrenceKey.isNotEmpty)
                    'for ${entry.occurrenceKey.replaceFirst('T', ' ')}',
                  // Those two carry the appearance's instance tag, which is
                  // bookkeeping rather than something to read.
                  if (entry.detail case final detail?
                      when entry.eventType != ReminderLogEvent.osFired &&
                          entry.eventType != ReminderLogEvent.stickyShown)
                    detail,
                ].join(' · ');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          dateFormat.format(entry.at.toLocal()),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _eventLabel(entry.eventType),
                              style: theme.textTheme.bodySmall,
                            ),
                            Text(
                              detail,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
