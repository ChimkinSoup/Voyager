import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/datetime_selector_popover.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';

/// Voyager's date picker in Gaia's look: a dialog in a [GaiaGlowRing], as
/// Gaia's menus are. A day alone unless [timed]; with [optionalTime], the
/// time may be left off, as a task's can.
Future<DateTimePick?> showGaiaDatePicker(
  BuildContext context, {
  required DateTime initial,
  required bool timed,
  bool optionalTime = false,
  bool initialHasTime = true,
}) => showDialog<DateTimePick>(
  context: context,
  builder: (context) => Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    insetPadding: const EdgeInsets.all(12),
    child: SizedBox.fromSize(
      size: timed ? kDateTimeSelectorPopoverSize : kDateSelectorPopoverSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              offset: const Offset(0, 12),
              blurRadius: 40,
              spreadRadius: -8,
            ),
          ],
        ),
        child: GaiaGlowRing(
          radius: _radius,
          hovered: false,
          child: Material(
            type: MaterialType.transparency,
            // The calendar reads the week's first day from the settings,
            // which the companion doesn't have (GAIA_HLD.md §3.2): it gets
            // the default.
            child: ProviderScope(
              overrides: [settingsProvider.overrideWith(_DefaultSettings.new)],
              child: timed
                  ? DateTimeSelectorPopover(
                      initialDateTime: initial,
                      optionalTime: optionalTime,
                      initialHasTime: initialHasTime,
                      quickPickBuilder: _quickPick,
                      // A proposal is a draft: only Done changes it.
                      keepOnDismiss: false,
                      doneBuilder: (onPressed) => GaiaButton(
                        label: 'Done',
                        onPressed: onPressed,
                        size: 32,
                      ),
                    )
                  : DateSelectorPopover(
                      initialStartDate: initial,
                      initialEndDate: initial,
                      singleDateMode: true,
                      inlineMode: true,
                      quickPickBuilder: _quickPick,
                      onDateSelected: (day) => Navigator.of(context).pop((
                        dateTime: DateUtils.dateOnly(day),
                        hasTime: false,
                      )),
                    ),
            ),
          ),
        ),
      ),
    ),
  ),
);

const _radius = 12.0;

/// Today, Tomorrow and Next Week as Gaia's buttons, narrower than the
/// card's so the three fit the calendar's width; the picked day's in the
/// accent.
Widget _quickPick(String label, bool selected, VoidCallback? onPressed) =>
    Builder(
      builder: (context) => GaiaButton(
        label: label,
        onPressed: onPressed,
        size: 28,
        padding: 8,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
    );

class _DefaultSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}
