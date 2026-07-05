import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';

/// Inline event add/edit panel for the calendar sidebar (no dialog).
class CalendarEventPanel extends ConsumerStatefulWidget {
  const CalendarEventPanel({
    super.key,
    this.event,
    required this.initialDate,
    required this.onSave,
    required this.onCancel,
  });

  final CalendarEvent? event;
  final DateTime initialDate;
  final ValueChanged<Map<String, dynamic>> onSave;
  final VoidCallback onCancel;

  @override
  ConsumerState<CalendarEventPanel> createState() => _CalendarEventPanelState();
}

class _CalendarEventPanelState extends ConsumerState<CalendarEventPanel> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _notesFocusNode;
  late bool _isFullDay;
  late DateTime _start;
  late DateTime _end;
  late int _colorValue;
  late EventRecurrence _recurrence;
  String? _titleError;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _titleController = TextEditingController(text: e?.title ?? '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    _titleFocusNode = FocusNode();
    _titleFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _notesFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _notesFocusNode = FocusNode();
    // Notes is the last text field: Enter saves, Shift+Enter inserts a newline.
    _notesFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _submit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _isFullDay = e?.isFullDay ?? false;
    _start = e?.start ??
        DateTime(
          widget.initialDate.year,
          widget.initialDate.month,
          widget.initialDate.day,
          widget.initialDate.hour,
          widget.initialDate.minute,
        );
    _end = e?.end ?? _start.add(const Duration(hours: 1));
    final settings = ref.read(settingsProvider).valueOrNull;
    _colorValue = e?.colorValue ?? (settings?.accentColor ?? 0xFF7C9EFF);
    _recurrence = e?.recurrence ?? EventRecurrence.none;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _titleFocusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant CalendarEventPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event?.id != widget.event?.id ||
        oldWidget.initialDate != widget.initialDate) {
      final e = widget.event;
      _titleController.text = e?.title ?? '';
      _notesController.text = e?.notes ?? '';
      _isFullDay = e?.isFullDay ?? false;
      _start = e?.start ??
          DateTime(
            widget.initialDate.year,
            widget.initialDate.month,
            widget.initialDate.day,
            widget.initialDate.hour,
            widget.initialDate.minute,
          );
      _end = e?.end ?? _start.add(const Duration(hours: 1));
      final settings = ref.read(settingsProvider).valueOrNull;
      _colorValue = e?.colorValue ?? (settings?.accentColor ?? 0xFF7C9EFF);
      _recurrence = e?.recurrence ?? EventRecurrence.none;
      _titleError = null;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _titleFocusNode.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = 'Title cannot be empty');
      _titleFocusNode.requestFocus();
      return;
    }
    widget.onSave({
      'title': title,
      'notes': _notesController.text.trim(),
      'isFullDay': _isFullDay,
      'start': _start,
      'end': _end,
      'colorValue': _colorValue,
      'recurrence': _recurrence,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: EnterToSubmitScope(
          onSubmit: _submit,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.event == null ? 'New event' : 'Edit event',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onCancel,
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LabeledTextField(
                        label: 'Title',
                        controller: _titleController,
                        focusNode: _titleFocusNode,
                        autofocus: true,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        onChanged: (_) {
                          if (_titleError != null) {
                            setState(() => _titleError = null);
                          }
                        },
                      ),
                      if (_titleError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _titleError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12.0),
                        child: Wrap(
                          spacing: 4.0,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            // Date
                            Builder(
                              builder: (buttonContext) => SelectorPill(
                                label: DateFormat('EEE, MMM d').format(_start),
                                onTap: () async {
                                  final date =
                                      await showContextualPopover<DateTime>(
                                    context: context,
                                    buttonContext: buttonContext,
                                    height: 380, // Taller for date picker
                                    builder: (ctx) => DateSelectorPopover(
                                      initialDate: _start,
                                      // onAddEndDate: () {}, // Not fully implemented in smart row yet
                                    ),
                                  );
                                  if (date != null) {
                                    setState(() {
                                      _start = DateTime(
                                        date.year,
                                        date.month,
                                        date.day,
                                        _start.hour,
                                        _start.minute,
                                      );
                                      _end = DateTime(
                                        date.year,
                                        date.month,
                                        date.day,
                                        _end.hour,
                                        _end.minute,
                                      );
                                    });
                                  }
                                },
                              ),
                            ),
                            if (!_isFullDay) ...[
                              const SizedBox(width: 12),
                              // Combined Time Range Pill
                              Builder(
                                builder: (buttonContext) => SelectorPill(
                                  onTap: () async {
                                    final result = await showContextualPopover<TimeRangeResult>(
                                      context: context,
                                      buttonContext: buttonContext,
                                      width: 360, // Wider to fit two spinners
                                      builder: (ctx) => TimeRangePopover(
                                        initialStart: TimeOfDay.fromDateTime(_start),
                                        initialEnd: TimeOfDay.fromDateTime(_end),
                                      ),
                                    );
                                    if (result != null) {
                                      setState(() {
                                        _start = DateTime(
                                          _start.year,
                                          _start.month,
                                          _start.day,
                                          result.start.hour,
                                          result.start.minute,
                                        );
                                        _end = DateTime(
                                          _end.year,
                                          _end.month,
                                          _end.day,
                                          result.end.hour,
                                          result.end.minute,
                                        );
                                        // Auto-adjust end date if duration goes past midnight
                                        if (_end.isBefore(_start)) {
                                          _end = _end.add(const Duration(days: 1));
                                        }
                                      });
                                    }
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        TimeOfDay.fromDateTime(_start).format(context),
                                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                              color: Theme.of(context).colorScheme.onSurface,
                                              fontWeight: FontWeight.w500,
                                            ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4.0),
                                        child: Icon(Icons.arrow_forward,
                                            size: 14,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.5)),
                                      ),
                                      Text(
                                        TimeOfDay.fromDateTime(_end).format(context),
                                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                              color: Theme.of(context).colorScheme.onSurface,
                                              fontWeight: FontWeight.w500,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      SwitchListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12.0),
                        title: const Text('All day'),
                        value: _isFullDay,
                        onChanged: (v) => setState(() => _isFullDay = v),
                      ),
                      const SizedBox(height: 8),
                      VoyagerDropdownButtonFormField<EventRecurrence>(
                        decoration: const InputDecoration(labelText: 'Repeat'),
                        initialValue: _recurrence,
                        items: EventRecurrence.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(recurrenceLabel(value)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _recurrence = value);
                        },
                      ),
                      const SizedBox(height: 12),
                      LabeledTextField(
                        label: 'Notes',
                        controller: _notesController,
                        focusNode: _notesFocusNode,
                        maxLines: 3,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                      ),
                      const SizedBox(height: 12),
                      ColorPickerField(
                        label: 'Event color',
                        value: _colorValue,
                        swatchRadius: 20,
                        maxHeight: 160,
                        onChanged: (value) => setState(() => _colorValue = value),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _submit,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
