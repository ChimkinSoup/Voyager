import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/domain/models/calendar_models.dart';

/// Inline event add/edit panel for the calendar sidebar (no dialog).
class CalendarEventPanel extends ConsumerStatefulWidget {
  const CalendarEventPanel({
    super.key,
    this.event,
    required this.initialDate,
    required this.calendars,
    required this.initialCalendarId,
    required this.onSave,
    required this.onCancel,
    this.focusTitleOnOpen = false,
  });

  final CalendarEvent? event;
  final DateTime initialDate;
  final List<Calendar> calendars;
  final String initialCalendarId;
  final ValueChanged<Map<String, dynamic>> onSave;
  final VoidCallback onCancel;
  final bool focusTitleOnOpen;

  @override
  ConsumerState<CalendarEventPanel> createState() => _CalendarEventPanelState();
}

class _CalendarEventPanelState extends ConsumerState<CalendarEventPanel> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _notesFocusNode;
  var _lastNotesText = '';
  late bool _isFullDay;
  late DateTime _start;
  late DateTime _end;
  late int _colorValue;
  late EventRecurrence _recurrence;
  late String _calendarId;
  String? _titleError;
  bool _isDatePopoverOpen = false;
  bool _isTimePopoverOpen = false;
  bool _intentionalDiscard = false;
  bool _closingAfterSave = false;
  final _timePillKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _titleController = TextEditingController(text: e?.title ?? '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    _lastNotesText = _notesController.text;
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
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        final outdent = HardwareKeyboard.instance.isShiftPressed;
        if (handleListTab(controller: _notesController, outdent: outdent)) {
          // Keep _lastNotesText in sync for the next keystroke's diff.
          _handleNotesChanged(_notesController.text);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        if (handleListBackspace(controller: _notesController)) {
          _handleNotesChanged(_notesController.text);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        if (isOnListLine(_notesController)) {
          // Let the newline through so list-continuation/clean-exit (wired
          // via onChanged) handles it, instead of submitting.
          return KeyEventResult.ignored;
        }
        _submit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _isFullDay = e?.isFullDay ?? true;
    _start = e?.start ??
        DateTime(
          widget.initialDate.year,
          widget.initialDate.month,
          widget.initialDate.day,
          widget.initialDate.hour,
          widget.initialDate.minute,
        );
    _end = e?.end ?? _start.add(const Duration(hours: 1));
    _calendarId = e?.calendarId ?? widget.initialCalendarId;
    _colorValue = e?.colorValue ?? _defaultEventColor(_calendarId);
    _recurrence = e?.recurrence ?? EventRecurrence.none;
    _scheduleTitleFocusIfNeeded();
  }

  /// Default color for a new event: the color of the calendar it's being
  /// created in, falling back to the accent color if that calendar has none.
  int _defaultEventColor(String calendarId) {
    final calendar = widget.calendars
        .where((c) => c.id == calendarId)
        .firstOrNull;
    final settings = ref.read(settingsProvider).valueOrNull;
    return calendar?.colorValue ?? settings?.accentColor ?? 0xFF7C9EFF;
  }

  void _scheduleTitleFocusIfNeeded() {
    if (!widget.focusTitleOnOpen) return;
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
      _lastNotesText = _notesController.text;
      _isFullDay = e?.isFullDay ?? true;
      _start = e?.start ??
          DateTime(
            widget.initialDate.year,
            widget.initialDate.month,
            widget.initialDate.day,
            widget.initialDate.hour,
            widget.initialDate.minute,
          );
      _end = e?.end ?? _start.add(const Duration(hours: 1));
      _calendarId = e?.calendarId ?? widget.initialCalendarId;
      _colorValue = e?.colorValue ?? _defaultEventColor(_calendarId);
      _recurrence = e?.recurrence ?? EventRecurrence.none;
      _titleError = null;
    }
    if (widget.focusTitleOnOpen && !oldWidget.focusTitleOnOpen) {
      _scheduleTitleFocusIfNeeded();
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

  void _handleNotesChanged(String value) {
    applyListEditing(controller: _notesController, previousText: _lastNotesText);
    _lastNotesText = _notesController.text;
  }

  Map<String, dynamic> _buildPayload(String title) => {
        'title': title,
        'notes': _notesController.text.trim(),
        'isFullDay': _isFullDay,
        'start': _start,
        'end': _end,
        'colorValue': _colorValue,
        'recurrence': _recurrence,
        'calendarId': _calendarId,
      };

  /// Returns true when the form is valid and [onSave] was called.
  bool _trySave({bool showValidationErrors = true}) {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      if (showValidationErrors) {
        setState(() => _titleError = 'Title cannot be empty');
        _titleFocusNode.requestFocus();
      }
      return false;
    }
    _closingAfterSave = true;
    widget.onSave(_buildPayload(title));
    return true;
  }

  void _submit() {
    _trySave();
  }

  void _discard() {
    _intentionalDiscard = true;
    Navigator.of(context).pop();
  }

  void _handleDismissPop() {
    if (_intentionalDiscard || _closingAfterSave) {
      Navigator.of(context).pop();
      return;
    }

    // Clicking outside the popup saves valid edits; invalid forms are discarded.
    if (!_trySave(showValidationErrors: false)) {
      Navigator.of(context).pop();
    }
  }

  int _calendarFlagColor(Calendar calendar) =>
      calendar.colorValue ?? Theme.of(context).colorScheme.primary.toARGB32();

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
    final accent = Color(_colorValue);
    final baseTheme = Theme.of(context);
    final eventTheme = baseTheme.copyWith(
      colorScheme: baseTheme.colorScheme.copyWith(primary: accent),
      popupMenuTheme: VoyagerMenuTheme.popupMenuTheme(
        textTheme: baseTheme.textTheme,
        onSurface: baseTheme.colorScheme.onSurface,
        accentColor: accent,
        color: baseTheme.popupMenuTheme.color,
      ),
      menuTheme: VoyagerMenuTheme.menuTheme(
        accentColor: accent,
        color: baseTheme.popupMenuTheme.color,
      ),
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
    final panel = Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Theme(
        data: eventTheme,
        child: EnterToSubmitScope(
          onSubmit: _submit,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 14),
              // ── Row 1: title + all-day icon ───────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        LabeledTextField(
                          label: 'Title',
                          controller: _titleController,
                          focusNode: _titleFocusNode,
                          textInputAction: TextInputAction.done,
                          accentColor: accent,
                          dense: true,
                          borderRadius: 12,
                          contentPadding: const EdgeInsets.fromLTRB(
                            14,
                            15,
                            40,
                            15,
                          ),
                          onSubmitted: (_) => _submit(),
                          onChanged: (_) {
                            if (_titleError != null) {
                              setState(() => _titleError = null);
                            }
                          },
                        ),
                        if (widget.calendars.isNotEmpty)
                          Positioned(
                            top: 0,
                            right: 10,
                            child: JournalTitleCornerFlag(
                              colorValue: widget.calendars
                                      .cast<Calendar?>()
                                      .firstWhere(
                                        (c) => c?.id == _calendarId,
                                        orElse: () => null,
                                      )
                                      ?.colorValue ??
                                  accent.toARGB32(),
                              onSelected: (v) =>
                                  setState(() => _calendarId = v),
                              tooltip: 'Move to calendar',
                              menuEntries: (_) => [
                                for (var i = 0;
                                    i < widget.calendars.length;
                                    i++)
                                  VoyagerPopupMenuItem<String>(
                                    value: widget.calendars[i].id,
                                    position: VoyagerMenuTheme.positionFor(
                                      i,
                                      widget.calendars.length,
                                    ),
                                    child: Row(
                                      children: [
                                        JournalBookmarkFlag(
                                          colorValue: _calendarFlagColor(
                                            widget.calendars[i],
                                          ),
                                          size: 12,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            widget.calendars[i].name,
                                          ),
                                        ),
                                        if (widget.calendars[i].id ==
                                            _calendarId)
                                          Icon(
                                            PhosphorIconsRegular.check,
                                            size: 18,
                                            color: Color(_calendarFlagColor(
                                              widget.calendars[i],
                                            )),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Transform.translate(
                    offset: const Offset(2, 0),
                    child: IconButton(
                      onPressed: () =>
                          setState(() => _isFullDay = !_isFullDay),
                      tooltip: _isFullDay ? 'All day (on)' : 'All day (off)',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        PhosphorIconsRegular.clockCountdown,
                        size: 18,
                        color: _isFullDay
                            ? accent
                            : baseTheme.colorScheme.onSurface
                                .withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                ],
              ),
              if (_titleError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _titleError!,
                  style: TextStyle(
                    color: baseTheme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              // ── Row 2: date/time pills (full width) ───────────────────
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Builder(
                      builder: (buttonContext) {
                        final isMultiDay = _start.year != _end.year ||
                            _start.month != _end.month ||
                            _start.day != _end.day;
                        final dateFormat = isMultiDay
                            ? DateFormat('MMM d')
                            : DateFormat('EEE, MMM d');
                        final label = isMultiDay
                            ? '${dateFormat.format(_start)} → ${dateFormat.format(_end)}'
                            : dateFormat.format(_start);
                        return SelectorPill(
                          dense: true,
                          ellipsize: false,
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
                                accentColor: accent,
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
                      const SizedBox(width: 6),
                      Builder(
                        key: _timePillKey,
                        builder: (buttonContext) => SelectorPill(
                          dense: true,
                          ellipsize: false,
                          isActive: _isTimePopoverOpen,
                          accentColor: accent,
                          onTap: () => _openTimePopover(buttonContext),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                TimeOfDay.fromDateTime(_start).format(context),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                      fontWeight: FontWeight.w500,
                                    ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                child: Icon(
                                  Icons.arrow_forward,
                                  size: 10,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              Text(
                                TimeOfDay.fromDateTime(_end).format(context),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
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
              ),
              const SizedBox(height: 10),
                // ── Row 3: notes ─────────────────────────────────────────
                LabeledTextField(
                  label: 'Notes',
                  controller: _notesController,
                  focusNode: _notesFocusNode,
                  maxLines: 3,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  accentColor: accent,
                  onChanged: _handleNotesChanged,
                ),
                // ── Row 4: color swatches (no label) ─────────────────────
                ColorPickerField(
                  label: '',
                  value: _colorValue,
                  swatchRadius: 14,
                  maxHeight: paletteViewportHeight(
                    14,
                    visibleRows: 2,
                    clipPartialNextRow: true,
                  ),
                  onChanged: (value) {
                    setState(() => _colorValue = value);
                    ContextualPopoverAccent.update(context, Color(value));
                  },
                ),
                const SizedBox(height: 10),
                // ── Row 5: cancel / save ──────────────────────────────────
                Row(
                  children: [
                    GlassButton(
                      onPressed: _discard,
                      label: 'Cancel',
                      dense: true,
                    ),
                    const Spacer(),
                    GlassButton(
                      onPressed: _submit,
                      label: 'Save',
                      dense: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    );

    final content = Stack(
      clipBehavior: Clip.none,
      children: [
        panel,
        Positioned(
          top: 5,
          right: 9,
          child: IconButton(
            onPressed: _discard,
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Close',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ),
      ],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleDismissPop();
      },
      child: content,
    );
  }
}
