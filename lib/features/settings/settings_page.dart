import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/build_info.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/utils/key_binding.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/petal_field.dart' show petalColorWeights;
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/core/widgets/rounded_drag_proxy.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/settings/backup_list_dialog.dart';
import 'package:voyager/features/trash/trash_dialog.dart';
import 'package:voyager/features/settings/custom_quotes_dialog.dart';
import 'package:voyager/features/settings/services/auto_backup_service.dart';
import 'package:voyager/features/settings/devices_section.dart';
import 'package:voyager/features/settings/dictionary_dialog.dart';
import 'package:voyager/features/settings/job_experience_snippets_dialog.dart';
import 'package:voyager/features/settings/media_storage_dialog.dart';
import 'package:voyager/features/settings/key_binding_dialog.dart';
import 'package:voyager/features/settings/settings_color_palette_section.dart';
import 'package:voyager/features/settings/snippets_dialog.dart';
import 'package:voyager/features/settings/weather_location_tile.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    final journalsAsync = ref.watch(journalsProvider);
    final todoStatsAsync = ref.watch(todoListStatsProvider);
    final journalCount = journalsAsync.valueOrNull?.length;
    final todoStats = todoStatsAsync.valueOrNull;
    final openTaskCount = todoStats?.values.fold<int>(
      0,
      (sum, stat) => sum + stat.active,
    );
    final completedTaskCount = todoStats?.values.fold<int>(
      0,
      (sum, stat) => sum + stat.completed,
    );

    return settingsAsync.when(
      data: (settings) => KeepAliveScrollView(
        storageKey: ShellPageStorageKeys.settingsList,
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('App accent color'),
            subtitle: Text(formatColorHex(settings.accentColor)),
            leading: CircleAvatar(backgroundColor: Color(settings.accentColor)),
            onTap: () =>
                pickAccentColor(context, ref, settings, (s) => _save(ref, s)),
          ),
          const SizedBox(height: 8),
          SettingsColorPaletteSection(
            settings: settings,
            onSave: (s) => _save(ref, s),
          ),
          const SizedBox(height: 16),
          Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Theme'),
            subtitle: Text(
              settings.themeMode == AppThemeMode.light
                  ? 'Light — cream paper with drifting petals'
                  : 'Dark — geometric night',
            ),
            trailing: SegmentedButton<AppThemeMode>(
              segments: const [
                ButtonSegment(
                  value: AppThemeMode.dark,
                  icon: Icon(PhosphorIconsRegular.moon),
                  label: Text('Dark'),
                ),
                ButtonSegment(
                  value: AppThemeMode.light,
                  icon: Icon(PhosphorIconsRegular.sun),
                  label: Text('Light'),
                ),
              ],
              selected: {settings.themeMode},
              showSelectedIcon: false,
              onSelectionChanged: (sel) =>
                  _save(ref, settings.copyWith(themeMode: sel.first)),
            ),
          ),
          if (settings.themeMode == AppThemeMode.light)
            _PetalSettings(settings: settings, onSave: (s) => _save(ref, s))
          else
            const _GeometricSettings(),
          const SizedBox(height: 16),
          Text('Life Tracker', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Birth date'),
            subtitle: Text(
              settings.birthDate == null
                  ? 'Not set — the Life Tracker tree will show a placeholder'
                  : DateFormat.yMMMMd().format(settings.birthDate!),
            ),
            trailing: const Icon(PhosphorIconsRegular.calendar),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: settings.birthDate ?? DateTime(1995, 1, 1),
                firstDate: DateTime(1900),
                lastDate: DateTime.now(),
              );
              if (picked != null) {
                _save(ref, settings.copyWith(birthDate: picked));
              }
            },
          ),
          const SizedBox(height: 16),
          Text('Statistics', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Total journals'),
            trailing: Text(_statCountLabel(journalCount)),
          ),
          ListTile(
            title: const Text('Non-completed tasks'),
            trailing: Text(_statCountLabel(openTaskCount)),
          ),
          ListTile(
            title: const Text('Completed tasks'),
            trailing: Text(_statCountLabel(completedTaskCount)),
          ),
          // The old companion toggle for the analytics *calendar* view is
          // gone with that view itself — a statistic's calendar now opens as
          // a popup from its grid tile, so this one switch governs whether
          // built-in trackers show up at all.
          SwitchListTile(
            title: const Text('Default trackers in grid view'),
            subtitle: const Text(
              'Show built-in trackers like Journal Entries in the analytics '
              'grid view',
            ),
            value: settings.showDefaultTrackersInGrid,
            onChanged: (v) =>
                _save(ref, settings.copyWith(showDefaultTrackersInGrid: v)),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Show quotes on journal entries'),
            value: settings.showQuotes,
            onChanged: (v) => _save(ref, settings.copyWith(showQuotes: v)),
          ),
          ListTile(
            title: const Text('Custom quotes'),
            subtitle: const Text(
              'Add your own quotes to the pool a new entry picks from',
            ),
            trailing: const Icon(PhosphorIconsRegular.quotes),
            onTap: () => showCustomQuotesDialog(context),
          ),
          SwitchListTile(
            title: const Text('Week starts on Monday'),
            // Purely a display preference now: weekly tracker values are
            // always filed under Monday (see
            // [kTrackerStorageWeekStartsMonday]), so this only decides which
            // column a calendar draws first. It used to re-anchor every
            // stored weekly value on each flip, which meant a per-device
            // setting repartitioned synced data — and rewrote each row's
            // periodStart while leaving its id derived from the old anchor.
            onChanged: (v) =>
                _save(ref, settings.copyWith(weekStartsOnMonday: v)),
            value: settings.weekStartsOnMonday,
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
          SwitchListTile(
            title: const Text('Vim keybindings'),
            subtitle: const Text(
              'Press Esc in any text box for Normal mode: motions, operators, '
              'text objects, visual mode and / search. Fields still start in '
              'Insert, so typing works as usual until you ask for Vim',
            ),
            value: settings.vimModeEnabled,
            onChanged: (v) => _save(ref, settings.copyWith(vimModeEnabled: v)),
          ),
          SwitchListTile(
            title: const Text('Caps Lock indicator'),
            subtitle: const Text(
              'Shows a mark next to the caret while Caps Lock is on and a text '
              'box has focus. Windows and Linux only — macOS draws its own',
            ),
            value: settings.capsLockIndicatorEnabled,
            onChanged: (v) =>
                _save(ref, settings.copyWith(capsLockIndicatorEnabled: v)),
          ),
          SwitchListTile(
            title: const Text('Autocorrect'),
            subtitle: const Text(
              'Fixes obvious typos in multi-line text boxes as you finish a '
              'word — only when one dictionary word is a single swapped, '
              'missing or extra letter away. Backspace right after undoes it '
              'and stops it happening again for that word',
            ),
            value: settings.autocorrectEnabled,
            onChanged: (v) =>
                _save(ref, settings.copyWith(autocorrectEnabled: v)),
          ),
          ListTile(
            title: const Text('Text snippets'),
            subtitle: Text(
              settings.snippets.isEmpty
                  ? 'Type a shortcut in any text box and expand it into '
                        'something longer — none set up yet'
                  : '${settings.snippets.length} '
                        '${settings.snippets.length == 1 ? 'snippet' : 'snippets'}'
                        '${settings.snippetsEnabled ? '' : ' (disabled)'}',
            ),
            trailing: const Icon(PhosphorIconsRegular.textAa),
            onTap: () => showSnippetsDialog(context),
          ),
          const _DictionaryTile(),
          WeatherLocationTile(settings: settings),
          const SizedBox(height: 16),
          Text('Finance', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text('Show annualized subscription cost'),
            subtitle: const Text(
              'Displays each recurring bill\'s yearly total in faint text on '
              'the Bill Radar (e.g. \$180/yr for a \$15/month plan)',
            ),
            value: settings.showAnnualizedSubscriptionCost,
            onChanged: (v) => _save(
              ref,
              settings.copyWith(showAnnualizedSubscriptionCost: v),
            ),
          ),
          const SizedBox(height: 16),
          Text('Jobs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Job application profile'),
            subtitle: Text(_jobProfileSummary(settings)),
            trailing: const Icon(PhosphorIconsRegular.caretRight),
            onTap: () => _showJobProfileDialog(context, ref, settings),
          ),
          ListTile(
            title: const Text('Experience snippets'),
            subtitle: Text(jobExperienceSnippetsSummary(settings)),
            trailing: const Icon(PhosphorIconsRegular.caretRight),
            onTap: () => showJobExperienceSnippetsDialog(context),
          ),
          const SizedBox(height: 16),
          Text('LeetCode', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('LeetCode username'),
            subtitle: Text(
              settings.leetcodeUsername == null ||
                      settings.leetcodeUsername!.isEmpty
                  ? 'Not set — Track will open with blank fields'
                  : settings.leetcodeUsername!,
            ),
            trailing: const Icon(PhosphorIconsRegular.caretRight),
            onTap: () => _showLeetCodeUsernameDialog(context, ref, settings),
          ),
          SwitchListTile(
            title: const Text('View NeetCode 150'),
            subtitle: const Text(
              'Show a progress ring for NeetCode 150 problems on the '
              'LeetCode dashboard',
            ),
            value: settings.showNeetCode150,
            onChanged: (v) => _save(ref, settings.copyWith(showNeetCode150: v)),
          ),
          const SizedBox(height: 16),
          Text('Study', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Grade: Fail'),
            subtitle: Text(formatKeyBinding(settings.srsFailKey)),
            onTap: () => _pickCalendarKey(
              context,
              ref,
              settings,
              title: 'Fail key',
              current: settings.srsFailKey,
              onSelected: (key) => settings.copyWith(srsFailKey: key),
            ),
          ),
          ListTile(
            title: const Text('Grade: Hard'),
            subtitle: Text(formatKeyBinding(settings.srsHardKey)),
            onTap: () => _pickCalendarKey(
              context,
              ref,
              settings,
              title: 'Hard key',
              current: settings.srsHardKey,
              onSelected: (key) => settings.copyWith(srsHardKey: key),
            ),
          ),
          ListTile(
            title: const Text('Grade: Good'),
            subtitle: Text(formatKeyBinding(settings.srsGoodKey)),
            onTap: () => _pickCalendarKey(
              context,
              ref,
              settings,
              title: 'Good key',
              current: settings.srsGoodKey,
              onSelected: (key) => settings.copyWith(srsGoodKey: key),
            ),
          ),
          ListTile(
            title: const Text('Grade: Easy'),
            subtitle: Text(formatKeyBinding(settings.srsEasyKey)),
            onTap: () => _pickCalendarKey(
              context,
              ref,
              settings,
              title: 'Easy key',
              current: settings.srsEasyKey,
              onSelected: (key) => settings.copyWith(srsEasyKey: key),
            ),
          ),
          const SizedBox(height: 16),
          Text('Dream Journal', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text('Show dream statistics in analytics'),
            subtitle: const Text(
              'Adds a stat to the analytics page showing whether you logged '
              'a dream each day',
            ),
            value: settings.showDreamStatistics,
            onChanged: (v) =>
                _save(ref, settings.copyWith(showDreamStatistics: v)),
          ),
          const SizedBox(height: 16),
          Text('Workout', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Weight unit'),
            subtitle: Text(
              settings.weightUnit == WeightUnit.kg ? 'Kilograms' : 'Pounds',
            ),
            trailing: SegmentedButton<WeightUnit>(
              segments: const [
                ButtonSegment(value: WeightUnit.lb, label: Text('lb')),
                ButtonSegment(value: WeightUnit.kg, label: Text('kg')),
              ],
              selected: {settings.weightUnit},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  _save(ref, settings.copyWith(weightUnit: selection.first)),
            ),
          ),
          SwitchListTile(
            title: const Text('Rest timer between sets'),
            subtitle: Text(
              'Starts a ${settings.workoutRestSeconds}s countdown when you '
              'complete a set',
            ),
            value: settings.workoutRestTimerEnabled,
            onChanged: (v) =>
                _save(ref, settings.copyWith(workoutRestTimerEnabled: v)),
          ),
          if (settings.workoutRestTimerEnabled)
            ListTile(
              title: const Text('Rest length'),
              subtitle: Slider(
                value: settings.workoutRestSeconds.toDouble().clamp(15, 300),
                min: 15,
                max: 300,
                divisions: 19,
                label: '${settings.workoutRestSeconds}s',
                onChanged: (v) => _save(
                  ref,
                  settings.copyWith(workoutRestSeconds: v.round()),
                ),
              ),
            ),
          SwitchListTile(
            title: const Text('Show workouts on the calendar'),
            subtitle: const Text(
              'Adds a small icon to month and week days you worked out on',
            ),
            value: settings.showWorkoutsOnCalendar,
            onChanged: (v) =>
                _save(ref, settings.copyWith(showWorkoutsOnCalendar: v)),
          ),
          SwitchListTile(
            title: const Text('Show workout statistics in analytics'),
            subtitle: const Text(
              'Adds a stat to the analytics page showing whether you worked '
              'out each day',
            ),
            value: settings.showWorkoutStatistics,
            onChanged: (v) =>
                _save(ref, settings.copyWith(showWorkoutStatistics: v)),
          ),
          const SizedBox(height: 16),
          Text('Images', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text('Upload images to the cloud'),
            subtitle: const Text(
              'Off keeps attached images on this device forever. Your other '
              'devices still see that an image exists, but can never get the '
              'picture itself',
            ),
            value: settings.mediaRemoteUploadsEnabled,
            onChanged: (v) async {
              await _save(ref, settings.copyWith(mediaRemoteUploadsEnabled: v));
              // Turning uploads on is the moment everything attached while
              // they were off can finally leave — without this those images
              // would stay stranded on one device forever.
              if (!v) return;
              final queued = await ref
                  .read(mediaServiceProvider)
                  .queueLocalOnlyUploads();
              if (queued == 0 || !context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Queued $queued image${queued == 1 ? '' : 's'} for upload.',
                  ),
                ),
              );
            },
          ),
          SwitchListTile(
            title: const Text('Download images from the cloud'),
            subtitle: const Text(
              'Off shows "Download disabled" wherever an image is not already '
              'on this device, instead of a spinner that never finishes',
            ),
            value: settings.mediaRemoteDownloadsEnabled,
            onChanged: (v) =>
                _save(ref, settings.copyWith(mediaRemoteDownloadsEnabled: v)),
          ),
          SwitchListTile(
            title: const Text('Download images in the background'),
            subtitle: Text(
              settings.mediaRemoteDownloadsEnabled
                  ? 'Fetches every synced image after a sync, so they are '
                        'there next time you are offline'
                  : 'Needs "Download images from the cloud" to be on',
            ),
            value: settings.mediaBackgroundPrefetchEnabled,
            // Prefetch is meaningless while downloads are off, so it is
            // disabled rather than left on as a setting with no effect.
            onChanged: settings.mediaRemoteDownloadsEnabled
                ? (v) => _save(
                    ref,
                    settings.copyWith(mediaBackgroundPrefetchEnabled: v),
                  )
                : null,
          ),
          const _MediaStorageTile(),
          const SizedBox(height: 16),
          const DevicesSettingsSection(),
          const SizedBox(height: 16),
          Text('Navigation', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Reorder navigation pages'),
            trailing: const Icon(PhosphorIconsRegular.caretRight),
            onTap: () => _showReorderNavDialog(context, ref, settings),
          ),
          ListTile(
            title: const Text('Startup page'),
            subtitle: Text(_startupPageLabel(settings)),
            trailing: const Icon(PhosphorIconsRegular.caretRight),
            onTap: () => _showStartupPageDialog(context, ref, settings),
          ),
          const SizedBox(height: 16),
          Text(
            'Backup & Restore',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          ListTile(
            title: const Text('Trash'),
            subtitle: const Text(
              'Restore anything deleted in the last 30 days, or delete it '
              'for good',
            ),
            leading: const Icon(PhosphorIconsRegular.trash),
            trailing: const Icon(PhosphorIconsRegular.caretRight),
            onTap: () => showTrashDialog(context),
          ),
          const _AutoBackupTiles(),
          ListTile(
            title: const Text('Export Backup'),
            subtitle: const Text(
              'Export everything — journal, tasks, calendar, trackers, '
              'finance, study, workouts and settings — to a ZIP file',
            ),
            leading: const Icon(PhosphorIconsRegular.downloadSimple),
            onTap: () async {
              try {
                // saveFile, not getDirectoryPath: on Windows every other
                // file_picker dialog runs on a spawned isolate, but
                // getDirectoryPath drives COM's IFileOpenDialog inline on the
                // platform thread and takes the process down with an access
                // violation before it ever returns a path.
                final targetPath = await FilePicker.platform.saveFile(
                  dialogTitle: 'Export Backup',
                  fileName:
                      'voyager_backup_${DateTime.now().millisecondsSinceEpoch}.zip',
                  type: FileType.custom,
                  allowedExtensions: ['zip'],
                );
                if (targetPath == null) return;

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Exporting backup...')),
                  );
                }

                final file = await ref
                    .read(dataExportServiceProvider)
                    .exportDataToZip(File(targetPath));

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Backup exported to: ${file.path}'),
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
                }
              }
            },
          ),
          ListTile(
            title: const Text('Import Backup'),
            subtitle: const Text(
              'Restore everything from a ZIP file. Records the backup and this '
              'device already agree on are left untouched',
            ),
            leading: const Icon(PhosphorIconsRegular.uploadSimple),
            onTap: () async {
              try {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['zip'],
                );
                if (result == null || result.files.single.path == null) return;
                if (!context.mounted) return;

                // Behind a pre-restore snapshot, like any other restore.
                await confirmAndRestoreBackup(
                  context,
                  ref,
                  File(result.files.single.path!),
                );
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
                }
              }
            },
          ),
          ListTile(
            title: const Text('About'),
            subtitle: Text(
              'Voyager — local-first journal and productivity\n'
              'Build $buildLabel',
            ),
            trailing: const Icon(PhosphorIconsRegular.copy, size: 18),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: buildLabel));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Build info copied')),
              );
            },
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
            ListTile(
              title: const Text('Finance hotkey'),
              subtitle: Text(settings.financeHotkey),
            ),
            ListTile(
              title: const Text('Reminder hotkey'),
              subtitle: Text(settings.reminderHotkey),
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

  /// Writes through [SettingsNotifier], which publishes the new value itself
  /// — invalidating instead would re-read the row and rebuild every page in
  /// the shell a second time for a value we already have.
  Future<void> _save(WidgetRef ref, AppSettings settings) {
    return ref.read(settingsProvider.notifier).saveSettings(settings);
  }

  String _statCountLabel(int? count) {
    if (count == null) return '—';
    return count.toString();
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

  String _startupPageLabel(AppSettings settings) {
    switch (settings.startupPageMode) {
      case StartupPageMode.first:
        return 'First page in navigation order';
      case StartupPageMode.lastSeen:
        return 'Last seen page';
      case StartupPageMode.custom:
        final path = settings.customStartupPage;
        if (path == null) return 'Custom (none selected)';
        final dest = shellDestinations.cast<ShellDestination?>().firstWhere(
          (d) => d?.path == path,
          orElse: () => null,
        );
        return dest != null ? 'Custom: ${dest.label}' : 'Custom: $path';
    }
  }

  Future<void> _showReorderNavDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final items = getOrderedDestinations(settings, shellDestinations).toList();

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Reorder navigation pages'),
              content: SizedBox(
                width: 320,
                child: ReorderableListView(
                  shrinkWrap: true,
                  // The default desktop handle makes only the trailing icon
                  // draggable; wrapping each row ourselves makes the whole
                  // option — icon, label and handle — the grab area.
                  buildDefaultDragHandles: false,
                  proxyDecorator: roundedDragProxy,
                  onReorder: (oldIndex, newIndex) {
                    if (oldIndex < newIndex) {
                      newIndex -= 1;
                    }
                    final item = items.removeAt(oldIndex);
                    items.insert(newIndex, item);
                    setState(() {});
                  },
                  children: [
                    for (var i = 0; i < items.length; i++)
                      ReorderableDragStartListener(
                        key: ValueKey(items[i].dest.path),
                        index: i,
                        child: ListTile(
                          leading: Icon(items[i].dest.icon),
                          title: Text(items[i].dest.label),
                          trailing: const Icon(Icons.drag_handle),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                GlassButton(
                  onPressed: () => Navigator.of(context).pop(),
                  label: 'Cancel',
                  dense: true,
                ),
                GlassButton(
                  onPressed: () {
                    final newOrder = items.map((e) => e.dest.path).toList();
                    _save(ref, settings.copyWith(navPageOrder: newOrder));
                    Navigator.of(context).pop();
                  },
                  label: 'Save',
                  dense: true,
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Names the slots that carry a link, so the tile says what the Jobs header
  /// will actually show without opening the dialog.
  static String _jobProfileSummary(AppSettings settings) {
    final filled = [
      if ((settings.jobProfileLinkedInUrl ?? '').isNotEmpty) 'LinkedIn',
      if ((settings.jobProfileGitHubUrl ?? '').isNotEmpty) 'GitHub',
      if ((settings.jobProfilePortfolioUrl ?? '').isNotEmpty) 'Portfolio',
    ];
    if (filled.isEmpty) {
      return 'Not set — no copy buttons on the Jobs page';
    }
    return '${filled.join(', ')} set';
  }

  Future<void> _showJobProfileDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _JobProfileDialog(
        settings: settings,
        onSave: (linkedIn, gitHub, portfolio) {
          _save(
            ref,
            settings.copyWith(
              jobProfileLinkedInUrl: linkedIn.isEmpty ? null : linkedIn,
              clearJobProfileLinkedInUrl: linkedIn.isEmpty,
              jobProfileGitHubUrl: gitHub.isEmpty ? null : gitHub,
              clearJobProfileGitHubUrl: gitHub.isEmpty,
              jobProfilePortfolioUrl: portfolio.isEmpty ? null : portfolio,
              clearJobProfilePortfolioUrl: portfolio.isEmpty,
            ),
          );
        },
      ),
    );
  }

  Future<void> _showLeetCodeUsernameDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    // Controller/FocusNode live on the dialog State — disposing them here after
    // showDialog returns races the dismiss animation (TextField still listening).
    await showDialog<void>(
      context: context,
      builder: (context) => _LeetCodeUsernameDialog(
        initialUsername: settings.leetcodeUsername ?? '',
        onSave: (value) {
          _save(
            ref,
            settings.copyWith(
              leetcodeUsername: value.isEmpty ? null : value,
              clearLeetcodeUsername: value.isEmpty,
            ),
          );
        },
      ),
    );
  }

  Future<void> _showStartupPageDialog(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final ordered = getOrderedDestinations(settings, shellDestinations);
    StartupPageMode mode = settings.startupPageMode;
    String? customPath = settings.customStartupPage;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Startup page'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<StartupPageMode>(
                    title: const Text('First page in navigation order'),
                    value: StartupPageMode.first,
                    groupValue: mode,
                    onChanged: (v) => setState(() => mode = v!),
                  ),
                  RadioListTile<StartupPageMode>(
                    title: const Text('Last seen page'),
                    value: StartupPageMode.lastSeen,
                    groupValue: mode,
                    onChanged: (v) => setState(() => mode = v!),
                  ),
                  RadioListTile<StartupPageMode>(
                    title: const Text('Custom page...'),
                    value: StartupPageMode.custom,
                    groupValue: mode,
                    onChanged: (v) {
                      setState(() {
                        mode = v!;
                        customPath ??= ordered.first.dest.path;
                      });
                    },
                  ),
                  if (mode == StartupPageMode.custom)
                    Padding(
                      padding: const EdgeInsets.only(left: 48, top: 8),
                      child: DropdownButtonFormField<String>(
                        value: customPath,
                        items: [
                          for (final d in shellDestinations)
                            DropdownMenuItem(
                              value: d.path,
                              child: Row(
                                children: [
                                  Icon(d.icon, size: 16),
                                  const SizedBox(width: 8),
                                  Text(d.label),
                                ],
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => customPath = v),
                      ),
                    ),
                ],
              ),
              actions: [
                GlassButton(
                  onPressed: () => Navigator.of(context).pop(),
                  label: 'Cancel',
                  dense: true,
                ),
                GlassButton(
                  onPressed: () {
                    _save(
                      ref,
                      settings.copyWith(
                        startupPageMode: mode,
                        customStartupPage: customPath,
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  label: 'Save',
                  dense: true,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Opens the app-wide spell-check dictionary, and counts the user's own words
/// in its subtitle.
///
/// Its own widget so that count — which changes every time a word is added
/// from a misspelling popup anywhere in the app — rebuilds one tile instead of
/// the whole settings page.
/// How much disk the image cache is using, plus the low-disk warning.
///
/// Its own widget rather than a row in the list above so that recomputing the
/// cache size — which walks the media directory — rebuilds only this tile and
/// not the whole settings page.
/// The automatic-backups switch and its status row — AUTO_BACKUP_HLD.md §9.
class _AutoBackupTiles extends ConsumerStatefulWidget {
  const _AutoBackupTiles();

  @override
  ConsumerState<_AutoBackupTiles> createState() => _AutoBackupTilesState();
}

class _AutoBackupTilesState extends ConsumerState<_AutoBackupTiles> {
  @override
  void initState() {
    super.initState();
    // Fresh each time Settings opens (§9.2).
    ref.read(autoBackupServiceProvider).refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(autoBackupServiceProvider);
    final status = service.status;
    final theme = Theme.of(context);

    final (Color? dot, String word) = switch (status?.health) {
      null => (null, ''),
      AutoBackupHealth.backingUp => (null, 'Backing up…'),
      AutoBackupHealth.off => (theme.colorScheme.outline, 'Off'),
      AutoBackupHealth.attention => (Colors.amber, 'Attention'),
      AutoBackupHealth.notYetBackedUp => (
        theme.colorScheme.outline,
        'Not yet backed up',
      ),
      AutoBackupHealth.due => (theme.colorScheme.outline, 'Due'),
      AutoBackupHealth.healthy => (Colors.green, 'Healthy'),
    };

    return Column(
      children: [
        SwitchListTile(
          title: const Text('Automatic backups'),
          subtitle: const Text(
            'A verified backup every day on this device: the last 3 days, '
            'one about a week old and one about a month old',
          ),
          value: status?.enabled ?? true,
          onChanged: status == null ? null : (v) => service.setEnabled(v),
        ),
        ListTile(
          leading: const Icon(PhosphorIconsRegular.shieldCheck),
          title: Text(
            status == null
                ? 'Reading backups…'
                : [
                        '${status.backupCount} '
                            '${status.backupCount == 1 ? 'backup' : 'backups'}',
                        if (status.snapshotCount > 0)
                          '+ ${status.snapshotCount} restore '
                              '${status.snapshotCount == 1 ? 'snapshot' : 'snapshots'}',
                      ].join(' ') +
                      ' · ${formatBackupBytes(status.totalBytes)}',
          ),
          subtitle: status == null ? null : Text(status.detail),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status?.health == AutoBackupHealth.backingUp)
                const SizedBox.square(
                  dimension: 10,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (dot != null)
                Icon(Icons.circle, size: 10, color: dot),
              const SizedBox(width: 6),
              Text(word, style: theme.textTheme.labelMedium),
              const SizedBox(width: 4),
              const Icon(PhosphorIconsRegular.caretRight),
            ],
          ),
          onTap: () => showBackupListDialog(context),
        ),
      ],
    );
  }
}

class _MediaStorageTile extends ConsumerWidget {
  const _MediaStorageTile();

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(mediaStorageUsageProvider).valueOrNull;
    final diskLow = ref.watch(mediaDiskLowProvider).valueOrNull ?? false;
    final theme = Theme.of(context);

    final pending = usage == null
        ? 0
        : usage.pendingUploadCount + usage.pendingDownloadCount;

    return ListTile(
      title: const Text('Image storage'),
      subtitle: Text(
        usage == null
            ? 'Measuring…'
            : [
                '${usage.assetCount} '
                    '${usage.assetCount == 1 ? 'image' : 'images'}',
                _formatBytes(usage.byteSize),
                if (pending > 0) '$pending waiting to sync',
                if (diskLow) 'Less than 5% of this disk is free',
              ].join(' · '),
        style: diskLow
            ? theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              )
            : null,
      ),
      trailing: Icon(
        diskLow
            ? PhosphorIconsRegular.warningCircle
            : PhosphorIconsRegular.hardDrives,
        color: diskLow ? theme.colorScheme.error : null,
      ),
      onTap: () => showMediaStorageDialog(context),
    );
  }
}

class _DictionaryTile extends ConsumerWidget {
  const _DictionaryTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(customWordsProvider).valueOrNull?.length ?? 0;
    final flagged = ref.watch(flaggedWordsProvider).valueOrNull?.length ?? 0;
    // Both numbers once either is non-zero: "custom words" alone stopped
    // describing this list when flags arrived (`FLAGGED_WORDS.md` §7).
    return ListTile(
      title: const Text('Dictionary'),
      subtitle: Text(
        count == 0 && flagged == 0
            ? 'Add extra words the spell checker should accept, or flag ones '
                  'it should mark'
            : flagged == 0
            ? '$count custom ${count == 1 ? 'word' : 'words'}'
            : '$count custom, $flagged flagged',
      ),
      trailing: const Icon(PhosphorIconsRegular.bookOpen),
      onTap: () => showDictionaryDialog(context),
    );
  }
}

/// Light-theme petal controls. Only mounted while the light theme is active.
///
/// Kept in the settings list (not a separate page) so tuning is immediate: the
/// background is live behind the settings sheet, so every slider change is
/// visible as it is dragged.
class _PetalSettings extends ConsumerWidget {
  const _PetalSettings({required this.settings, required this.onSave});

  final AppSettings settings;
  final Future<void> Function(AppSettings settings) onSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const Text('Petal color'),
          subtitle: Text(
            '${formatColorHex(settings.petalColor)} · '
            '${(petalColorWeights[settings.minorPetalColors.length][0] * 100).round()}% of petals',
          ),
          leading: CircleAvatar(backgroundColor: Color(settings.petalColor)),
          onTap: () => _pickPetalColor(context, ref),
        ),
        ..._minorColorTiles(context, ref),
        _PetalSlider(
          label: 'Max petals',
          value: settings.petalMaxCount.toDouble(),
          min: 0,
          max: 200,
          divisions: 40,
          valueLabel: settings.petalMaxCount.toString(),
          onChanged: (v) => onSave(settings.copyWith(petalMaxCount: v.round())),
        ),
        _PetalSlider(
          label: 'Fall speed',
          value: settings.petalFallSpeed,
          min: 8,
          max: 120,
          valueLabel: settings.petalFallSpeed.toStringAsFixed(0),
          onChanged: (v) => onSave(settings.copyWith(petalFallSpeed: v)),
        ),
        _PetalSlider(
          label: 'Wind frequency',
          value: settings.petalWindFrequency,
          min: 0.02,
          max: 0.6,
          valueLabel: '${settings.petalWindFrequency.toStringAsFixed(2)} Hz',
          onChanged: (v) => onSave(settings.copyWith(petalWindFrequency: v)),
        ),
        _PetalSlider(
          label: 'Wind burst strength',
          value: settings.petalWindStrength,
          min: 0,
          max: 160,
          valueLabel: settings.petalWindStrength.toStringAsFixed(0),
          onChanged: (v) => onSave(settings.copyWith(petalWindStrength: v)),
        ),
      ],
    );
  }

  Future<void> _pickPetalColor(BuildContext context, WidgetRef ref) async {
    // Ensure the current petal color is always selectable even when it isn't
    // one of the palette swatches (the default rose usually isn't).
    final palette = <int>[
      settings.petalColor,
      ...ref.read(colorPaletteProvider).where((c) => c != settings.petalColor),
    ];
    final picked = await pickColorFromPalette(
      context,
      palette: palette,
      current: settings.petalColor,
      title: 'Petal color',
    );
    if (picked != null) {
      await onSave(settings.copyWith(petalColor: picked));
    }
  }

  /// One tile per configured minor color plus a trailing "add" tile, capped
  /// at 3 minor colors total. See [petalColorWeights] for the ratio each
  /// count maps to.
  List<Widget> _minorColorTiles(BuildContext context, WidgetRef ref) {
    final minors = settings.minorPetalColors;
    final weights = petalColorWeights[minors.length];
    return [
      for (var i = 0; i < minors.length; i++)
        ListTile(
          title: Text('Minor color ${i + 1}'),
          subtitle: Text(
            '${formatColorHex(minors[i])} · '
            '${(weights[i + 1] * 100).round()}% of petals',
          ),
          leading: CircleAvatar(backgroundColor: Color(minors[i])),
          onTap: () => _pickMinorPetalColor(context, ref, i),
          trailing: IconButton(
            icon: const Icon(PhosphorIconsRegular.trash),
            tooltip: 'Remove minor color',
            onPressed: () => _removeMinorPetalColor(i),
          ),
        ),
      if (minors.length < 3)
        ListTile(
          title: const Text('Add minor color'),
          leading: const Icon(PhosphorIconsRegular.plus),
          onTap: () => _addMinorPetalColor(context, ref),
        ),
    ];
  }

  Future<void> _pickMinorPetalColor(
    BuildContext context,
    WidgetRef ref,
    int index,
  ) async {
    final current = settings.minorPetalColors[index];
    final palette = <int>[
      current,
      ...ref.read(colorPaletteProvider).where((c) => c != current),
    ];
    final picked = await pickColorFromPalette(
      context,
      palette: palette,
      current: current,
      title: 'Minor color ${index + 1}',
    );
    if (picked != null) {
      final updated = List<int>.from(settings.minorPetalColors);
      updated[index] = picked;
      await onSave(settings.copyWith(minorPetalColors: updated));
    }
  }

  Future<void> _addMinorPetalColor(BuildContext context, WidgetRef ref) async {
    if (settings.minorPetalColors.length >= 3) return;
    final palette = ref.read(colorPaletteProvider);
    final picked = await pickColorFromPalette(
      context,
      palette: palette,
      current: palette.isNotEmpty ? palette.first : null,
      title: 'Add minor color',
    );
    if (picked != null) {
      final updated = List<int>.from(settings.minorPetalColors)..add(picked);
      await onSave(settings.copyWith(minorPetalColors: updated));
    }
  }

  Future<void> _removeMinorPetalColor(int index) async {
    final updated = List<int>.from(settings.minorPetalColors)..removeAt(index);
    await onSave(settings.copyWith(minorPetalColors: updated));
  }
}

/// The dark theme's counterpart to [_PetalSettings]: the few geometric
/// background knobs worth owning outside Dev. The rest (scale, focal point,
/// variation floor, wave shape and timing) stay in the Dev panels.
///
/// Goes through the params notifiers rather than [AppSettings] directly, so a
/// drag repaints the grid live and persists once, debounced.
class _GeometricSettings extends ConsumerWidget {
  const _GeometricSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final texture = ref.watch(geometricTextureParamsProvider);
    final wave = ref.watch(geometricWaveParamsProvider);
    final textureNotifier = ref.read(geometricTextureParamsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PetalSlider(
          label: 'Grid intensity',
          value: texture.intensity,
          min: 0,
          max: 1,
          divisions: 100,
          valueLabel: '${(texture.intensity * 100).round()}%',
          onChanged: (v) =>
              textureNotifier.update(texture.copyWith(intensity: v)),
        ),
        _PetalSlider(
          label: 'Glow spread',
          value: texture.focalSpread,
          min: 0.1,
          max: 2,
          divisions: 190,
          valueLabel: texture.focalSpread.toStringAsFixed(2),
          onChanged: (v) =>
              textureNotifier.update(texture.copyWith(focalSpread: v)),
        ),
        SwitchListTile(
          title: const Text('Wave'),
          subtitle: const Text('Triangles lift in a sweep across the grid'),
          value: wave.enabled,
          onChanged: (v) => ref
              .read(geometricWaveParamsProvider.notifier)
              .update(wave.copyWith(enabled: v)),
        ),
      ],
    );
  }
}

class _PetalSlider extends StatelessWidget {
  const _PetalSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.valueLabel,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String valueLabel;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
              Text(
                valueLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Owns the username field's controller and focus node so Enter-to-save cannot
/// dispose them while the dialog's dismiss animation still rebuilds the field.
/// Edits all three profile-link slots together (§3.4). One save path, so the
/// three `clear` flags travel in a single [AppSettings.copyWith].
class _JobProfileDialog extends StatefulWidget {
  const _JobProfileDialog({required this.settings, required this.onSave});

  final AppSettings settings;
  final void Function(String linkedIn, String gitHub, String portfolio) onSave;

  @override
  State<_JobProfileDialog> createState() => _JobProfileDialogState();
}

class _JobProfileDialogState extends State<_JobProfileDialog> {
  late final _linkedInController = TextEditingController(
    text: widget.settings.jobProfileLinkedInUrl ?? '',
  );
  late final _gitHubController = TextEditingController(
    text: widget.settings.jobProfileGitHubUrl ?? '',
  );
  late final _portfolioController = TextEditingController(
    text: widget.settings.jobProfilePortfolioUrl ?? '',
  );

  @override
  void dispose() {
    _linkedInController.dispose();
    _gitHubController.dispose();
    _portfolioController.dispose();
    super.dispose();
  }

  void _submit() {
    widget.onSave(
      _linkedInController.text.trim(),
      _gitHubController.text.trim(),
      _portfolioController.text.trim(),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Job application profile'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(
              controller: _linkedInController,
              label: 'LinkedIn',
              hint: 'https://linkedin.com/in/…',
              autofocus: true,
            ),
            const SizedBox(height: 12),
            _field(
              controller: _gitHubController,
              label: 'GitHub',
              hint: 'https://github.com/…',
            ),
            const SizedBox(height: 12),
            _field(
              controller: _portfolioController,
              label: 'Portfolio',
              hint: 'https://…',
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
        ),
        GlassButton(dense: true, onPressed: _submit, label: 'Save'),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool autofocus = false,
  }) {
    return VoyagerTextField(
      controller: controller,
      autofocus: autofocus,
      // Enter commits from any of the three, the way the one-field dialogs
      // in this page already behave.
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        contentPadding: kM3OutlinedContentPadding,
      ),
    );
  }
}

class _LeetCodeUsernameDialog extends StatefulWidget {
  const _LeetCodeUsernameDialog({
    required this.initialUsername,
    required this.onSave,
  });

  final String initialUsername;
  final ValueChanged<String> onSave;

  @override
  State<_LeetCodeUsernameDialog> createState() =>
      _LeetCodeUsernameDialogState();
}

class _LeetCodeUsernameDialogState extends State<_LeetCodeUsernameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialUsername,
  );
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    // Enter does exactly what Save does. A one-field dialog that makes you
    // reach for the mouse to commit a name you just finished typing is
    // asking for a step the keyboard already offered.
    widget.onSave(_controller.text.trim());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('LeetCode username'),
      content: VimTextScope(
        enabled: VimEnabledScope.of(context) && vimSuitsField(),
        controller: _controller,
        multiline: false,
        builder: (context, vim) {
          final theme = Theme.of(context);
          final textStyle = theme.textTheme.bodyLarge ?? const TextStyle();
          const hintText = 'e.g. johndoe123';
          return VimOverlayHost(
            session: vim.session,
            snippetSession: vim.snippetSession,
            overlayPaintsSelection: vim.overlayPaintsSelection,
            controller: _controller,
            focusNode: _focusNode,
            style: textStyle,
            accentColor: theme.colorScheme.primary,
            overlayPadding: vimOverlayPadding(
              contentPadding: kM3OutlinedContentPadding,
              density: theme.visualDensity,
              cursorWidth: vim.overlayCaretWidth,
              outlineGap: true,
              outlineCenter: true,
            ),
            hintText: hintText,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: textStyle,
              cursorColor: vim.overlayCaretColor(theme.colorScheme.primary),
              cursorWidth: vim.overlayCaretWidth,
              undoController: vim.undoController,
              scrollPadding: kVoyagerFieldScrollPadding,
              scrollPhysics: const VoyagerFieldScrollPhysics(),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                hintText: hintText,
                contentPadding: kM3OutlinedContentPadding,
              ),
            ),
          );
        },
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
          dense: true,
        ),
        GlassButton(onPressed: _submit, label: 'Save', dense: true),
      ],
    );
  }
}
