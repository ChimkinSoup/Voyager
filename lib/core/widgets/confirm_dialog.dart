import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String cancelLabel = 'Cancel',
  String confirmLabel = 'Delete',
}) async {
  final confirmed = await showDialog<bool>(
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
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(cancelLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
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
  final result = await showDialog<DeleteContainerChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, DeleteContainerChoice.cancel),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, DeleteContainerChoice.moveToDefault),
          child: Text(moveLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () =>
              Navigator.pop(context, DeleteContainerChoice.deleteAll),
          child: Text(deleteAllLabel),
        ),
      ],
    ),
  );
  return result ?? DeleteContainerChoice.cancel;
}
