import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/core/widgets/palette_color_picker.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/domain/models/calendar_models.dart';

Future<String?> promptCalendarName(
  BuildContext context,
  String title, {
  String? initial,
}) {
  return showPromptNameDialog(
    context,
    title: title,
    initial: initial,
    contentWidth: 400,
  );
}

Future<void> renameCalendarList(
  BuildContext context,
  WidgetRef ref,
  Calendar calendar,
) async {
  final name = await promptCalendarName(
    context,
    'Rename calendar',
    initial: calendar.name,
  );
  if (name == null || name.trim().isEmpty || name.trim() == calendar.name) {
    return;
  }
  final updated = calendar.copyWith(name: name.trim());
  await ref.read(calendarRepositoryProvider).upsertCalendar(updated);
  ref.invalidate(calendarsProvider);
  await ref.read(calendarsProvider.future);
}

Future<void> changeCalendarListColor(
  BuildContext context,
  WidgetRef ref,
  Calendar calendar,
  List<Calendar> allCalendars,
) async {
  final color = await pickPaletteColorWithRef(
    ref,
    context,
    current: calendar.colorValue,
    usedColors: allCalendars
        .where((item) => item.id != calendar.id && item.colorValue != null)
        .map((item) => item.colorValue!)
        .toSet(),
  );
  if (color == null) return;
  final updated = calendar.copyWith(colorValue: color);
  await ref.read(calendarRepositoryProvider).upsertCalendar(updated);
  ref.invalidate(calendarsProvider);
  await ref.read(calendarsProvider.future);
}

Future<Calendar?> createCalendarList(
  BuildContext context,
  WidgetRef ref,
) async {
  final allCalendars = ref.read(calendarsProvider).valueOrNull ?? [];
  final palette = ref.read(colorPaletteProvider);
  final defaultColor = Theme.of(context).colorScheme.primary.toARGB32();
  final assigner = paletteFromItems(
    allCalendars.map((c) => c.colorValue),
    palette,
  );
  final result = await showCreateNameColorDialog(
    context,
    title: 'New calendar',
    palette: palette,
    initialColor: assigner.nextColor(),
    usedColors: allCalendars
        .where((c) => c.colorValue != null)
        .map((c) => c.colorValue!)
        .toSet(),
  );
  if (result == null) return null;

  final now = utcNow();
  final repo = ref.read(calendarRepositoryProvider);
  final created = Calendar(
    id: newId(),
    name: result.name,
    colorValue: result.color,
    createdAt: now,
    updatedAt: now,
  );

  if (allCalendars.isEmpty) {
    final legacy = Calendar(
      id: legacyCalendarId,
      name: 'Calendar',
      colorValue: defaultColor,
      createdAt: now,
      updatedAt: now,
    );
    await repo.upsertCalendar(legacy);
  }

  await repo.upsertCalendar(created);
  ref.invalidate(calendarsProvider);
  return created;
}

void _invalidateCalendarDeleteProviders(WidgetRef ref) {
  ref.invalidate(calendarsProvider);
  ref.invalidate(calendarEventsProvider);
}

/// Deletes a calendar and (per user choice) either soft-deletes its events or
/// moves them to the default calendar. Calendars are local-only, so there is
/// no remote-sync step to follow up with.
Future<bool> deleteCalendarList(
  BuildContext context,
  WidgetRef ref, {
  required Calendar calendar,
  required List<Calendar> allCalendars,
  required int eventCount,
  VoidCallback? onConfirmed,
  VoidCallback? onLocalDeleteFailed,
}) async {
  if (calendar.id == legacyCalendarId) return false;

  // Read out of the theme before the dialog: the orElse below runs after the
  // await, where [context] may already be dead.
  final fallbackColor = Theme.of(context).colorScheme.primary.toARGB32();

  final choice = await showDeleteContainerDialog(
    context,
    title: 'Delete "${calendar.name}"?',
    message: eventCount == 0
        ? 'This calendar has no events and will be removed.'
        : 'This calendar has $eventCount events. Move them to the default "Calendar", or delete everything.',
    deleteAllLabel: 'Yes (delete all events)',
  );
  if (!context.mounted || choice == DeleteContainerChoice.cancel) return false;

  onConfirmed?.call();

  final repo = ref.read(calendarRepositoryProvider);

  try {
    if (choice == DeleteContainerChoice.deleteAll && eventCount > 0) {
      await repo.softDeleteEventsInCalendar(calendar.id);
    } else if (choice == DeleteContainerChoice.moveToDefault && eventCount > 0) {
      final fallback = allCalendars.firstWhere(
        (item) => item.id == legacyCalendarId,
        orElse: () {
          final now = utcNow();
          return Calendar(
            id: legacyCalendarId,
            name: 'Calendar',
            colorValue: fallbackColor,
            createdAt: now,
            updatedAt: now,
          );
        },
      );
      if (!allCalendars.any((item) => item.id == legacyCalendarId)) {
        await repo.upsertCalendar(fallback);
      }
      await repo.reassignEventsCalendar(calendar.id, legacyCalendarId);
    }

    await repo.softDeleteCalendar(calendar.id);
  } catch (error, stackTrace) {
    onLocalDeleteFailed?.call();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'calendar_list_actions',
        context: ErrorDescription('while deleting calendar locally'),
      ),
    );
    return false;
  }

  _invalidateCalendarDeleteProviders(ref);

  return true;
}
