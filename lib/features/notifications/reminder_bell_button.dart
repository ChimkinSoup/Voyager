import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/reminders/reminder_labels.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// The lead-time presets a bell offers (`SCHEDULED_REMINDERS_HLD.md` §6.3), in
/// minutes before the task's or event's time.
const List<int> kReminderOffsetPresets = [0, 15, 60, 24 * 60];

/// The bell's offset for [entityId], or null while it is off.
int? entityReminderOffset(
  List<EntityReminder> reminders,
  ReminderSourceKind kind,
  String entityId,
) {
  final id = reminderSourceKey(kind, entityId);
  for (final reminder in reminders) {
    if (reminder.id != id) continue;
    return reminder.enabled && reminder.deletedAt == null
        ? reminder.offsetMinutes
        : null;
  }
  return null;
}

/// Turns [entityId]'s bell on at [offsetMinutes] before its time, or off when
/// that is null. Returns whether anything was written.
///
/// Off is a switch rather than a delete, so the offset last used is there to
/// read back. Turning it on, or moving the offset, re-arms it from now: an
/// occurrence that has already passed is not owed an alert.
Future<bool> setEntityReminder(
  ReminderRepository repository, {
  required ReminderSourceKind kind,
  required String entityId,
  required int? offsetMinutes,
}) async {
  final id = reminderSourceKey(kind, entityId);
  final existing = await repository.getEntityReminder(id);
  final now = utcNow();
  if (offsetMinutes == null) {
    if (existing == null || !existing.enabled) return false;
    await repository.upsertEntityReminder(
      existing.copyWith(
        enabled: false,
        updatedAt: now,
        version: existing.version + 1,
      ),
    );
    return true;
  }
  if (existing == null) {
    await repository.upsertEntityReminder(
      EntityReminder(
        id: id,
        createdAt: now,
        updatedAt: now,
        sourceKind: kind,
        entityId: entityId,
        enabled: true,
        offsetMinutes: offsetMinutes,
        armedAt: now,
      ),
    );
    return true;
  }
  if (existing.enabled && existing.offsetMinutes == offsetMinutes) return false;
  await repository.upsertEntityReminder(
    existing.copyWith(
      enabled: true,
      offsetMinutes: offsetMinutes,
      armedAt: now,
      updatedAt: now,
      version: existing.version + 1,
    ),
  );
  return true;
}

/// A bell toggle for a form row, beside the repeat button: dim until a
/// reminder is set, then in the accent, like [RepeatIconButton].
class ReminderBellButton extends StatelessWidget {
  const ReminderBellButton({
    super.key,
    required this.offsetMinutes,
    required this.onChanged,
    this.accentColor,
    this.enabled = true,
    this.disabledTooltip,
    this.onOpenChanged,
  });

  /// Null while the bell is off.
  final int? offsetMinutes;
  final ValueChanged<int?> onChanged;
  final Color? accentColor;
  final bool enabled;
  final String? disabledTooltip;

  /// Told when the picker opens and closes, for a panel whose Enter-to-save
  /// must not fire underneath an open popover.
  final ValueChanged<bool>? onOpenChanged;

  Future<void> _pick(BuildContext buttonContext) async {
    onOpenChanged?.call(true);
    final choice = await showContextualPopover<_BellChoice>(
      context: buttonContext,
      buttonContext: buttonContext,
      width: 220,
      accentColor: accentColor,
      builder: (_) => _ReminderOffsetPopover(current: offsetMinutes),
    );
    if (!buttonContext.mounted) {
      onOpenChanged?.call(false);
      return;
    }
    switch (choice) {
      case null:
        break;
      case _BellOff():
        onChanged(null);
      case _BellPreset(:final minutes):
        onChanged(minutes);
      case _BellCustom():
        final minutes = await _showCustomOffsetDialog(
          buttonContext,
          initialMinutes: offsetMinutes ?? 30,
        );
        if (minutes != null) onChanged(minutes);
    }
    onOpenChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;
    final on = offsetMinutes != null && enabled;
    return Builder(
      builder: (buttonContext) => IconButton(
        onPressed: enabled ? () => unawaited(_pick(buttonContext)) : null,
        tooltip: !enabled
            ? (disabledTooltip ?? 'Reminder')
            : on
            ? 'Reminder: ${reminderOffsetLabel(offsetMinutes!).toLowerCase()}'
            : 'Reminder',
        padding: EdgeInsets.zero,
        constraints: kMinTouchTarget,
        icon: Icon(
          on ? PhosphorIconsFill.bell : PhosphorIconsRegular.bell,
          size: 18,
          color: on
              ? accent
              : theme.colorScheme.onSurface.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

sealed class _BellChoice {
  const _BellChoice();
}

class _BellOff extends _BellChoice {
  const _BellOff();
}

class _BellPreset extends _BellChoice {
  const _BellPreset(this.minutes);
  final int minutes;
}

class _BellCustom extends _BellChoice {
  const _BellCustom();
}

class _ReminderOffsetPopover extends StatelessWidget {
  const _ReminderOffsetPopover({required this.current});

  final int? current;

  @override
  Widget build(BuildContext context) {
    final isCustom =
        current != null && !kReminderOffsetPresets.contains(current);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OptionRow(
          label: 'No reminder',
          selected: current == null,
          onTap: () => Navigator.of(context).pop(const _BellOff()),
        ),
        for (final minutes in kReminderOffsetPresets)
          _OptionRow(
            label: reminderOffsetLabel(minutes),
            selected: current == minutes,
            onTap: () => Navigator.of(context).pop(_BellPreset(minutes)),
          ),
        _OptionRow(
          label: isCustom
              ? 'Custom: ${reminderOffsetLabel(current!).toLowerCase()}'
              : 'Custom…',
          selected: isCustom,
          onTap: () => Navigator.of(context).pop(const _BellCustom()),
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
            if (selected)
              Icon(
                PhosphorIconsRegular.check,
                size: 14,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

/// Days, hours and minutes before; null when cancelled.
Future<int?> _showCustomOffsetDialog(
  BuildContext context, {
  required int initialMinutes,
}) {
  return showVoyagerDialog<int>(
    context: context,
    builder: (_) => _CustomOffsetDialog(initialMinutes: initialMinutes),
  );
}

class _CustomOffsetDialog extends StatefulWidget {
  const _CustomOffsetDialog({required this.initialMinutes});

  final int initialMinutes;

  @override
  State<_CustomOffsetDialog> createState() => _CustomOffsetDialogState();
}

class _CustomOffsetDialogState extends State<_CustomOffsetDialog> {
  late final TextEditingController _days;
  late final TextEditingController _hours;
  late final TextEditingController _minutes;

  @override
  void initState() {
    super.initState();
    final total = widget.initialMinutes;
    _days = TextEditingController(text: '${total ~/ (24 * 60)}');
    _hours = TextEditingController(text: '${(total % (24 * 60)) ~/ 60}');
    _minutes = TextEditingController(text: '${total % 60}');
  }

  @override
  void dispose() {
    _days.dispose();
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  void _submit() {
    int read(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
    final total = read(_days) * 24 * 60 + read(_hours) * 60 + read(_minutes);
    Navigator.of(context).pop(total);
  }

  @override
  Widget build(BuildContext context) {
    Widget field(String label, TextEditingController controller) => Expanded(
      child: LabeledTextField(
        label: label,
        controller: controller,
        keyboardType: TextInputType.number,
        onSubmitted: (_) => _submit(),
      ),
    );

    final dialog = EnterToSubmitScope(
      onSubmit: _submit,
      child: AlertDialog(
        title: const Text('Remind me before'),
        content: SizedBox(
          width: 320,
          child: Row(
            children: [
              field('Days', _days),
              const SizedBox(width: 8),
              field('Hours', _hours),
              const SizedBox(width: 8),
              field('Minutes', _minutes),
            ],
          ),
        ),
        actions: [
          GlassButton(
            dense: true,
            label: 'Cancel',
            onPressed: () => Navigator.of(context).pop(),
          ),
          GlassButton(dense: true, label: 'Set', onPressed: _submit),
        ],
      ),
    );
    return CtrlEnterToSubmitScope(onSubmit: _submit, child: dialog);
  }
}
