import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
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
  bool _isDatePopoverOpen = false;
  bool _isTimePopoverOpen = false;
  final _timePillKey = GlobalKey();

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
        _titleFocusNode.unfocus();
        if (!_isFullDay) {
          final timeContext = _timePillKey.currentContext;
          if (timeContext != null) {
            _openTimePopover(timeContext);
          }
        }
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

  Future<void> _openTimePopover(BuildContext buttonContext) async {
    setState(() => _isTimePopoverOpen = true);
    final result = await showContextualPopover<DateTimeRange>(
      context: context,
      buttonContext: buttonContext,
      width: 360, // Wider to fit two spinners
      accentColor: Color(_colorValue),
      builder: (ctx) => TimeRangePopover(
        initialStart: _start,
        initialEnd: _end,
        onChanged: (DateTimeRange range) {
          setState(() {
            _start = range.start;
            _end = range.end;
          });
        },
      ),
    );
    setState(() => _isTimePopoverOpen = false);
    if (result != null) {
      setState(() {
        _start = result.start;
        _end = result.end;
      });
    }
    // After closing the time popover, ensure nothing has focus
    // so EnterToSubmitScope can catch the next Enter keypress.
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.event != null;
    final accent = Color(_colorValue);
    final baseTheme = Theme.of(context);
    final eventTheme = baseTheme.copyWith(
      colorScheme: baseTheme.colorScheme.copyWith(primary: accent),
      popupMenuTheme: VoyagerMenuTheme.popupMenuTheme(
        textTheme: baseTheme.textTheme,
        onSurface: baseTheme.colorScheme.onSurface,
        accentColor: accent,
      ),
      menuTheme: VoyagerMenuTheme.menuTheme(accentColor: accent),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return accent;
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accent.withValues(alpha: 0.45);
          }
          return null;
        }),
      ),
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        floatingLabelStyle:
            baseTheme.textTheme.labelLarge?.copyWith(color: accent),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: accent.withValues(alpha: 0.95),
            width: 1.8,
          ),
        ),
      ),
    );
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    final card = Card(
      margin: EdgeInsets.zero,
      shape: isEditing
          ? cardShape.copyWith(
              side: BorderSide(
                color: Color(_colorValue).withValues(alpha: 0.6),
                width: 3,
              ),
            )
          : cardShape,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Theme(
          data: eventTheme,
          child: EnterToSubmitScope(
            onSubmit: _submit,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    onPressed: widget.onCancel,
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 14),
                        LabeledTextField(
                          label: 'Title',
                          controller: _titleController,
                          focusNode: _titleFocusNode,
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          accentColor: accent,
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
                              color: baseTheme.colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            // Date
                            Builder(
                              builder: (buttonContext) {
                                final isMultiDay = _start.year != _end.year ||
                                    _start.month != _end.month ||
                                    _start.day != _end.day;
                                final dateFormat = isMultiDay
                                    ? DateFormat('MMM d')
                                    : DateFormat('EEE, MMM d');
                                final label = isMultiDay
                                    ? '${dateFormat.format(_start)} -> ${dateFormat.format(_end)}'
                                    : dateFormat.format(_start);

                                return SelectorPill(
                                  isActive: _isDatePopoverOpen,
                                  label: label,
                                  accentColor: accent,
                                  onTap: () async {
                                  setState(() => _isDatePopoverOpen = true);
                                  final dateRange =
                                      await showContextualPopover<DateTimeRange>(
                                    context: context,
                                    buttonContext: buttonContext,
                                    width: 320,
                                    height: 380,
                                    accentColor: accent,
                                    builder: (ctx) => DateSelectorPopover(
                                      initialStartDate: _start,
                                      initialEndDate: _end,
                                    ),
                                  );
                                  setState(() => _isDatePopoverOpen = false);
                                  if (dateRange != null) {
                                    setState(() {
                                      _start = DateTime(
                                        dateRange.start.year,
                                        dateRange.start.month,
                                        dateRange.start.day,
                                        _start.hour,
                                        _start.minute,
                                      );
                                      _end = DateTime(
                                        dateRange.end.year,
                                        dateRange.end.month,
                                        dateRange.end.day,
                                        _end.hour,
                                        _end.minute,
                                      );
                                    });
                                  }
                                },
                              );
                            },
                          ),
                          if (!_isFullDay) ...[
                            const SizedBox(width: 8),
                            // Combined time range pill
                            Builder(
                              key: _timePillKey,
                              builder: (buttonContext) => SelectorPill(
                                isActive: _isTimePopoverOpen,
                                accentColor: accent,
                                onTap: () => _openTimePopover(buttonContext),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      TimeOfDay.fromDateTime(_start)
                                          .format(context),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: Icon(
                                        Icons.arrow_forward,
                                        size: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                    Text(
                                      TimeOfDay.fromDateTime(_end)
                                          .format(context),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
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
                      Padding(
                        // Match SelectorPill horizontal inset so "All day" aligns with date text.
                        padding: const EdgeInsets.only(left: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('All day'),
                            const SizedBox(width: 12),
                            Switch(
                              value: _isFullDay,
                              onChanged: (v) => setState(() => _isFullDay = v),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      VoyagerDropdownButtonFormField<EventRecurrence>(
                        decoration: const InputDecoration(labelText: 'Repeat'),
                        initialValue: _recurrence,
                        accentColor: accent,
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
                        accentColor: accent,
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
      ),
    );

    if (!isEditing) return card;

    final glowColor = Color(_colorValue).withValues(alpha: 0.6);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: glowColor,
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      child: card,
    );
  }
}
