import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/glass_button.dart';

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
  final result = await showDialog<DeleteContainerChoice>(
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
