import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/widgets/report_height.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';

/// The calendar hotkey's floater: the calendar's new-event panel, for today,
/// all day, in the calendar the calendar page last had open — what its "Add
/// event" button would open. Always fresh, like the reminder floater: nothing
/// is kept when the floater is dismissed.
class CalendarFloater extends ConsumerWidget {
  const CalendarFloater({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final container = ProviderScope.containerOf(context, listen: false);
    final floaters = ref.read(floaterControllerProvider);
    final settings = ref.read(settingsProvider).valueOrNull;
    final lastViewed = settings?.calendarShowAllCalendars == false
        ? settings?.lastViewedCalendarId
        : null;
    // The window is sized to the panel through setHeight; scrollable for the
    // frame between the panel growing and the window growing with it, which
    // would otherwise overflow it.
    return VoyagerScrollView(
      child: ReportHeight(
        onHeight: floaters.setHeight,
        child: CalendarEventPanel(
          initialDate: DateUtils.dateOnly(DateTime.now()),
          calendars: ref.read(calendarsProvider).valueOrNull ?? const [],
          initialCalendarId: lastViewed ?? legacyCalendarId,
          focusTitleOnOpen: true,
          onSave: (data) => unawaited(() async {
            await container
                .read(calendarRepositoryProvider)
                .upsertEvent(newCalendarEventFromPanel(data));
            container.invalidate(calendarEventsProvider);
            await floaters.completeWith('Event added');
          }()),
          onCancel: () => unawaited(floaters.dismiss()),
          leading: const FloaterAppIcon(VoyagerIcons.calendar, size: 20),
        ),
      ),
    );
  }
}
