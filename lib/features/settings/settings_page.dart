import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    return settingsAsync.when(
      data: (settings) => KeepAliveScrollView(
        storageKey: ShellPageStorageKeys.settingsList,
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('App accent color'),
            subtitle: Text('#${settings.accentColor.toRadixString(16).padLeft(8, '0').toUpperCase()}'),
            leading: CircleAvatar(backgroundColor: Color(settings.accentColor)),
            onTap: () => _pickAccent(context, ref, settings),
          ),
          SwitchListTile(
            title: const Text('Show quotes on journal entries'),
            value: settings.showQuotes,
            onChanged: (v) => _save(ref, settings.copyWith(showQuotes: v)),
          ),
          SwitchListTile(
            title: const Text('Week starts on Monday'),
            value: settings.weekStartsOnMonday,
            onChanged: (v) => _save(ref, settings.copyWith(weekStartsOnMonday: v)),
          ),
          SwitchListTile(
            title: const Text('Hide completed tasks'),
            subtitle: const Text('Removes completed tasks and the completed section from to-do'),
            value: settings.hideCompletedTasks,
            onChanged: (v) => _save(ref, settings.copyWith(hideCompletedTasks: v)),
          ),
          if (isWindows) ...[
            ListTile(
              title: const Text('Journal hotkey'),
              subtitle: Text(settings.journalHotkey),
            ),
            ListTile(
              title: const Text('To-do hotkey'),
              subtitle: Text(settings.todoHotkey),
            ),
          ],
          if (isAndroid)
            const ListTile(
              title: Text('Global hotkeys'),
              subtitle: Text('Available on Windows only'),
            ),
          ListTile(
            title: const Text('Sign out'),
            onTap: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }

  Future<void> _save(WidgetRef ref, AppSettings settings) async {
    await ref.read(settingsRepositoryProvider).saveSettings(settings);
    ref.invalidate(settingsProvider);
  }

  Future<void> _pickAccent(BuildContext context, WidgetRef ref, AppSettings settings) async {
    var selected = settings.accentColor;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Accent color'),
          content: SizedBox(
            width: 360,
            child: ColorPickerField(
              label: 'Choose accent',
              value: selected,
              onChanged: (value) => setDialogState(() => selected = value),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved == true) {
      await _save(ref, settings.copyWith(accentColor: selected));
    }
  }
}
