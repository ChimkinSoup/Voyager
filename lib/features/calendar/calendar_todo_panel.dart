import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_menu_theme.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/core/widgets/datetime_picker_dialog.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/journal_color_flag.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/core/utils/time_format.dart';

class CalendarTodoPanel extends ConsumerStatefulWidget {
  const CalendarTodoPanel({
    super.key,
    required this.task,
    required this.lists,
    required this.listColors,
    required this.onSave,
    required this.onCancel,
    this.focusTitleOnOpen = false,
  });

  final TodoTask task;
  final List<TodoListModel> lists;
  final Map<String, int?> listColors;
  final ValueChanged<TodoTask> onSave;
  final VoidCallback onCancel;
  final bool focusTitleOnOpen;

  @override
  ConsumerState<CalendarTodoPanel> createState() => _CalendarTodoPanelState();
}

class _CalendarTodoPanelState extends ConsumerState<CalendarTodoPanel> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final FocusNode _titleFocusNode;
  late final FocusNode _notesFocusNode;
  late bool _completed;
  late String _listId;
  DateTime? _dueDate;
  String? _titleError;
  bool _intentionalDiscard = false;
  bool _closingAfterSave = false;
  bool _isDatePickerOpen = false;
  bool _isListPickerOpen = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.title);
    _notesController = TextEditingController(text: widget.task.notes ?? '');
    _titleFocusNode = FocusNode();
    _titleFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _titleFocusNode.unfocus();
        _notesFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _notesFocusNode = FocusNode();
    _notesFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _submit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _completed = widget.task.completed;
    _listId = widget.task.listId;
    _dueDate = widget.task.dueDate;
    _scheduleTitleFocusIfNeeded();
  }

  void _scheduleTitleFocusIfNeeded() {
    if (!widget.focusTitleOnOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _titleFocusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant CalendarTodoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id) {
      _titleController.text = widget.task.title;
      _notesController.text = widget.task.notes ?? '';
      _completed = widget.task.completed;
      _listId = widget.task.listId;
      _dueDate = widget.task.dueDate;
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
    final notes = _notesController.text.trim();
    widget.onSave(widget.task.copyWith(
      title: title,
      notes: notes.isEmpty ? null : notes,
      clearNotes: notes.isEmpty,
      completed: _completed,
      listId: _listId,
      dueDate: _dueDate,
      clearDueDate: _dueDate == null,
    ));
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
    if (!_trySave(showValidationErrors: false)) {
      Navigator.of(context).pop();
    }
  }

  String _formatDue(DateTime dateTime) {
    final local = dateTime.toLocal();
    if (local.hour == 0 && local.minute == 0) {
      return DateFormat('EEE, MMM d').format(local);
    }
    return '${DateFormat('EEE, MMM d').format(local)}  ${formatTime12Hour(dateTime)}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.read(settingsProvider).valueOrNull;
    final fallbackColor = settings?.accentColor ?? 0xFF7C9EFF;
    final listColorValue = widget.listColors[_listId] ?? fallbackColor;
    final accent = Color(listColorValue);
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
              // ── Row 1: title + completed icon ───────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: LabeledTextField(
                      label: 'Title',
                      controller: _titleController,
                      focusNode: _titleFocusNode,
                      textInputAction: TextInputAction.done,
                      accentColor: accent,
                      dense: true,
                      borderRadius: 12,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 15,
                      ),
                      onSubmitted: (_) => _submit(),
                      onChanged: (_) {
                        if (_titleError != null) {
                          setState(() => _titleError = null);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Transform.translate(
                    offset: const Offset(2, 0),
                    child: IconButton(
                      onPressed: () => setState(() => _completed = !_completed),
                      tooltip: _completed ? 'Mark incomplete' : 'Mark completed',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      icon: Icon(
                        _completed
                            ? PhosphorIconsFill.checkCircle
                            : PhosphorIconsRegular.circle,
                        size: 22,
                        color: _completed
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
              // ── Row 2: date pill & list selector ───────────────────
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Builder(builder: (context) {
                      final localDue = _dueDate?.toLocal();
                      final hasTime = localDue != null && (localDue.hour != 0 || localDue.minute != 0);
                      final label = localDue == null 
                          ? 'Set date & time'
                          : DateFormat('EEE, MMM d').format(_dueDate!.toLocal()) + (hasTime ? ' at ${formatTime12Hour(_dueDate!.toLocal())}' : '');
                      
                      return SelectorPill(
                        dense: true,
                        ellipsize: false,
                        isActive: _isDatePickerOpen,
                        label: label,
                        accentColor: accent,
                        onTap: () async {
                          setState(() => _isDatePickerOpen = true);
                          
                          final initialDt = _dueDate != null && hasTime
                              ? _dueDate!.toLocal()
                              : (_dueDate != null 
                                  ? _dueDate!.toLocal().copyWith(hour: 12, minute: 0)
                                  : DateTime.now().toLocal());

                          final pickedDt = await showContextualPopover<DateTime>(
                            context: context,
                            buttonContext: context,
                            width: 500,
                            height: 380,
                            accentColor: accent,
                            builder: (ctx) => DateTimeSelectorPopover(
                              initialDateTime: initialDt,
                              accentColor: accent,
                              optionalTime: true,
                              initialHasTime: hasTime,
                            ),
                          );
                          
                          if (mounted) setState(() => _isDatePickerOpen = false);
                          
                          if (pickedDt != null) {
                            setState(() => _dueDate = pickedDt.toUtc());
                          }
                        },
                      );
                    }),
                    if (_dueDate != null) ...[
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: () => setState(() => _dueDate = null),
                        icon: const Icon(PhosphorIconsRegular.x, size: 14),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                        padding: EdgeInsets.zero,
                        color: baseTheme.colorScheme.onSurface.withValues(alpha: 0.5),
                        tooltip: 'Clear due date',
                      ),
                    ],
                    const SizedBox(width: 6),
                    if (widget.lists.isNotEmpty)
                      Builder(builder: (context) {
                        final currentList = widget.lists.firstWhere((l) => l.id == _listId, orElse: () => widget.lists.first);
                        return SelectorPill(
                          dense: true,
                          ellipsize: true,
                          isActive: _isListPickerOpen,
                          label: currentList.name,
                          accentColor: accent,
                          onTap: () async {
                            setState(() => _isListPickerOpen = true);
                            final picked = await showContextualPopover<String>(
                              context: context,
                              buttonContext: context,
                              builder: (ctx) => Theme(
                                data: baseTheme,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 240, maxHeight: 300),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: ListView(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      shrinkWrap: true,
                                      children: widget.lists.asMap().entries.map((entry) {
                                        final index = entry.key;
                                        final list = entry.value;
                                        return VoyagerPopupMenuItem<String>(
                                          value: list.id,
                                          position: VoyagerMenuTheme.positionFor(index, widget.lists.length),
                                          height: 36,
                                          padding: const EdgeInsets.symmetric(horizontal: 12),
                                          child: Row(
                                            children: [
                                              JournalBookmarkFlag(
                                                colorValue: widget.listColors[list.id] ?? fallbackColor,
                                                size: 14,
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  list.name,
                                                  style: baseTheme.textTheme.labelMedium?.copyWith(
                                                    color: baseTheme.colorScheme.onSurface,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (_listId == list.id)
                                                Icon(PhosphorIconsBold.check, size: 14, color: accent),
                                            ],
                                          ),
                                          onTap: () => Navigator.of(ctx).pop(list.id),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ),
                              ),
                            );
                            if (mounted) setState(() => _isListPickerOpen = false);
                            if (picked != null) {
                              setState(() => _listId = picked);
                            }
                          },
                        );
                      }),
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
              ),
              const SizedBox(height: 10),
              // ── Row 5: cancel / save ──────────────────────────────────
              Row(
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _discard,
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
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

    final content = Stack(
      clipBehavior: Clip.none,
      children: [
        panel,
        Positioned(
          top: 5,
          right: 9,
          child: SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              onPressed: _discard,
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
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
