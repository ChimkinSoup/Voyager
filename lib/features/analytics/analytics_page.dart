import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/analytics/heatmap_calendar.dart';
import 'package:voyager/features/analytics/ranking_prompt_banner.dart';
import 'package:voyager/features/shell/shell_page_storage_keys.dart';

class AnalyticsPage extends ConsumerWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(journalEntriesProvider);
    final trackersAsync = ref.watch(trackersProvider);
    final rankingConfigsAsync = ref.watch(rankingConfigsProvider);
    final analytics = ref.watch(analyticsServiceProvider);
    final prompt = ref.watch(periodicPromptServiceProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: entriesAsync.when(
        data: (entries) => trackersAsync.when(
          data: (trackers) => rankingConfigsAsync.when(
            data: (rankingConfigs) {
              final words = entries.fold<int>(
                0,
                (sum, e) => sum + analytics.countWords(e.body),
              );
              final streak = prompt.longestJournalStreak(entries);
              final calendarTrackers = trackers
                  .where((t) => t.showOnCalendar)
                  .toList();
              return KeepAliveScrollView(
                storageKey: ShellPageStorageKeys.analyticsList,
                children: [
                  Text(
                    'Total entries: ${analytics.totalJournalEntries(entries)}',
                  ),
                  Text('Words written: $words'),
                  Text('Longest streak: $streak days'),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 200,
                    child: LineChart(
                      LineChartData(
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (var i = 0; i < entries.length; i++)
                                FlSpot(
                                  i.toDouble(),
                                  analytics
                                      .countWords(entries[i].body)
                                      .toDouble(),
                                ),
                            ],
                            isCurved: true,
                            preventCurveOverShooting: true,
                            preventCurveOvershootingThreshold: 0,
                            color: Theme.of(context).colorScheme.primary,
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _RankingsSection(configs: rankingConfigs),
                  if (calendarTrackers.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    _TrackerHeatmap(tracker: calendarTrackers.first),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text(
                        'Statistic Trackers',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => _createTracker(context, ref),
                        icon: const Icon(PhosphorIconsRegular.plus),
                        label: const Text('New tracker'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (trackers.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No trackers yet. Create one to start logging custom stats.',
                        ),
                      ),
                    ),
                  ...trackers.map(
                    (tracker) => _TrackerCard(
                      tracker: tracker,
                      weekStartsMonday:
                          ref
                              .watch(settingsProvider)
                              .value
                              ?.weekStartsOnMonday ??
                          true,
                      onToggleCalendar: (value) async {
                        await ref
                            .read(trackerRepositoryProvider)
                            .upsertTracker(
                              tracker.copyWith(showOnCalendar: value),
                            );
                        ref.invalidate(trackersProvider);
                      },
                    ),
                  ),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }

  Future<void> _createTracker(BuildContext context, WidgetRef ref) async {
    final tracker = await showDialog<StatisticTracker>(
      context: context,
      builder: (_) => const _TrackerDialog(),
    );
    if (tracker == null) return;
    await ref.read(trackerRepositoryProvider).upsertTracker(tracker);
    ref.invalidate(trackersProvider);
  }
}

class _RankingsSection extends ConsumerWidget {
  const _RankingsSection({required this.configs});

  final List<RankingConfig> configs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Periodic Rankings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => _createRanking(context, ref),
              icon: const Icon(PhosphorIconsRegular.plus),
              label: const Text('New ranking'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (configs.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No rankings yet. Create one to get prompted on its cadence.',
              ),
            ),
          ),
        for (final config in configs) _RankingCard(config: config),
      ],
    );
  }

  Future<void> _createRanking(BuildContext context, WidgetRef ref) async {
    final config = await showDialog<RankingConfig>(
      context: context,
      builder: (_) => const _RankingDialog(),
    );
    if (config == null) return;
    await ref.read(trackerRepositoryProvider).upsertRankingConfig(config);
    ref.invalidate(rankingConfigsProvider);
  }
}

class _RankingCard extends ConsumerWidget {
  const _RankingCard({required this.config});

  final RankingConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(rankingValuesProvider(config.id));
    final weekStartsMonday =
        ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: valuesAsync.when(
          data: (values) {
            final sorted = [...values]
              ..sort((a, b) => a.periodStart.compareTo(b.periodStart));
            final lastCompleted = sorted.isEmpty
                ? null
                : sorted.last.periodStart;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        config.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text('${config.cadence.name} / 1-${config.maxValue}'),
                  ],
                ),
                const SizedBox(height: 8),
                RankingPromptBanner(
                  cadence: config.cadence,
                  maxValue: config.maxValue,
                  lastCompleted: lastCompleted,
                  weekStartsMonday: weekStartsMonday,
                  onSubmit: (value) =>
                      _saveRanking(ref, value, weekStartsMonday),
                ),
                if (sorted.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 120,
                    child: LineChart(
                      LineChartData(
                        minY: 1,
                        maxY: config.maxValue.toDouble(),
                        gridData: const FlGridData(show: false),
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: [
                              for (var i = 0; i < sorted.length; i++)
                                FlSpot(
                                  i.toDouble(),
                                  sorted[i].value.toDouble(),
                                ),
                            ],
                            isCurved: true,
                            preventCurveOverShooting: true,
                            preventCurveOvershootingThreshold: 0,
                            color: Color(config.colorStart),
                            dotData: const FlDotData(show: false),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
        ),
      ),
    );
  }

  Future<void> _saveRanking(
    WidgetRef ref,
    int value,
    bool weekStartsMonday,
  ) async {
    final periodStart = _periodStart(
      DateTime.now(),
      config.cadence,
      weekStartsMonday: weekStartsMonday,
    );
    final now = utcNow();
    await ref
        .read(trackerRepositoryProvider)
        .upsertRankingValue(
          RankingValue(
            id: '${config.id}_${periodStart.millisecondsSinceEpoch}',
            configId: config.id,
            periodStart: periodStart,
            value: value,
            createdAt: now,
            updatedAt: now,
          ),
        );
    ref.invalidate(rankingValuesProvider(config.id));
  }
}

class _RankingDialog extends ConsumerStatefulWidget {
  const _RankingDialog();

  @override
  ConsumerState<_RankingDialog> createState() => _RankingDialogState();
}

class _RankingDialogState extends ConsumerState<_RankingDialog> {
  final _nameController = TextEditingController(text: 'Weekly review');
  final _maxController = TextEditingController(text: '10');
  var _cadence = TrackerCadence.weekly;
  late int _colorStart;
  late int _colorEnd;
  var _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final palette = ref.read(colorPaletteProvider);
    _colorStart = palette.contains(0xFF4CAF50)
        ? 0xFF4CAF50
        : palette.first;
    _colorEnd = palette.contains(0xFFF44336) ? 0xFFF44336 : palette.last;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New periodic ranking'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            VoyagerTextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            VoyagerDropdownButtonFormField<TrackerCadence>(
              initialValue: _cadence,
              decoration: const InputDecoration(labelText: 'Cadence'),
              items: TrackerCadence.values
                  .map(
                    (cadence) => DropdownMenuItem(
                      value: cadence,
                      child: Text(cadence.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _cadence = value ?? _cadence),
            ),
            const SizedBox(height: 12),
            VoyagerTextField(
              controller: _maxController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Max value'),
            ),
            const SizedBox(height: 12),
            ColorPickerField(
              label: 'Low score color',
              value: _colorStart,
              onChanged: (value) => setState(() => _colorStart = value),
            ),
            const SizedBox(height: 12),
            ColorPickerField(
              label: 'High score color',
              value: _colorEnd,
              onChanged: (value) => setState(() => _colorEnd = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    final maxValue = int.tryParse(_maxController.text.trim()) ?? 10;
    if (name.isEmpty || maxValue < 2) return;
    final now = utcNow();
    Navigator.pop(
      context,
      RankingConfig(
        id: newId(),
        name: name,
        cadence: _cadence,
        maxValue: maxValue,
        colorStart: _colorStart,
        colorEnd: _colorEnd,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
}

class _TrackerHeatmap extends ConsumerWidget {
  const _TrackerHeatmap({required this.tracker});

  final StatisticTracker tracker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valuesAsync = ref.watch(trackerValuesProvider(tracker.id));
    return valuesAsync.when(
      data: (values) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${tracker.name} calendar heatmap',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          HeatmapCalendar(
            tracker: tracker,
            values: values,
            month: DateTime.now(),
          ),
        ],
      ),
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('$e'),
    );
  }
}

class _TrackerCard extends ConsumerStatefulWidget {
  const _TrackerCard({
    required this.tracker,
    required this.weekStartsMonday,
    required this.onToggleCalendar,
  });

  final StatisticTracker tracker;
  final bool weekStartsMonday;
  final ValueChanged<bool> onToggleCalendar;

  @override
  ConsumerState<_TrackerCard> createState() => _TrackerCardState();
}

class _TrackerCardState extends ConsumerState<_TrackerCard> {
  final _intController = TextEditingController();
  String? _loadedValueId;

  @override
  void dispose() {
    _intController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valuesAsync = ref.watch(trackerValuesProvider(widget.tracker.id));
    final periodStart = _periodStart(
      DateTime.now(),
      widget.tracker.cadence,
      weekStartsMonday: widget.weekStartsMonday,
    );

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: valuesAsync.when(
          data: (values) {
            final current = values.cast<TrackerValue?>().firstWhere(
              (value) =>
                  value != null &&
                  _samePeriod(
                    value.periodStart,
                    periodStart,
                    widget.tracker.cadence,
                  ),
              orElse: () => null,
            );
            _syncIntegerController(current);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 6,
                      backgroundColor: Color(widget.tracker.colorValue),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.tracker.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Switch(
                      value: widget.tracker.showOnCalendar,
                      onChanged: widget.onToggleCalendar,
                    ),
                  ],
                ),
                Text(
                  '${_typeLabel(widget.tracker.type)} / ${widget.tracker.cadence.name}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _valueEditor(current: current, periodStart: periodStart),
                if (values.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _TrackerHistoryChart(tracker: widget.tracker, values: values),
                ],
              ],
            );
          },
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
        ),
      ),
    );
  }

  void _syncIntegerController(TrackerValue? value) {
    if (widget.tracker.type != TrackerType.integer) return;
    if (_loadedValueId == value?.id) return;
    _loadedValueId = value?.id;
    _intController.text = (value?.intValue ?? widget.tracker.defaultInt)
        .toString();
  }

  Widget _valueEditor({
    required TrackerValue? current,
    required DateTime periodStart,
  }) {
    switch (widget.tracker.type) {
      case TrackerType.integer:
        final cap = widget.tracker.integerCap;
        final parsed =
            int.tryParse(_intController.text) ?? widget.tracker.defaultInt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cap != null)
              Slider(
                min: 0,
                max: cap.toDouble(),
                divisions: cap == 0 ? null : cap,
                label: parsed.clamp(0, cap).toString(),
                value: parsed.clamp(0, cap).toDouble(),
                onChanged: (value) {
                  setState(
                    () => _intController.text = value.round().toString(),
                  );
                },
                onChangeEnd: (_) => _saveInteger(current, periodStart),
              ),
            Row(
              children: [
                SizedBox(
                  width: 160,
                  child: VoyagerTextField(
                    controller: _intController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Current ${widget.tracker.cadence.name} value',
                      helperText: cap == null ? null : '0-$cap',
                    ),
                    onSubmitted: (_) => _saveInteger(current, periodStart),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _saveInteger(current, periodStart),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        );
      case TrackerType.boolean:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Completed for this period'),
          value: current?.boolValue ?? widget.tracker.defaultBool,
          onChanged: (value) => _saveValue(
            current: current,
            periodStart: periodStart,
            boolValue: value,
          ),
        );
      case TrackerType.enumType:
        final options = widget.tracker.enumOptions;
        final currentValue =
            current?.enumValue ?? widget.tracker.defaultEnumOption;
        return VoyagerDropdownButtonFormField<String>(
          initialValue: options.contains(currentValue) ? currentValue : null,
          decoration: const InputDecoration(labelText: 'Current value'),
          items: options
              .map(
                (option) =>
                    DropdownMenuItem(value: option, child: Text(option)),
              )
              .toList(),
          onChanged: (value) => _saveValue(
            current: current,
            periodStart: periodStart,
            enumValue: value,
          ),
        );
    }
  }

  Future<void> _saveInteger(TrackerValue? current, DateTime periodStart) async {
    final raw = int.tryParse(_intController.text.trim());
    if (raw == null) return;
    final cap = widget.tracker.integerCap;
    final value = cap == null ? raw : raw.clamp(0, cap);
    await _saveValue(
      current: current,
      periodStart: periodStart,
      intValue: value,
    );
  }

  Future<void> _saveValue({
    required TrackerValue? current,
    required DateTime periodStart,
    int? intValue,
    bool? boolValue,
    String? enumValue,
  }) async {
    final now = utcNow();
    final value = TrackerValue(
      id:
          current?.id ??
          '${widget.tracker.id}_${periodStart.millisecondsSinceEpoch}',
      trackerId: widget.tracker.id,
      periodStart: periodStart,
      intValue: intValue,
      boolValue: boolValue,
      enumValue: enumValue,
      createdAt: current?.createdAt ?? now,
      updatedAt: now,
    );
    await ref.read(trackerRepositoryProvider).upsertValue(value);
    ref.invalidate(trackerValuesProvider(widget.tracker.id));
  }
}

class _TrackerHistoryChart extends StatelessWidget {
  const _TrackerHistoryChart({required this.tracker, required this.values});

  final StatisticTracker tracker;
  final List<TrackerValue> values;

  @override
  Widget build(BuildContext context) {
    final sorted = [...values]
      ..sort((a, b) => a.periodStart.compareTo(b.periodStart));
    final spots = <FlSpot>[
      for (var i = 0; i < sorted.length; i++)
        FlSpot(i.toDouble(), _numericValue(sorted[i])),
    ];
    if (spots.isEmpty) return const SizedBox.shrink();

    final maxY = switch (tracker.type) {
      TrackerType.integer =>
        (tracker.integerCap ??
                spots
                    .map((spot) => spot.y)
                    .fold<double>(1, (max, y) => y > max ? y : max))
            .toDouble(),
      TrackerType.boolean => 1.0,
      TrackerType.enumType => 1.0,
    };

    return SizedBox(
      height: 110,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY <= 0 ? 1 : maxY,
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: tracker.type == TrackerType.integer,
              preventCurveOverShooting: true,
              preventCurveOvershootingThreshold: 0,
              color: Color(tracker.colorValue),
              dotData: FlDotData(show: spots.length <= 12),
              belowBarData: BarAreaData(
                show: true,
                color: Color(tracker.colorValue).withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _numericValue(TrackerValue value) {
    return switch (tracker.type) {
      TrackerType.integer => (value.intValue ?? 0).toDouble(),
      TrackerType.boolean => value.boolValue == true ? 1 : 0,
      TrackerType.enumType =>
        value.enumValue == null || value.enumValue!.isEmpty ? 0 : 1,
    };
  }
}

class _TrackerDialog extends ConsumerStatefulWidget {
  const _TrackerDialog();

  @override
  ConsumerState<_TrackerDialog> createState() => _TrackerDialogState();
}

class _TrackerDialogState extends ConsumerState<_TrackerDialog> {
  final _nameController = TextEditingController();
  final _defaultIntController = TextEditingController(text: '0');
  final _capController = TextEditingController(text: '10');
  final _optionsController = TextEditingController();
  var _type = TrackerType.integer;
  var _cadence = TrackerCadence.daily;
  late int _colorValue;
  var _initialized = false;
  var _showOnCalendar = false;
  var _hasCap = false;
  var _defaultBool = false;
  String? _defaultEnumOption;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final palette = ref.read(colorPaletteProvider);
    _colorValue = palette.isNotEmpty ? palette.first : defaultColorPalette.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _defaultIntController.dispose();
    _capController.dispose();
    _optionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enumOptions = _enumOptions;
    return AlertDialog(
      title: const Text('New statistic tracker'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              VoyagerTextField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              VoyagerDropdownButtonFormField<TrackerType>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: TrackerType.values
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(_typeLabel(type)),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _type = value ?? _type),
              ),
              const SizedBox(height: 12),
              VoyagerDropdownButtonFormField<TrackerCadence>(
                initialValue: _cadence,
                decoration: const InputDecoration(labelText: 'Cadence'),
                items: TrackerCadence.values
                    .map(
                      (cadence) => DropdownMenuItem(
                        value: cadence,
                        child: Text(cadence.name),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => _cadence = value ?? _cadence),
              ),
              const SizedBox(height: 12),
              ColorPickerField(
                label: 'Tracker color',
                value: _colorValue,
                onChanged: (value) => setState(() => _colorValue = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show on calendar'),
                value: _showOnCalendar,
                onChanged: (value) => setState(() => _showOnCalendar = value),
              ),
              if (_type == TrackerType.integer) ...[
                VoyagerTextField(
                  controller: _defaultIntController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Default value'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use cap'),
                  value: _hasCap,
                  onChanged: (value) => setState(() => _hasCap = value),
                ),
                if (_hasCap)
                  VoyagerTextField(
                    controller: _capController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Cap'),
                  ),
              ],
              if (_type == TrackerType.boolean)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default checked'),
                  value: _defaultBool,
                  onChanged: (value) => setState(() => _defaultBool = value),
                ),
              if (_type == TrackerType.enumType) ...[
                VoyagerTextField(
                  controller: _optionsController,
                  decoration: const InputDecoration(
                    labelText: 'Options',
                    helperText: 'Comma-separated, e.g. Gym A, Gym B',
                  ),
                  onChanged: (_) => setState(() {
                    if (!enumOptions.contains(_defaultEnumOption)) {
                      _defaultEnumOption = null;
                    }
                  }),
                ),
                const SizedBox(height: 12),
                VoyagerDropdownButtonFormField<String>(
                  initialValue: enumOptions.contains(_defaultEnumOption)
                      ? _defaultEnumOption
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Default option',
                  ),
                  items: enumOptions
                      .map(
                        (option) => DropdownMenuItem(
                          value: option,
                          child: Text(option),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _defaultEnumOption = value),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  List<String> get _enumOptions => _optionsController.text
      .split(',')
      .map((option) => option.trim())
      .where((option) => option.isNotEmpty)
      .toSet()
      .toList();

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final enumOptions = _enumOptions;
    if (_type == TrackerType.enumType && enumOptions.isEmpty) return;
    final now = utcNow();
    Navigator.pop(
      context,
      StatisticTracker(
        id: newId(),
        name: name,
        type: _type,
        cadence: _cadence,
        colorValue: _colorValue,
        showOnCalendar: _showOnCalendar,
        integerCap: _type == TrackerType.integer && _hasCap
            ? int.tryParse(_capController.text.trim())
            : null,
        defaultInt: int.tryParse(_defaultIntController.text.trim()) ?? 0,
        defaultBool: _defaultBool,
        enumOptions: enumOptions,
        defaultEnumOption: _defaultEnumOption,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
}

String _typeLabel(TrackerType type) {
  return switch (type) {
    TrackerType.integer => 'Integer',
    TrackerType.boolean => 'Boolean',
    TrackerType.enumType => 'Dropdown',
  };
}

DateTime _periodStart(
  DateTime date,
  TrackerCadence cadence, {
  required bool weekStartsMonday,
}) {
  final local = DateTime(date.year, date.month, date.day);
  return switch (cadence) {
    TrackerCadence.daily => local,
    TrackerCadence.weekly => local.subtract(
      Duration(
        days: weekStartsMonday
            ? local.weekday - DateTime.monday
            : local.weekday % 7,
      ),
    ),
    TrackerCadence.monthly => DateTime(local.year, local.month),
    TrackerCadence.yearly => DateTime(local.year),
  };
}

bool _samePeriod(DateTime a, DateTime b, TrackerCadence cadence) {
  final normalizedA = _periodStart(a, cadence, weekStartsMonday: true);
  final normalizedB = _periodStart(b, cadence, weekStartsMonday: true);
  return normalizedA.year == normalizedB.year &&
      normalizedA.month == normalizedB.month &&
      normalizedA.day == normalizedB.day;
}
