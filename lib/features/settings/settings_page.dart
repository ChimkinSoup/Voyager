import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/utils/key_binding.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';
import 'package:voyager/features/settings/key_binding_dialog.dart';
import 'package:voyager/features/settings/settings_color_palette_section.dart';
import 'package:voyager/features/settings/weather_location_tile.dart';
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
            subtitle: Text(formatColorHex(settings.accentColor)),
            leading: CircleAvatar(backgroundColor: Color(settings.accentColor)),
            onTap: () => pickAccentColor(context, ref, settings, (s) => _save(ref, s)),
          ),
          const SizedBox(height: 8),
          SettingsColorPaletteSection(
            settings: settings,
            onSave: (s) => _save(ref, s),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Show quotes on journal entries'),
            value: settings.showQuotes,
            onChanged: (v) => _save(ref, settings.copyWith(showQuotes: v)),
          ),
          SwitchListTile(
            title: const Text('Week starts on Monday'),
            value: settings.weekStartsOnMonday,
            onChanged: (v) =>
                _save(ref, settings.copyWith(weekStartsOnMonday: v)),
          ),
          ListTile(
            title: const Text('Calendar: previous period'),
            subtitle: Text(
              '${formatKeyBinding(settings.calendarNavigateLeftKey)} '
              '(also Left arrow)',
            ),
            onTap: () => _pickCalendarKey(
              context,
              ref,
              settings,
              title: 'Previous period key',
              current: settings.calendarNavigateLeftKey,
              onSelected: (key) =>
                  settings.copyWith(calendarNavigateLeftKey: key),
            ),
          ),
          ListTile(
            title: const Text('Calendar: next period'),
            subtitle: Text(
              '${formatKeyBinding(settings.calendarNavigateRightKey)} '
              '(also Right arrow)',
            ),
            onTap: () => _pickCalendarKey(
              context,
              ref,
              settings,
              title: 'Next period key',
              current: settings.calendarNavigateRightKey,
              onSelected: (key) =>
                  settings.copyWith(calendarNavigateRightKey: key),
            ),
          ),
          SwitchListTile(
            title: const Text('Hide completed tasks'),
            subtitle: const Text(
              'Removes completed tasks and the completed section from to-do',
            ),
            value: settings.hideCompletedTasks,
            onChanged: (v) =>
                _save(ref, settings.copyWith(hideCompletedTasks: v)),
          ),
          WeatherLocationTile(settings: settings),
          const ListTile(
            title: Text('About'),
            subtitle: Text('Voyager — local-first journal and productivity'),
          ),
          ListTile(
            title: const Text('Weather data'),
            subtitle: const Text('Provided by OpenWeather'),
            trailing: const Icon(PhosphorIconsRegular.arrowSquareOut, size: 18),
            onTap: () => launchUrl(
              Uri.parse('https://openweathermap.org/'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          if (isWindows) ...[
            ListTile(
              title: const Text('Journal hotkey'),
              subtitle: Text(
                '${settings.journalHotkey}\n'
                'Avoid Ctrl+Shift combos that browsers use (e.g. Chrome DevTools).',
              ),
            ),
            ListTile(
              title: const Text('To-do hotkey'),
              subtitle: Text(
                '${settings.todoHotkey}\n'
                'Default is $defaultTodoHotkey so Chrome Ctrl+Shift+T still works.',
              ),
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

  Future<void> _pickCalendarKey(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings, {
    required String title,
    required String current,
    required AppSettings Function(String key) onSelected,
  }) async {
    final picked = await showKeyBindingDialog(
      context,
      title: title,
      current: current,
    );
    if (picked == null || picked == current) return;
    await _save(ref, onSelected(picked));
  }
}
