import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
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
    _colorValue = e?.colorValue ?? 0;
    _recurrence = e?.recurrence ?? EventRecurrence.none;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _titleFocusNode.requestFocus();
    });
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
    if (_colorValue == 0) {
      _colorValue = Theme.of(context).colorScheme.primary.toARGB32();
    }
    
    return EnterToSubmitScope(
      onSubmit: _submit,
      child: AlertDialog(
      title: Text(widget.event == null ? 'New event' : 'Edit event'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Full day'),
              value: _isFullDay,
              onChanged: (v) => setState(() => _isFullDay = v),
            ),
            const SizedBox(height: 16),
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
            const SizedBox(height: 16),
            LabeledTextField(
              label: 'Notes',
              controller: _notesController,
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            ColorPickerField(
              label: 'Event color',
              value: _colorValue,
              swatchRadius: 24,
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
    ),
    );
  }
}
