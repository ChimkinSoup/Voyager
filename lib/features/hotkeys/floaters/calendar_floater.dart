import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sound/app_sounds.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/widgets/report_height.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';
import 'package:voyager/features/calendar/calendar_list_actions.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

/// The calendar hotkey's floater: the calendar's new-event panel, for today,
/// all day, in the calendar the calendar page has open — what its "Add event"
/// button would open. Drafts kept across dismissals, and taken into
/// the app by the floater's icon.
class CalendarFloater extends ConsumerStatefulWidget {
  const CalendarFloater({super.key});

  @override
  ConsumerState<CalendarFloater> createState() => _CalendarFloaterState();
}

class _CalendarFloaterState extends ConsumerState<CalendarFloater> {
  final _panel = GlobalKey<CalendarEventPanelState>();
  late final FloaterController _floaters;

  @override
  void initState() {
    super.initState();
    _floaters = ref.read(floaterControllerProvider)..registerFlush(_keepDraft);
  }

  @override
  void dispose() {
    _floaters.unregisterFlush(_keepDraft);
    super.dispose();
  }

  /// Run before every dismiss, so the draft is stored before "Open in app"
  /// asks the calendar page to take it up, rather than from the panel's
  /// `dispose`, which can come after.
  Future<void> _keepDraft() async {
    final panel = _panel.currentState;
    if (panel == null) return;
    ref.read(calendarCaptureDraftProvider.notifier).state = panel
        .unsavedDraft();
  }

  @override
  Widget build(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    final settings = ref.read(settingsProvider).valueOrNull;
    final calendars = ref.read(calendarsProvider).valueOrNull ?? const [];
    final selected = ref.read(calendarPageSelectionProvider);
    // Passed over once its calendar is known to be deleted.
    final pageCalendar =
        calendars.isEmpty || calendars.any((c) => c.id == selected)
        ? selected
        : null;
    // The window is sized to the panel through setHeight; scrollable for the
    // frame between the panel growing and the window growing with it, which
    // would otherwise overflow it.
    return VoyagerScrollView(
      child: ReportHeight(
        onHeight: _floaters.setHeight,
        child: CalendarEventPanel(
          key: _panel,
          initialDate: DateUtils.dateOnly(DateTime.now()),
          calendars: calendars,
          initialCalendarId:
              pageCalendar ??
              defaultCalendarIdFor(calendars, settings) ??
              legacyCalendarId,
          focusTitleOnOpen: true,
          draft: ref.read(calendarCaptureDraftProvider),
          onDraft: (draft) => storeCalendarCaptureDraft(container, draft),
          onSave: (data) => unawaited(() async {
            await container
                .read(calendarRepositoryProvider)
                .upsertEvent(newCalendarEventFromPanel(data));
            container.invalidate(calendarEventsProvider);
            container.read(appSoundsProvider).play(AppSound.saved);
            await _floaters.completeWith('Event added');
          }()),
          onCancel: () => unawaited(_floaters.dismiss()),
          leading: const FloaterAppIcon(VoyagerIcons.calendar, size: 20),
        ),
      ),
    );
  }
}
