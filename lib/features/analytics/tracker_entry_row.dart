import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/notification_urgency_dot.dart';
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';

/// A single tracker's inline entry editor for [date] — name and a
/// type-specific input (integer/boolean/enum, colored to the tracker's own
/// accent), plus a trailing slot that shows either an urgency badge or a
/// brief "saved" checkmark flash after writing. Used embedded in the
/// notification popover's Analytics section.
///
/// Enum/boolean edits save immediately; integer edits are held locally
/// (see [TrackerEntryRowState.commit]) until the section's centralized Save
/// button commits them, since typing a number has no natural "done" moment
/// the way selecting a dropdown option or flipping a switch does.
class TrackerEntryRow extends ConsumerStatefulWidget {
  const TrackerEntryRow({
    super.key,
    required this.tracker,
    required this.date,
    this.onDirtyChanged,
  });

  final StatisticTracker tracker;
  final DateTime date;

  /// Notified with `true` when this row has an unsaved integer edit pending,
  /// and `false` once it's saved (or reverted). Lets the section aggregate
  /// which rows the centralized Save button needs to commit.
  final ValueChanged<bool>? onDirtyChanged;

  @override
  ConsumerState<TrackerEntryRow> createState() => TrackerEntryRowState();
}

class TrackerEntryRowState extends ConsumerState<TrackerEntryRow> {
  static const _editorHeight = 32.0;
  static const _editorBorderRadius = 10.0;
  // Fixed so the trailing badge/checkmark/empty states never change the
  // row's width — only what's centered inside this slot changes.
  static const _trailingSlotWidth = 18.0;

  final _intController = TextEditingController();
  final _intFocusNode = FocusNode();
  String? _enumValue;
  bool _saved = false;
  bool _dirty = false;
  TrackerValue? _existing;

  @override
  void initState() {
    super.initState();
    _intController.text = widget.tracker.defaultInt.toString();
    _intFocusNode.addListener(_handleIntFocusChange);
  }

  @override
  void didUpdateWidget(covariant TrackerEntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date != widget.date) {
      if (_dirty) {
        _commitPendingForDateChange(_existing, oldWidget.date);
        widget.onDirtyChanged?.call(false);
      }
      setState(() {
        _saved = false;
        _dirty = false;
      });
    }
  }

  /// Flushes a pending integer edit for the date being navigated away from,
  /// so switching dates (or closing the popover) doesn't silently drop it.
  /// Written separately from [_saveValue] because that path targets
  /// `widget.date`, which has already moved on to the new date by the time
  /// this runs.
  Future<void> _commitPendingForDateChange(
    TrackerValue? existing,
    DateTime date,
  ) async {
    final raw = int.tryParse(_intController.text.trim());
    if (raw == null) return;
    final val = _clampInt(raw);
    final now = utcNow();
    await ref
        .read(trackerRepositoryProvider)
        .upsertValue(
          TrackerValue(
            id: existing?.id ?? trackerValueId(widget.tracker.id, date),
            trackerId: widget.tracker.id,
            periodStart: date,
            intValue: val,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
          ),
        );
    ref.invalidate(trackerValuesProvider(widget.tracker.id));
    ref.invalidate(pendingStatEntriesProvider);
  }

  @override
  void dispose() {
    _intFocusNode.removeListener(_handleIntFocusChange);
    _intFocusNode.dispose();
    _intController.dispose();
    super.dispose();
  }

  /// Saves this row's pending integer edit, if any. No-op for rows that
  /// aren't dirty (enum/boolean rows never are — they save on interaction).
  /// Called by the section's centralized Save button.
  Future<void> commit() async {
    if (!_dirty) return;
    await _saveInt(_existing);
  }

  /// Clamps whatever's typed to the tracker's valid range the moment focus
  /// leaves the field, so an out-of-range value never lingers on screen
  /// waiting for a save/Enter that may not come.
  void _handleIntFocusChange() {
    if (_intFocusNode.hasFocus) return;
    final raw = int.tryParse(_intController.text.trim());
    if (raw == null) return;
    final clamped = _clampInt(raw).toString();
    if (_intController.text != clamped) {
      _intController.text = clamped;
    }
  }

  int _clampInt(int raw) {
    final cap = widget.tracker.integerCap;
    if (cap == null) return raw;
    return raw.clamp(widget.tracker.defaultInt, cap);
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
        _existing = existing;

        // Sync the int/enum editors from persisted state once, unless we're
        // still showing the transient "saved" flash for a value we just
        // wrote, or the user has an unsaved integer edit pending.
        if (!_saved && !_dirty) {
          if (widget.tracker.type == TrackerType.integer) {
            final val = existing?.intValue ?? widget.tracker.defaultInt;
            if (_intController.text != val.toString()) {
              _intController.text = val.toString();
              _intController.selection = TextSelection(
                baseOffset: 0,
                extentOffset: _intController.text.length,
              );
            }
          } else if (widget.tracker.type == TrackerType.enumType) {
            final val = existing?.enumValue ?? widget.tracker.defaultEnumOption;
            _enumValue = widget.tracker.enumOptions.contains(val) ? val : null;
          }
        }

        final isToday = _isSameDate(widget.date, DateTime.now());
        final isUrgent = isToday && existing == null;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  widget.tracker.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _buildEditor(existing, theme, accent),
              ),
              const SizedBox(width: 6),
              // Trailing slot — urgency badge, saved checkmark, or empty.
              // Fixed width so switching between those states (e.g. on save)
              // never shifts the rest of the row.
              SizedBox(
                width: _trailingSlotWidth,
                height: _editorHeight,
                child: Center(
                  child: _saved
                      ? Icon(
                          PhosphorIconsRegular.checkCircle,
                          size: 16,
                          color: theme.colorScheme.primary,
                        )
                      : (isUrgent
                            ? NotificationUrgencyDot(
                                important: false,
                                accent: theme.colorScheme.primary,
                              )
                            : null),
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

  Widget _buildEditor(TrackerValue? existing, ThemeData theme, Color accent) {
    switch (widget.tracker.type) {
      case TrackerType.integer:
        final cap = widget.tracker.integerCap;
        final minVal = widget.tracker.defaultInt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _editorHeight,
              child: TextField(
                controller: _intController,
                focusNode: _intFocusNode,
                autofocus: false,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.left,
                textAlignVertical: TextAlignVertical.center,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                decoration: InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  filled: true,
                  fillColor:
                      theme.inputDecorationTheme.fillColor ??
                      theme.colorScheme.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 9,
                  ),
                  border: _editorBorder(accent, width: 1.3),
                  enabledBorder: _editorBorder(accent, width: 1.3),
                  focusedBorder: _editorBorder(accent, width: 1.8),
                ),
                onChanged: (_) {
                  if (!_dirty) {
                    setState(() => _dirty = true);
                    widget.onDirtyChanged?.call(true);
                  }
                },
                onSubmitted: (_) => _saveInt(existing),
              ),
            ),
            if (cap != null) ...[
              const SizedBox(height: 1),
              Text(
                '$minVal-$cap',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 7,
                  height: 1,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
            ],
          ],
        );
      case TrackerType.boolean:
        return Align(
          alignment: Alignment.centerLeft,
          child: Switch(
            value: existing?.boolValue ?? widget.tracker.defaultBool,
            onChanged: (v) => _saveValue(existing, boolValue: v),
            activeColor: accent,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        );
      case TrackerType.enumType:
        final options = widget.tracker.enumOptions;
        final selected = _enumValue;
        return VoyagerDropdownButtonFormField<String>(
          initialValue: selected,
          showCaret: false,
          accentColor: accent,
          decoration: InputDecoration(
            isDense: true,
            isCollapsed: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 9,
            ),
            border: _editorBorder(accent, width: 1.3),
            enabledBorder: _editorBorder(accent, width: 1.3),
          ),
          items: options
              .map(
                (o) => DropdownMenuItem(
                  value: o,
                  child: Text(
                    o,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            setState(() => _enumValue = v);
            _saveValue(existing, enumValue: v);
          },
        );
    }
  }

  /// A tracker-colored outline matching [_editorBorderRadius] — used at rest
  /// so the border itself carries the tracker's color, replacing the old
  /// standalone color dot.
  OutlineInputBorder _editorBorder(Color accent, {required double width}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(_editorBorderRadius),
      borderSide: BorderSide(color: accent, width: width),
    );
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _saveInt(TrackerValue? existing) async {
    final raw = int.tryParse(_intController.text.trim());
    if (raw == null) return;
    final val = _clampInt(raw);
    if (_intController.text != val.toString()) {
      _intController.text = val.toString();
    }
    await _saveValue(existing, intValue: val);
  }

  Future<void> _saveValue(
    TrackerValue? current, {
    int? intValue,
    bool? boolValue,
    String? enumValue,
  }) async {
    final now = utcNow();
    await ref
        .read(trackerRepositoryProvider)
        .upsertValue(
          TrackerValue(
            id: current?.id ?? trackerValueId(widget.tracker.id, widget.date),
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
    if (_dirty) {
      _dirty = false;
      widget.onDirtyChanged?.call(false);
    }
    if (mounted) setState(() => _saved = true);
    // Reset saved indicator after 2s
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _saved = false);
  }
}
