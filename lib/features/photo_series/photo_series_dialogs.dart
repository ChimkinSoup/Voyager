import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/services/reminder_schedule.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';

/// What the series dialog was left with.
typedef PhotoSeriesForm = ({
  String name,
  TrackerCadence cadence,
  List<({String? id, String name})> angles,
  PhotoReminderSettings reminder,
  PhotoHideStyle hideStyle,
});

/// "Daily", "Weekly"…
String photoCadenceLabel(TrackerCadence cadence) => switch (cadence) {
  TrackerCadence.daily => 'Daily',
  TrackerCadence.weekly => 'Weekly',
  TrackerCadence.monthly => 'Monthly',
  TrackerCadence.yearly => 'Yearly',
};

/// Asks for a series' name, cadence, reminder, how its photos hide and its
/// angles: a new series with no
/// [series], or [series] with its [angles] to edit. Null when cancelled.
Future<PhotoSeriesForm?> showPhotoSeriesDialog(
  BuildContext context, {
  PhotoSeries? series,
  List<PhotoSeriesAngle> angles = const [],
}) {
  return showVoyagerDialog<PhotoSeriesForm>(
    context: context,
    builder: (context) => _PhotoSeriesDialog(series: series, angles: angles),
  );
}

class _AngleDraft {
  _AngleDraft(this.id, String name)
    : controller = TextEditingController(text: name);

  final String? id;
  final TextEditingController controller;
}

class _PhotoSeriesDialog extends StatefulWidget {
  const _PhotoSeriesDialog({required this.series, required this.angles});

  final PhotoSeries? series;
  final List<PhotoSeriesAngle> angles;

  @override
  State<_PhotoSeriesDialog> createState() => _PhotoSeriesDialogState();
}

class _PhotoSeriesDialogState extends State<_PhotoSeriesDialog> {
  late final _name = TextEditingController(text: widget.series?.name ?? '');
  final _nameFocus = FocusNode();
  late var _cadence = widget.series?.cadence ?? TrackerCadence.weekly;
  late final _angles = widget.angles.isEmpty
      ? [_AngleDraft(null, kDefaultPhotoAngleName)]
      : [for (final angle in widget.angles) _AngleDraft(angle.id, angle.name)];
  late var _remind = widget.series?.reminderEnabled ?? true;
  late var _minutes = widget.series?.reminderMinutes ?? 9 * 60;
  late var _weekday = widget.series?.reminderWeekday ?? DateTime.monday;
  late var _monthDay = widget.series?.reminderMonthDay ?? 1;
  late var _month = widget.series?.reminderMonth ?? DateTime.now().month;
  late var _hideStyle = widget.series?.hideStyle ?? PhotoHideStyle.blur;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    for (final angle in _angles) {
      angle.controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the series a name.');
      // The field's own submit (or the click on Create) took focus away.
      _nameFocus.requestFocus();
      return;
    }
    Navigator.pop<PhotoSeriesForm>(context, (
      name: name,
      cadence: _cadence,
      angles: [
        for (final angle in _angles)
          (id: angle.id, name: angle.controller.text.trim()),
      ],
      reminder: (
        enabled: _remind,
        minutes: _minutes,
        weekday: _weekday,
        monthDay: _monthDay,
        month: _month,
      ),
      hideStyle: _hideStyle,
    ));
  }

  Future<void> _pickTime(BuildContext buttonContext) async {
    final picked = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: buttonContext,
      width: 240,
      height: 300,
      builder: (_) => TimeSelectorPopover(
        initialTime: atLocalMinutes(DateTime.now(), _minutes),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _minutes = picked.hour * 60 + picked.minute);
  }

  /// The day the reminder falls on: a weekday, or a day of the month (and
  /// for a yearly series, a month). A daily series has none.
  Widget? _reminderDay(ThemeData theme) {
    switch (_cadence) {
      case TrackerCadence.daily:
        return null;
      case TrackerCadence.weekly:
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var day = DateTime.monday; day <= DateTime.sunday; day++)
              SelectorPill(
                dense: true,
                // 2024-01-01 was a Monday.
                label: DateFormat.E().format(DateTime(2024, 1, day)),
                isActive: _weekday == day,
                fillWhenActive: true,
                onTap: () => setState(() => _weekday = day),
              ),
          ],
        );
      case TrackerCadence.monthly:
      case TrackerCadence.yearly:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_cadence == TrackerCadence.yearly) ...[
                  Expanded(
                    key: const ValueKey('month'),
                    child: VoyagerDropdownButtonFormField<int>(
                      initialValue: _month,
                      decoration: const InputDecoration(
                        labelText: 'Month',
                        isDense: true,
                      ),
                      items: [
                        for (var month = 1; month <= 12; month++)
                          DropdownMenuItem(
                            value: month,
                            child: Text(
                              DateFormat.MMMM().format(DateTime(2024, month)),
                            ),
                          ),
                      ],
                      onChanged: (month) =>
                          setState(() => _month = month ?? _month),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  key: const ValueKey('day'),
                  child: VoyagerDropdownButtonFormField<int>(
                    initialValue: _monthDay,
                    decoration: const InputDecoration(
                      labelText: 'Day',
                      isDense: true,
                    ),
                    items: [
                      for (var day = 1; day <= 31; day++)
                        DropdownMenuItem(value: day, child: Text('$day')),
                    ],
                    onChanged: (day) =>
                        setState(() => _monthDay = day ?? _monthDay),
                  ),
                ),
              ],
            ),
            if (_monthDay > 28)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'In a shorter month, its last day.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        );
    }
  }

  void _move(int index, int by) {
    setState(() {
      final angle = _angles.removeAt(index);
      _angles.insert(index + by, angle);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.series != null;
    final removesPhotos =
        editing &&
        widget.angles.any(
          (angle) => !_angles.any((draft) => draft.id == angle.id),
        );
    return AlertDialog(
      title: Text(editing ? 'Edit series' : 'New photo series'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              VoyagerTextField(
                controller: _name,
                focusNode: _nameFocus,
                autofocus: !editing,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  isDense: true,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              Text('Every', style: theme.textTheme.labelMedium),
              const SizedBox(height: 6),
              SegmentedButton<TrackerCadence>(
                segments: [
                  for (final cadence in TrackerCadence.values)
                    ButtonSegment(
                      value: cadence,
                      label: Text(photoCadenceLabel(cadence)),
                    ),
                ],
                selected: {_cadence},
                showSelectedIcon: false,
                onSelectionChanged: (picked) =>
                    setState(() => _cadence = picked.single),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Remind me',
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  Switch(
                    value: _remind,
                    onChanged: (remind) => setState(() => _remind = remind),
                  ),
                ],
              ),
              if (_remind) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Builder(
                    builder: (buttonContext) => SelectorPill(
                      icon: PhosphorIconsRegular.clock,
                      label: formatTime12Hour(
                        atLocalMinutes(DateTime.now(), _minutes),
                      ),
                      onTap: () => unawaited(_pickTime(buttonContext)),
                    ),
                  ),
                ),
                if (_reminderDay(theme) case final day?) ...[
                  const SizedBox(height: 10),
                  day,
                ],
              ],
              const SizedBox(height: 16),
              // Either way, a click shows the photo (§7.1).
              Text('Hide photos as', style: theme.textTheme.labelMedium),
              const SizedBox(height: 6),
              SegmentedButton<PhotoHideStyle>(
                segments: const [
                  ButtonSegment(
                    value: PhotoHideStyle.blur,
                    label: Text('Blurred'),
                  ),
                  ButtonSegment(
                    value: PhotoHideStyle.blank,
                    label: Text('Blank'),
                  ),
                ],
                selected: {_hideStyle},
                showSelectedIcon: false,
                onSelectionChanged: (picked) =>
                    setState(() => _hideStyle = picked.single),
              ),
              const SizedBox(height: 16),
              Text('Angles', style: theme.textTheme.labelMedium),
              const SizedBox(height: 6),
              for (final (i, angle) in _angles.indexed)
                Padding(
                  key: ObjectKey(angle),
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: VoyagerTextField(
                          controller: angle.controller,
                          decoration: InputDecoration(
                            hintText: 'Angle ${i + 1}',
                            isDense: true,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Move up',
                        icon: const Icon(PhosphorIconsRegular.caretUp),
                        onPressed: i == 0 ? null : () => _move(i, -1),
                      ),
                      IconButton(
                        tooltip: 'Move down',
                        icon: const Icon(PhosphorIconsRegular.caretDown),
                        onPressed: i == _angles.length - 1
                            ? null
                            : () => _move(i, 1),
                      ),
                      // The last angle stays: a series needs one.
                      IconButton(
                        tooltip: 'Remove angle',
                        icon: const Icon(PhosphorIconsRegular.x),
                        onPressed: _angles.length == 1
                            ? null
                            : () => setState(() {
                                _angles.removeAt(i).controller.dispose();
                              }),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: GlassButton(
                  onPressed: () =>
                      setState(() => _angles.add(_AngleDraft(null, ''))),
                  icon: const Icon(PhosphorIconsRegular.plus, size: 13),
                  label: 'Add angle',
                  dense: true,
                ),
              ),
              if (removesPhotos)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    "A removed angle's photos go to the trash with it.",
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
          dense: true,
        ),
        GlassButton(
          onPressed: _submit,
          label: editing ? 'Save' : 'Create',
          dense: true,
        ),
      ],
    );
  }
}

/// Asks for a check-in's note, starting from [initial]. Null when cancelled;
/// empty clears the note.
Future<String?> showPhotoNoteDialog(BuildContext context, String initial) {
  return showVoyagerDialog<String>(
    context: context,
    builder: (context) => _NoteDialog(initial: initial),
  );
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initial});

  final String initial;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Note'),
      content: SizedBox(
        width: 380,
        child: VoyagerTextField(
          controller: _controller,
          autofocus: true,
          sensitive: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'Encrypted with your vault',
            isDense: true,
          ),
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
          dense: true,
        ),
        GlassButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          label: 'Save',
          dense: true,
        ),
      ],
    );
  }
}
