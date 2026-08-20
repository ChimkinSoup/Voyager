import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/todo_models.dart';

/// Per-list settings: whether the list's tasks join the combined list, and
/// whether the todo page opens into it.
///
/// The todo twin of the journal's settings sheet, minus the editor-chrome
/// toggles — a task row has no mood, weather or quote to hide. Every toggle
/// writes straight through, matching rename and change-colour.
Future<void> showTodoListSettingsDialog(
  BuildContext context,
  WidgetRef ref,
  TodoListModel list,
) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) => _TodoListSettingsDialog(listId: list.id),
  );
}

class _TodoListSettingsDialog extends ConsumerWidget {
  const _TodoListSettingsDialog({required this.listId});

  final String listId;

  Future<void> _saveList(WidgetRef ref, TodoListModel updated) async {
    await ref.read(todoRepositoryProvider).upsertList(updated);
    ref.read(remoteSyncServiceProvider).pushTodoList(updated);
    ref.invalidate(todoListsProvider);
    await ref.read(todoListsProvider.future);
  }

  /// Setting a default clears whichever list held it before, because
  /// [AppSettings.defaultTodoListId] is a single field — the exclusivity is
  /// structural rather than something the UI has to police.
  Future<void> _saveDefaultList(WidgetRef ref, {required bool isDefault}) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settings = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(
      isDefault
          ? settings.copyWith(defaultTodoListId: listId)
          : settings.copyWith(clearDefaultTodoListId: true),
    );
    ref.invalidate(settingsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(todoListsProvider).valueOrNull;
    final list = lists?.cast<TodoListModel?>().firstWhere(
      (l) => l!.id == listId,
      orElse: () => null,
    );
    final settings = ref.watch(settingsProvider).valueOrNull;
    final theme = Theme.of(context);

    if (list == null) {
      return AlertDialog(
        title: const Text('List settings'),
        content: const SizedBox(
          height: 96,
          child: Center(child: CircularProgressIndicator()),
        ),
        actions: [
          GlassButton(
            onPressed: () => Navigator.pop(context),
            label: 'Close',
            dense: true,
          ),
        ],
      );
    }

    final accent = Color(
      list.colorValue ?? theme.colorScheme.primary.toARGB32(),
    );
    final defaultListId = settings?.defaultTodoListId;
    final isDefault = defaultListId == list.id;
    final currentDefault = defaultListId == null
        ? null
        : lists?.cast<TodoListModel?>().firstWhere(
            (l) => l!.id == defaultListId,
            orElse: () => null,
          );

    return AlertDialog(
      title: Text('${list.name} settings'),
      content: SizedBox(
        width: 420,
        // Scrollable rather than a bare Column, matching the journal sheet:
        // AlertDialog hands its content whatever height is left over, which a
        // short window can make smaller than two rows plus their subtitles.
        child: VoyagerScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toggle(
                context,
                accent: accent,
                title: 'Include in "All tasks"',
                subtitle:
                    'Off keeps these tasks out of the combined list. They stay '
                    'in search and on the calendar.',
                value: list.includeInAllView,
                onChanged: (v) =>
                    _saveList(ref, list.copyWith(includeInAllView: v)),
              ),
              _toggle(
                context,
                accent: accent,
                title: 'Default view',
                subtitle: isDefault
                    ? 'The to-do page always opens here.'
                    : currentDefault != null
                    ? 'Currently: ${currentDefault.name}'
                    : 'No list is the default — the page reopens wherever you '
                          'left it.',
                value: isDefault,
                onChanged: (v) => _saveDefaultList(ref, isDefault: v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Close',
          dense: true,
        ),
      ],
    );
  }

  Widget _toggle(
    BuildContext context, {
    required Color accent,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      activeThumbColor: accent,
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: onChanged,
    );
  }
}
