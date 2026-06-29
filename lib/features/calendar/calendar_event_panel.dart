import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';

/// Inline event add/edit panel for the calendar sidebar (no dialog).
class CalendarEventPanel extends StatefulWidget {
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
  State<CalendarEventPanel> createState() => _CalendarEventPanelState();
}

class _CalendarEventPanelState extends State<CalendarEventPanel> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final FocusNode _titleFocusNode;
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
    _colorValue = e?.colorValue ?? 0xFF7C9EFF;
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
      _colorValue = e?.colorValue ?? 0xFF7C9EFF;
      _recurrence = e?.recurrence ?? EventRecurrence.none;
      _titleError = null;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _titleFocusNode.dispose();
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
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
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
                        maxLines: 3,
                      ),
                      const SizedBox(height: 12),
                      ColorPickerField(
                        label: 'Event color',
                        value: _colorValue,
                        swatchRadius: 20,
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
