import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';

class EventEditorDialog extends StatefulWidget {
  const EventEditorDialog({super.key, this.event, required this.initialDate});

  final CalendarEvent? event;
  final DateTime initialDate;

  @override
  State<EventEditorDialog> createState() => _EventEditorDialogState();
}

class _EventEditorDialogState extends State<EventEditorDialog> {
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
    _isFullDay = e?.isFullDay ?? true;
    _start =
        e?.start ??
        DateTime(
          widget.initialDate.year,
          widget.initialDate.month,
          widget.initialDate.day,
        );
    _end =
        e?.end ??
        DateTime(
          widget.initialDate.year,
          widget.initialDate.month,
          widget.initialDate.day,
          23,
          59,
        );
    _colorValue = e?.colorValue ?? 0xFF7C9EFF;
    _recurrence = e?.recurrence ?? EventRecurrence.none;
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
      return;
    }
    Navigator.pop(context, {
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
    return AlertDialog(
      title: Text(widget.event == null ? 'New event' : 'Edit event'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LabeledTextField(
              label: 'Title',
              controller: _titleController,
              focusNode: _titleFocusNode,
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
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _titleError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Full day'),
              value: _isFullDay,
              onChanged: (v) => setState(() => _isFullDay = v),
            ),
            DropdownButtonFormField<EventRecurrence>(
              initialValue: _recurrence,
              decoration: const InputDecoration(labelText: 'Repeat'),
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
            const SizedBox(height: 8),
            LabeledTextField(
              label: 'Notes',
              controller: _notesController,
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            ColorPickerField(
              label: 'Event color',
              value: _colorValue,
              onChanged: (value) => setState(() => _colorValue = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
