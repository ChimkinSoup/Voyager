import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_labels.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart'
    show kSoftDeleteUndoDwell;
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/scope_switcher.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/services/calendar_event_import.dart';
import 'package:voyager/features/notifications/reminder_bell_button.dart';

/// Imports a batch of events pasted from an AI, into one of [calendars].
///
/// The user copies [calendarEventImportPrompt] into an AI along with their
/// content, then pastes the reply here. Returns how many events were written,
/// or null when cancelled.
Future<int?> showCalendarImportDialog(
  BuildContext context, {
  required List<Calendar> calendars,
  required String initialCalendarId,
}) {
  return showVoyagerDialog<int>(
    context: context,
    builder: (context) => _CalendarImportDialog(
      calendars: calendars,
      initialCalendarId: initialCalendarId,
    ),
  );
}

class _CalendarImportDialog extends ConsumerStatefulWidget {
  const _CalendarImportDialog({
    required this.calendars,
    required this.initialCalendarId,
  });

  final List<Calendar> calendars;
  final String initialCalendarId;

  @override
  ConsumerState<_CalendarImportDialog> createState() =>
      _CalendarImportDialogState();
}

class _CalendarImportDialogState extends ConsumerState<_CalendarImportDialog> {
  final _controller = TextEditingController();
  late String _calendarId = widget.initialCalendarId;
  CalendarEventImport? _parsed;
  bool _copied = false;
  bool _importing = false;
  String? _importError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _parse(String text) {
    setState(() {
      _importError = null;
      _parsed = text.trim().isEmpty
          ? null
          : parseCalendarEventImport(
              text,
              palette: ref.read(colorPaletteProvider),
            );
    });
  }

  Future<void> _copyPrompt() async {
    await Clipboard.setData(
      ClipboardData(
        text: calendarEventImportPrompt(
          palette: ref.read(colorPaletteProvider),
          today: DateTime.now(),
        ),
      ),
    );
    if (mounted) setState(() => _copied = true);
  }

  /// The color an event lands with when the import named none: the same
  /// default a new event gets in the event panel.
  int get _defaultColor {
    final calendar = widget.calendars
        .where((c) => c.id == _calendarId)
        .firstOrNull;
    return calendar?.colorValue ??
        ref.read(settingsProvider).valueOrNull?.accentColor ??
        0xFF7C9EFF;
  }

  Future<void> _import() async {
    final events = _parsed?.events ?? const [];
    if (events.isEmpty || _importing) return;
    setState(() => _importing = true);
    final calendarRepo = ref.read(calendarRepositoryProvider);
    final reminderRepo = ref.read(reminderRepositoryProvider);
    final defaultColor = _defaultColor;
    // Resolved now: the dialog is gone by the time Undo is pressed, and a
    // `WidgetRef` throws once its widget is.
    final overlay = Overlay.of(context, rootOverlay: true);
    final container = ProviderScope.containerOf(context, listen: false);
    final ids = <String>[];
    var anyReminder = false;
    try {
      for (final imported in events) {
        final now = utcNow();
        final event = CalendarEvent(
          id: newId(),
          calendarId: _calendarId,
          title: imported.title,
          start: imported.start,
          end: imported.end,
          isFullDay: imported.isFullDay,
          colorValue: imported.colorValue ?? defaultColor,
          notes: imported.notes,
          recurrence: imported.recurrence,
          createdAt: now,
          updatedAt: now,
        );
        await calendarRepo.upsertEvent(event);
        ids.add(event.id);
        if (imported.reminderMinutes != null) {
          anyReminder = true;
          await setEntityReminder(
            reminderRepo,
            kind: ReminderSourceKind.calendarEvent,
            entityId: event.id,
            offsetMinutes: imported.reminderMinutes,
          );
        }
      }
    } catch (e) {
      // All or nothing, like the parse: a half import left in place would be
      // imported twice by the retry.
      var message = 'Import failed, nothing was added: $e';
      try {
        await _undoImport(container, ids);
      } catch (_) {
        // Some of the events stayed; show them rather than hide them.
        container.invalidate(calendarEventsProvider);
        message =
            'Import failed partway, and the events it added could not all be '
            'removed. Check the calendar before importing again: $e';
      }
      if (mounted) {
        setState(() {
          _importing = false;
          _importError = message;
        });
      }
      return;
    }
    ref.invalidate(calendarEventsProvider);
    if (anyReminder) {
      ref.invalidate(entityRemindersProvider);
      unawaited(ref.read(reminderOsNotifierProvider).requestPermission());
    }
    showVoyagerToastIn(
      overlay,
      message: 'Imported ${ids.length} event${ids.length == 1 ? '' : 's'}',
      icon: PhosphorIconsRegular.calendarPlus,
      dwell: kSoftDeleteUndoDwell,
      actions: [
        VoyagerToastAction(
          label: 'Undo',
          onPressed: () => unawaited(_undoImport(container, ids)),
        ),
      ],
    );
    if (mounted) Navigator.pop(context, events.length);
  }

  /// Takes an import back out. Soft-deleted like any other event delete; a
  /// bell left on a deleted event never fires, so reminders stay as they are.
  static Future<void> _undoImport(
    ProviderContainer container,
    List<String> ids,
  ) async {
    final repo = container.read(calendarRepositoryProvider);
    for (final id in ids) {
      await repo.softDeleteEvent(id);
    }
    container.invalidate(calendarEventsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final primary = theme.colorScheme.primary;
    final parsed = _parsed;
    final count = parsed?.events.length ?? 0;
    final selected = widget.calendars
        .where((c) => c.id == _calendarId)
        .firstOrNull;

    return AlertDialog(
      title: const Text('Import events'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Copy the prompt, paste it into an AI followed by your '
              'content, then paste its reply below.',
              style: muted,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                GlassButton(
                  dense: true,
                  onPressed: _copyPrompt,
                  icon: Icon(
                    _copied
                        ? PhosphorIconsRegular.check
                        : PhosphorIconsRegular.copy,
                    size: 16,
                  ),
                  label: _copied ? 'Prompt copied' : 'Copy AI prompt',
                ),
                const Spacer(),
                Text('Into', style: muted),
                const SizedBox(width: 8),
                ScopeSwitcher<String>(
                  selectedValue: _calendarId,
                  accent: selected?.colorValue != null
                      ? paletteColor(selected!.colorValue!, context)
                      : primary,
                  onSelected: (id) => setState(() => _calendarId = id),
                  items: [
                    for (final calendar in widget.calendars)
                      ScopeSwitcherItem<String>(
                        value: calendar.id,
                        label: calendar.name,
                        color: paletteColor(
                          calendar.colorValue ?? primary.toARGB32(),
                          context,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            LabeledTextField(
              label: 'AI reply',
              controller: _controller,
              hintText: '[ { "title": …, "date": "YYYY-MM-DD", … } ]',
              minLines: 6,
              maxLines: 10,
              autofocus: true,
              snippetsAllowed: false,
              autocorrectAllowed: false,
              onChanged: _parse,
            ),
            if (parsed != null) ...[
              const SizedBox(height: 12),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView(
                    shrinkWrap: true,
                    children: parsed.errors.isNotEmpty
                        ? [
                            for (final error in parsed.errors)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 3,
                                ),
                                child: Text(
                                  error,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                          ]
                        : [
                            for (final event in parsed.events)
                              _ImportPreviewRow(
                                event: event,
                                color: event.colorValue ?? _defaultColor,
                              ),
                          ],
                  ),
                ),
              ),
            ],
            if (_importError != null) ...[
              const SizedBox(height: 12),
              Text(
                _importError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
        ),
        GlassButton(
          dense: true,
          onPressed: count == 0 || _importing ? null : _import,
          label: count == 0
              ? 'Import'
              : 'Import $count event${count == 1 ? '' : 's'}',
        ),
      ],
    );
  }
}

class _ImportPreviewRow extends StatelessWidget {
  const _ImportPreviewRow({required this.event, required this.color});

  final ImportedCalendarEvent event;
  final int color;

  String get _when {
    final day = DateFormat('EEE, MMM d');
    final sameDay = DateUtils.isSameDay(event.start, event.end);
    if (event.isFullDay) {
      return sameDay
          ? day.format(event.start)
          : '${day.format(event.start)} – ${day.format(event.end)}';
    }
    final start =
        '${day.format(event.start)}, ${formatTime12Hour(event.start)}';
    return sameDay
        ? '$start – ${formatTime12Hour(event.end)}'
        : '$start – ${day.format(event.end)}, ${formatTime12Hour(event.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final extras = [
      if (event.recurrence.repeats)
        'repeats ${event.recurrence.frequency.name}',
      if (event.reminderMinutes != null)
        'reminder ${reminderOffsetLabel(event.reminderMinutes!).toLowerCase()}',
      if (event.notes.isNotEmpty) 'notes',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 5,
            backgroundColor: paletteColor(color, context),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                Text([_when, ...extras].join(' · '), style: muted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
