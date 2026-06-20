import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/event_editor_dialog.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  CalendarViewMode _mode = CalendarViewMode.month;
  DateTime _focused = DateTime.now();

  Future<void> _openEditor({CalendarEvent? event, DateTime? day}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => EventEditorDialog(event: event, initialDate: day ?? _focused),
    );
    if (result == null || (result['title'] as String).isEmpty) return;

    final now = utcNow();
    final saved = CalendarEvent(
      id: event?.id ?? newId(),
      title: result['title'] as String,
      start: result['start'] as DateTime,
      end: result['end'] as DateTime,
      isFullDay: result['isFullDay'] as bool,
      colorValue: result['colorValue'] as int,
      notes: result['notes'] as String,
      source: event?.source ?? EventSource.local,
      externalId: event?.externalId,
      createdAt: event?.createdAt ?? now,
      updatedAt: now,
    );
    await ref.read(calendarRepositoryProvider).upsertEvent(saved);
    ref.invalidate(calendarEventsProvider);
  }

  Future<void> _syncGoogle() async {
    final service = ref.read(googleCalendarSyncProvider);
    await service.syncReadOnly(const []);
    ref.invalidate(calendarEventsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google Calendar sync complete (read-only)')),
      );
    }
  }

  void _shiftFocus(int delta) {
    setState(() {
      _focused = switch (_mode) {
        CalendarViewMode.week => _focused.add(Duration(days: 7 * delta)),
        CalendarViewMode.month => DateTime(_focused.year, _focused.month + delta, 1),
        CalendarViewMode.year => DateTime(_focused.year + delta, 1, 1),
      };
    });
  }

  String get _headerLabel => switch (_mode) {
        CalendarViewMode.week => 'Week of ${DateFormat.MMMd().format(_focused)}',
        CalendarViewMode.month => DateFormat.yMMMM().format(_focused),
        CalendarViewMode.year => '${_focused.year}',
      };

  @override
  Widget build(BuildContext context) {
    final eventsAsync = ref.watch(calendarEventsProvider);
    final trackers = ref.watch(trackersProvider).value ?? const <StatisticTracker>[];
    final analytics = ref.watch(analyticsServiceProvider);
    final weekStartsMonday = ref.watch(settingsProvider).value?.weekStartsOnMonday ?? true;
    final calendarTrackers = trackers.where((tracker) => tracker.showOnCalendar).toList();
    final indicators = <CalendarDayIndicator>[];
    for (final tracker in calendarTrackers) {
      final values = ref.watch(trackerValuesProvider(tracker.id)).value ?? const <TrackerValue>[];
      final max = values.fold<int>(0, (max, value) {
        final current = value.intValue ?? 0;
        return current > max ? current : max;
      });
      for (final value in values) {
        indicators.add(
          CalendarDayIndicator(
            day: value.periodStart,
            colorValue: tracker.colorValue,
            label: '${tracker.name}: ${_trackerValueLabel(tracker, value)}',
            intensity: analytics.heatmapIntensity(
              type: tracker.type,
              value: value,
              tracker: tracker,
              maxInPeriod: max == 0 ? 1 : max,
            ),
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SegmentedButton<CalendarViewMode>(
                segments: const [
                  ButtonSegment(value: CalendarViewMode.week, label: Text('Week')),
                  ButtonSegment(value: CalendarViewMode.month, label: Text('Month')),
                  ButtonSegment(value: CalendarViewMode.year, label: Text('Year')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const Spacer(),
              IconButton(onPressed: () => _shiftFocus(-1), icon: const Icon(Icons.chevron_left)),
              Text(_headerLabel),
              IconButton(onPressed: () => _shiftFocus(1), icon: const Icon(Icons.chevron_right)),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _syncGoogle, child: const Text('Sync Google')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => _openEditor(day: _focused), child: const Text('Add event')),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: eventsAsync.when(
              data: (events) => CalendarGrid(
                mode: _mode,
                focused: _focused,
                events: events,
                indicators: indicators,
                weekStartsMonday: weekStartsMonday,
                onDayTap: (day) => _openEditor(day: day),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}

String _trackerValueLabel(StatisticTracker tracker, TrackerValue value) {
  return switch (tracker.type) {
    TrackerType.integer => '${value.intValue ?? tracker.defaultInt}',
    TrackerType.boolean => (value.boolValue ?? tracker.defaultBool) ? 'yes' : 'no',
    TrackerType.enumType => value.enumValue ?? tracker.defaultEnumOption ?? 'empty',
  };
}
