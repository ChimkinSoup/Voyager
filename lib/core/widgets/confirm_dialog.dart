import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/services/calendar_recurrence_editing.dart';

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String cancelLabel = 'Cancel',
  String confirmLabel = 'Delete',
}) async {
  final confirmed = await showVoyagerDialog<bool>(
    context: context,
    builder: (context) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            Navigator.pop(context, true),
      },
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            GlassButton(
              onPressed: () => Navigator.pop(context, false),
              label: cancelLabel,
              dense: true,
            ),
            GlassButton(
              onPressed: () => Navigator.pop(context, true),
              label: confirmLabel,
              color: Theme.of(context).colorScheme.error,
              dense: true,
            ),
          ],
        ),
      ),
    ),
  );
  return confirmed == true;
}

/// Delete a journal or to-do list: move contents to the default container, or
/// soft-delete everything including contents.
enum DeleteContainerChoice { cancel, moveToDefault, deleteAll }

Future<DeleteContainerChoice> showDeleteContainerDialog(
  BuildContext context, {
  required String title,
  required String message,
  String moveLabel = 'Yes',
  String deleteAllLabel = 'Yes (delete all entries)',
}) async {
  final result = await showVoyagerDialog<DeleteContainerChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context, DeleteContainerChoice.cancel),
          label: 'Cancel',
          dense: true,
        ),
        GlassButton(
          onPressed: () =>
              Navigator.pop(context, DeleteContainerChoice.moveToDefault),
          label: moveLabel,
          dense: true,
        ),
        GlassButton(
          onPressed: () =>
              Navigator.pop(context, DeleteContainerChoice.deleteAll),
          label: deleteAllLabel,
          color: Theme.of(context).colorScheme.error,
          dense: true,
        ),
      ],
    ),
  );
  return result ?? DeleteContainerChoice.cancel;
}

/// Asks which slice of a recurring series an edit or delete applies to.
///
/// Returns null when the user backs out. [isDelete] only swaps the wording and
/// the destructive colour — the three choices are the same either way, so the
/// prompt reads identically whichever action opened it.
Future<RecurrenceEditScope?> showRecurrenceScopeDialog(
  BuildContext context, {
  required String title,
  required bool isDelete,
}) async {
  return showVoyagerDialog<RecurrenceEditScope>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(
        isDelete
            ? 'This is a repeating event. Which occurrences should be deleted?'
            : 'This is a repeating event. Which occurrences should be changed?',
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
          dense: true,
        ),
        GlassButton(
          onPressed: () =>
              Navigator.pop(context, RecurrenceEditScope.thisEvent),
          label: 'This event only',
          dense: true,
        ),
        GlassButton(
          onPressed: () =>
              Navigator.pop(context, RecurrenceEditScope.thisAndFuture),
          label: 'This and all future events',
          dense: true,
        ),
        GlassButton(
          onPressed: () =>
              Navigator.pop(context, RecurrenceEditScope.allEvents),
          label: 'All events',
          color: isDelete ? Theme.of(context).colorScheme.error : null,
          dense: true,
        ),
      ],
    ),
  );
}
