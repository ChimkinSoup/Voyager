import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';

/// Width the repeat popover wants. Callers pass this to
/// `showContextualPopover` so the preset list and the custom editor agree.
const double kRepeatPopoverWidth = 268;

/// Picker for a [RecurrenceRule], shared by the calendar event panel and the
/// to-do edit panel.
///
/// Two pages in one popover: the five presets, and a custom editor for
/// "every X units" plus weekday selection. The custom page is reached from the
/// last preset row and returns to the list on save, so the popover never grows
/// taller than the list it opened as.
class RepeatSelectorPopover extends StatefulWidget {
  const RepeatSelectorPopover({
    super.key,
    required this.initialRule,
    required this.anchor,
    this.accentColor,
  });

  final RecurrenceRule initialRule;

  /// The date the rule hangs off — the event start or the task due date. Only
  /// used for labels ("Every week on Mon") and to seed the weekday chips.
  final DateTime anchor;

  final Color? accentColor;

  @override
  State<RepeatSelectorPopover> createState() => _RepeatSelectorPopoverState();
}

class _RepeatSelectorPopoverState extends State<RepeatSelectorPopover> {
  late RecurrenceRule _rule;
  late bool _customMode;

  // Custom-page working state, kept separate from [_rule] so backing out of the
  // custom page with Cancel leaves the committed rule untouched.
  late EventRecurrence _customFrequency;
  late int _customInterval;
  late Set<int> _customWeekdays;
  late final TextEditingController _intervalController;
  late final FocusNode _intervalFocusNode;

  @override
  void initState() {
    super.initState();
    _rule = widget.initialRule;
    _customMode = widget.initialRule.isCustom;
    _customFrequency = _rule.repeats ? _rule.frequency : EventRecurrence.daily;
    _customInterval = _rule.interval;
    _customWeekdays = {..._rule.weekdays};
    _intervalController = TextEditingController(text: '$_customInterval');
    _intervalFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _intervalController.dispose();
    _intervalFocusNode.dispose();
    super.dispose();
  }

  Color get _accent => widget.accentColor ?? Theme.of(context).colorScheme.primary;

  void _commit(RecurrenceRule rule) => Navigator.of(context).pop(rule);

  void _openCustom() {
    setState(() {
      _customMode = true;
      // A preset that is already a repeat seeds the custom page with itself, so
      // "Every week" → Custom starts at "every 1 week" rather than resetting.
      if (_rule.repeats) {
        _customFrequency = _rule.frequency;
        _customInterval = _rule.interval;
        _customWeekdays = {..._rule.weekdays};
      }
      _intervalController.text = '$_customInterval';
    });
  }

  void _saveCustom() {
    final weekdays = _customFrequency == EventRecurrence.weekly
        ? _customWeekdays
        : const <int>{};
    _commit(
      RecurrenceRule(
        frequency: _customFrequency,
        interval: _customInterval < 1 ? 1 : _customInterval,
        weekdays: weekdays,
      ),
    );
  }

  void _setInterval(int value) {
    final clamped = value < 1 ? 1 : (value > 999 ? 999 : value);
    setState(() => _customInterval = clamped);
    if (_intervalController.text != '$clamped') {
      _intervalController.text = '$clamped';
      _intervalController.selection = TextSelection.collapsed(
        offset: _intervalController.text.length,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return _customMode ? _buildCustomPage(context) : _buildPresetPage(context);
  }

  // ── Page 1: presets ───────────────────────────────────────────────────────

  Widget _buildPresetPage(BuildContext context) {
    const presets = [
      EventRecurrence.none,
      EventRecurrence.daily,
      EventRecurrence.weekly,
      EventRecurrence.monthly,
      EventRecurrence.yearly,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final frequency in presets)
          _OptionRow(
            label: recurrenceRuleLabel(
              RecurrenceRule(frequency: frequency),
              anchor: widget.anchor,
            ),
            selected: !_rule.isCustom && _rule.frequency == frequency,
            accent: _accent,
            onTap: () => _commit(RecurrenceRule(frequency: frequency)),
          ),
        Divider(
          height: 9,
          thickness: 1,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
        _OptionRow(
          label: _rule.isCustom
              ? recurrenceRuleLabel(_rule, anchor: widget.anchor)
              : 'Custom…',
          selected: _rule.isCustom,
          accent: _accent,
          trailing: PhosphorIconsRegular.caretRight,
          onTap: _openCustom,
        ),
      ],
    );
  }

  // ── Page 2: custom ────────────────────────────────────────────────────────

  Widget _buildCustomPage(BuildContext context) {
    final theme = Theme.of(context);
    final isWeekly = _customFrequency == EventRecurrence.weekly;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() => _customMode = false),
              icon: const Icon(PhosphorIconsRegular.caretLeft, size: 16),
              tooltip: 'Back',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            ),
            Expanded(
              child: Text(
                'Custom repeat',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text('Every', style: theme.textTheme.labelMedium),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              height: 34,
              child: TextField(
                controller: _intervalController,
                focusNode: _intervalFocusNode,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                style: theme.textTheme.labelLarge,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: _accent, width: 1.6),
                  ),
                ),
                // Empty is a transient state while typing, not a value: leave
                // [_customInterval] alone until a real number lands so the unit
                // label does not flicker to "1" mid-edit.
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed >= 1) {
                    setState(() => _customInterval = parsed);
                  }
                },
                onSubmitted: (_) => _setInterval(_customInterval),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _UnitDropdown(
                value: _customFrequency,
                interval: _customInterval,
                accent: _accent,
                onChanged: (value) =>
                    setState(() => _customFrequency = value),
              ),
            ),
          ],
        ),
        if (isWeekly) ...[
          const SizedBox(height: 12),
          Text('On', style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          _WeekdayChips(
            selected: effectiveWeekdays(
              RecurrenceRule(
                frequency: EventRecurrence.weekly,
                weekdays: _customWeekdays,
              ),
              widget.anchor,
            ),
            accent: _accent,
            onToggle: (weekday) {
              setState(() {
                final next = {
                  ...effectiveWeekdays(
                    RecurrenceRule(
                      frequency: EventRecurrence.weekly,
                      weekdays: _customWeekdays,
                    ),
                    widget.anchor,
                  ),
                };
                if (next.contains(weekday)) {
                  next.remove(weekday);
                } else {
                  next.add(weekday);
                }
                // Never let the set empty out: an empty weekly rule silently
                // falls back to the anchor weekday, so the chip the user just
                // cleared would light straight back up.
                if (next.isNotEmpty) _customWeekdays = next;
              });
            },
          ),
        ],
        const SizedBox(height: 12),
        Text(
          recurrenceRuleLabel(
            RecurrenceRule(
              frequency: _customFrequency,
              interval: _customInterval < 1 ? 1 : _customInterval,
              weekdays: isWeekly ? _customWeekdays : const {},
            ),
            anchor: widget.anchor,
          ),
          style: theme.textTheme.labelMedium?.copyWith(
            color: _accent,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            GlassButton(
              onPressed: () => setState(() => _customMode = false),
              label: 'Cancel',
              dense: true,
            ),
            const Spacer(),
            GlassButton(onPressed: _saveCustom, label: 'Done', dense: true),
          ],
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: selected ? accent : theme.colorScheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                Icon(PhosphorIconsRegular.check, size: 16, color: accent)
              else if (trailing != null)
                Icon(
                  trailing,
                  size: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnitDropdown extends StatelessWidget {
  const _UnitDropdown({
    required this.value,
    required this.interval,
    required this.accent,
    required this.onChanged,
  });

  final EventRecurrence value;
  final int interval;
  final Color accent;
  final ValueChanged<EventRecurrence> onChanged;

  static const _units = [
    EventRecurrence.daily,
    EventRecurrence.weekly,
    EventRecurrence.monthly,
    EventRecurrence.yearly,
  ];

  String _label(EventRecurrence unit) {
    final plural = interval == 1 ? '' : 's';
    return switch (unit) {
      EventRecurrence.daily => 'day$plural',
      EventRecurrence.weekly => 'week$plural',
      EventRecurrence.monthly => 'month$plural',
      EventRecurrence.yearly => 'year$plural',
      EventRecurrence.none => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropdownButtonHideUnderline(
      child: DropdownButton<EventRecurrence>(
        value: value,
        isDense: true,
        isExpanded: true,
        borderRadius: BorderRadius.circular(10),
        style: theme.textTheme.labelLarge,
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
        items: [
          for (final unit in _units)
            DropdownMenuItem(value: unit, child: Text(_label(unit))),
        ],
      ),
    );
  }
}

class _WeekdayChips extends StatelessWidget {
  const _WeekdayChips({
    required this.selected,
    required this.accent,
    required this.onToggle,
  });

  final Set<int> selected;
  final Color accent;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var weekday = DateTime.monday;
            weekday <= DateTime.sunday;
            weekday++)
          () {
            final isOn = selected.contains(weekday);
            return Tooltip(
              message: shortWeekdayName(weekday),
              child: Material(
                color: isOn
                    ? accent
                    : theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onToggle(weekday),
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Center(
                      child: Text(
                        shortWeekdayName(weekday).substring(0, 1),
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: isOn
                              ? (ThemeData.estimateBrightnessForColor(accent) ==
                                      Brightness.light
                                  ? Colors.black
                                  : Colors.white)
                              : theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }(),
      ],
    );
  }
}

/// Subtle repeat toggle for a form row.
///
/// Dim and outline-only until a rule is set, then it takes the accent colour so
/// a repeating item reads as repeating at a glance without the control shouting
/// when it is off — which is the state it is in for almost every event.
class RepeatIconButton extends StatelessWidget {
  const RepeatIconButton({
    super.key,
    required this.rule,
    required this.anchor,
    required this.onPressed,
    this.accentColor,
    this.isOpen = false,
    this.enabled = true,
    this.disabledTooltip,
  });

  final RecurrenceRule rule;
  final DateTime anchor;
  final VoidCallback onPressed;
  final Color? accentColor;
  final bool isOpen;

  /// Whether a rule can be picked at all. A to-do with no due date has nothing
  /// for a repeat to hang off, so the button reads as off and refuses the tap
  /// rather than lighting up over a rule that could never fire.
  final bool enabled;

  /// Shown in place of the usual tooltip while [enabled] is false.
  final String? disabledTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;
    final on = rule.repeats && enabled;
    return IconButton(
      onPressed: enabled ? onPressed : null,
      tooltip: !enabled
          ? (disabledTooltip ?? 'Repeat')
          : on
          ? recurrenceRuleLabel(rule, anchor: anchor)
          : 'Repeat',
      padding: EdgeInsets.zero,
      constraints: kMinTouchTarget,
      icon: Icon(
        PhosphorIconsRegular.repeat,
        size: 18,
        color: on || isOpen
            ? accent
            : theme.colorScheme.onSurface.withValues(alpha: 0.35),
      ),
    );
  }
}
