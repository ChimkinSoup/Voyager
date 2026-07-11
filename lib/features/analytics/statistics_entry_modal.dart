import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';

/// Opens the statistics entry modal sheet.
Future<void> showStatisticsEntryModal(
    BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: const _StatisticsEntryModal(),
    ),
  );
}

class _StatisticsEntryModal extends ConsumerStatefulWidget {
  const _StatisticsEntryModal();

  @override
  ConsumerState<_StatisticsEntryModal> createState() =>
      _StatisticsEntryModalState();
}

class _StatisticsEntryModalState
    extends ConsumerState<_StatisticsEntryModal> {
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
  }

  @override
  Widget build(BuildContext context) {
    final trackersAsync = ref.watch(trackersProvider);
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          // Handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Icon(
                  PhosphorIconsRegular.chartBar,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Text('Log Stats', style: theme.textTheme.titleMedium),
                const Spacer(),
                // Date selector
                TextButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(PhosphorIconsRegular.calendar, size: 16),
                  label: Text(_formatDate(_selectedDate)),
                ),
                IconButton(
                  onPressed: Navigator.of(context).pop,
                  icon: const Icon(PhosphorIconsRegular.x, size: 18),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Body
          Expanded(
            child: trackersAsync.when(
              data: (trackers) {
                final dailyTrackers = trackers
                    .where(
                      (t) =>
                          t.cadence == TrackerCadence.daily &&
                          t.deletedAt == null,
                    )
                    .toList();

                if (dailyTrackers.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            PhosphorIconsRegular.chartBar,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No daily trackers yet.\nCreate one on the Analytics page.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  separatorBuilder: (_, __) =>
                      const Divider(height: 20, indent: 16, endIndent: 16),
                  itemCount: dailyTrackers.length,
                  itemBuilder: (ctx, i) => _TrackerEntryRow(
                    tracker: dailyTrackers[i],
                    date: _selectedDate,
                  ),
                );
              },
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'Today';
    final yesterday = today.subtract(const Duration(days: 1));
    if (d == yesterday) return 'Yesterday';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

// ---------------------------------------------------------------------------
// Single tracker entry row inside the modal
// ---------------------------------------------------------------------------

class _TrackerEntryRow extends ConsumerStatefulWidget {
  const _TrackerEntryRow({required this.tracker, required this.date});

  final StatisticTracker tracker;
  final DateTime date;

  @override
  ConsumerState<_TrackerEntryRow> createState() => _TrackerEntryRowState();
}

class _TrackerEntryRowState extends ConsumerState<_TrackerEntryRow> {
  final _intController = TextEditingController();
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _intController.text =
        widget.tracker.defaultInt.toString();
  }

  @override
  void didUpdateWidget(covariant _TrackerEntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date != widget.date) {
      setState(() => _saved = false);
    }
  }

  @override
  void dispose() {
    _intController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valuesAsync = ref.watch(trackerValuesProvider(widget.tracker.id));
    final theme = Theme.of(context);
    final accent = Color(widget.tracker.colorValue);

    return valuesAsync.when(
      data: (values) {
        final existing = values.cast<TrackerValue?>().firstWhere(
          (v) =>
              v != null &&
              v.periodStart.year == widget.date.year &&
              v.periodStart.month == widget.date.month &&
              v.periodStart.day == widget.date.day,
          orElse: () => null,
        );

        // Sync int controller once
        if (!_saved && widget.tracker.type == TrackerType.integer) {
          final val = existing?.intValue ?? widget.tracker.defaultInt;
          if (_intController.text != val.toString()) {
            _intController.text = val.toString();
          }
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              // Color dot + name
              CircleAvatar(radius: 5, backgroundColor: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.tracker.name,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 12),
              // Editor
              _buildEditor(existing, theme),
              // Save indicator
              if (_saved)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    PhosphorIconsRegular.checkCircle,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('$e'),
    );
  }

  Widget _buildEditor(TrackerValue? existing, ThemeData theme) {
    switch (widget.tracker.type) {
      case TrackerType.integer:
        final cap = widget.tracker.integerCap;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 80,
              child: VoyagerTextField(
                controller: _intController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  helperText: cap == null ? null : '0-$cap',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                onSubmitted: (_) => _saveInt(existing),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: () => _saveInt(existing),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Save'),
            ),
          ],
        );
      case TrackerType.boolean:
        return Switch(
          value: existing?.boolValue ?? widget.tracker.defaultBool,
          onChanged: (v) => _saveValue(existing, boolValue: v),
        );
      case TrackerType.enumType:
        final options = widget.tracker.enumOptions;
        final current = existing?.enumValue ?? widget.tracker.defaultEnumOption;
        return SizedBox(
          width: 120,
          child: VoyagerDropdownButtonFormField<String>(
            initialValue: options.contains(current) ? current : null,
            decoration: const InputDecoration(isDense: true),
            items: options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) => _saveValue(existing, enumValue: v),
          ),
        );
    }
  }

  Future<void> _saveInt(TrackerValue? existing) async {
    final raw = int.tryParse(_intController.text.trim());
    if (raw == null) return;
    final cap = widget.tracker.integerCap;
    final val = cap == null ? raw : raw.clamp(0, cap);
    await _saveValue(existing, intValue: val);
  }

  Future<void> _saveValue(
    TrackerValue? current, {
    int? intValue,
    bool? boolValue,
    String? enumValue,
  }) async {
    final now = utcNow();
    await ref.read(trackerRepositoryProvider).upsertValue(
          TrackerValue(
            id: current?.id ??
                '${widget.tracker.id}_${widget.date.millisecondsSinceEpoch}',
            trackerId: widget.tracker.id,
            periodStart: widget.date,
            intValue: intValue,
            boolValue: boolValue,
            enumValue: enumValue,
            createdAt: current?.createdAt ?? now,
            updatedAt: now,
          ),
        );
    ref.invalidate(trackerValuesProvider(widget.tracker.id));
    ref.invalidate(pendingStatEntriesProvider);
    if (mounted) setState(() => _saved = true);
    // Reset saved indicator after 2s
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _saved = false);
  }
}
