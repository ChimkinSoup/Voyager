import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/hotkey_defaults.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/key_binding.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/petal_field.dart' show petalColorWeights;
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/settings/key_binding_dialog.dart';
import 'package:voyager/features/settings/settings_color_palette_section.dart';
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
            _PetalSettings(settings: settings, onSave: (s) => _save(ref, s)),
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
          SwitchListTile(
            title: const Text('Week starts on Monday'),
            value: settings.weekStartsOnMonday,
            onChanged: (v) async {
              if (v != settings.weekStartsOnMonday) {
                await _reanchorWeeklyValues(ref, weekStartsMonday: v);
              }
              await _save(ref, settings.copyWith(weekStartsOnMonday: v));
            },
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
          Text('Dream Journal', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text('Show dream statistics in analytics'),
            subtitle: const Text(
              'Adds a stat to the analytics page showing whether you logged '
              'a dream each day',
            ),
            value: settings.showDreamStatistics,
            onChanged: (v) => _save(
              ref,
              settings.copyWith(showDreamStatistics: v),
            ),
          ),
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
            title: const Text('Export Backup'),
            subtitle: const Text(
              'Export all journal entries and tasks to a ZIP file',
            ),
            leading: const Icon(PhosphorIconsRegular.downloadSimple),
            onTap: () async {
              try {
                String? selectedDirectory = await FilePicker.platform
                    .getDirectoryPath();
                if (selectedDirectory == null) return;

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Exporting backup...')),
                  );
                }

                final file = await ref
                    .read(dataExportServiceProvider)
                    .exportDataToZip();

                final finalPath =
                    '$selectedDirectory/voyager_backup_${DateTime.now().millisecondsSinceEpoch}.zip';
                await file.copy(finalPath);
                await file.delete();

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Backup exported to: $finalPath'),
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
              'Restore journal entries and tasks from a ZIP file',
            ),
            leading: const Icon(PhosphorIconsRegular.uploadSimple),
            onTap: () async {
              try {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['zip'],
                );
                if (result == null || result.files.single.path == null) return;

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Importing backup...')),
                  );
                }

                final file = File(result.files.single.path!);
                await ref.read(dataImportServiceProvider).importFromZip(file);

                // Refresh UI caches immediately
                ref.invalidate(journalsProvider);
                ref.invalidate(journalEntriesProvider);
                ref.invalidate(journalListEntriesProvider);
                ref.invalidate(journalEntryCountsProvider);
                ref.invalidate(journalAllEntryIdsProvider);
                ref.invalidate(todoListsProvider);
                ref.invalidate(todoTasksProvider);
                ref.invalidate(allTodoTasksProvider);
                ref.invalidate(todoListStatsProvider);

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Backup imported successfully! Draining sync queue...',
                      ),
                      duration: Duration(seconds: 4),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
                }
              }
            },
          ),
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

  /// Weekly tracker values are stored on their week's start day, which depends
  /// on the "week starts on Monday" setting. When that setting flips, every
  /// existing weekly value would otherwise land on the "wrong" weekday and
  /// vanish from the weekly grid (resurfacing as stray daily data). Re-anchor
  /// them to the new week-start so nothing is orphaned.
  Future<void> _reanchorWeeklyValues(
    WidgetRef ref, {
    required bool weekStartsMonday,
  }) async {
    final trackerRepo = ref.read(trackerRepositoryProvider);
    final promptService = ref.read(periodicPromptServiceProvider);
    final trackers = await trackerRepo.listTrackers();
    final now = utcNow();
    for (final tracker in trackers) {
      if (tracker.cadence != TrackerCadence.weekly) continue;
      final values = await trackerRepo.listValues(tracker.id);
      for (final value in values) {
        final anchored = promptService.periodStartFor(
          value.periodStart,
          TrackerCadence.weekly,
          weekStartsMonday: weekStartsMonday,
        );
        if (anchored.year == value.periodStart.year &&
            anchored.month == value.periodStart.month &&
            anchored.day == value.periodStart.day) {
          continue;
        }
        await trackerRepo.upsertValue(
          TrackerValue(
            id: value.id,
            trackerId: value.trackerId,
            periodStart: anchored,
            intValue: value.intValue,
            boolValue: value.boolValue,
            enumValue: value.enumValue,
            createdAt: value.createdAt,
            updatedAt: now,
            deletedAt: value.deletedAt,
          ),
        );
      }
    }
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
                      ListTile(
                        key: ValueKey(items[i].dest.path),
                        leading: Icon(items[i].dest.icon),
                        title: Text(items[i].dest.label),
                        trailing: const Icon(Icons.drag_handle),
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
          onChanged: (v) =>
              onSave(settings.copyWith(petalMaxCount: v.round())),
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
      ...ref
          .read(colorPaletteProvider)
          .where((c) => c != settings.petalColor),
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
    final updated = List<int>.from(settings.minorPetalColors)
      ..removeAt(index);
    await onSave(settings.copyWith(minorPetalColors: updated));
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
                  color: Theme.of(context).colorScheme.onSurface.withValues(
                    alpha: 0.7,
                  ),
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
