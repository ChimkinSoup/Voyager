import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_list_actions.dart';

/// Create, rename, recolour and delete calendars, behind the header gear.
///
/// The journal and todo twins carry a Settings row; a calendar has no
/// per-entity settings sheet to open, so this one does not.
///
/// Returns the id of a calendar created here, so the page can select it.
Future<String?> showCalendarManageSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final createdId = await showVoyagerDialog<String?>(
    context: context,
    builder: (context) => const _CalendarManageDialog(),
  );
  ref.invalidate(calendarsProvider);
  ref.invalidate(calendarEventsProvider);
  return createdId;
}

class _CalendarManageDialog extends ConsumerStatefulWidget {
  const _CalendarManageDialog();

  @override
  ConsumerState<_CalendarManageDialog> createState() =>
      _CalendarManageDialogState();
}

class _CalendarManageDialogState extends ConsumerState<_CalendarManageDialog> {
  var _loading = true;
  List<Calendar> _calendars = [];
  Map<String, int> _counts = {};
  String? _createdCalendarId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final repo = ref.read(calendarRepositoryProvider);
    final calendars = await repo.listCalendars();
    final counts = <String, int>{};
    for (final calendar in calendars) {
      final events = await repo.listEvents(calendarId: calendar.id);
      counts[calendar.id] = events.length;
    }
    if (!mounted) return;
    setState(() {
      _calendars = calendars;
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _createCalendar() async {
    final created = await createCalendarList(context, ref);
    if (created == null || !mounted) return;
    _createdCalendarId = created.id;
    await _reload();
  }

  Future<void> _renameCalendar(Calendar calendar) async {
    await renameCalendarList(context, ref, calendar);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _pickColor(Calendar calendar) async {
    await changeCalendarListColor(context, ref, calendar, _calendars);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _deleteCalendar(Calendar calendar) async {
    final deleted = await deleteCalendarList(
      context,
      ref,
      calendar: calendar,
      allCalendars: _calendars,
      eventCount: _counts[calendar.id] ?? 0,
    );
    if (!deleted || !mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manage calendars'),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: _calendars.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final calendar = _calendars[index];
                  final count = _counts[calendar.id] ?? 0;
                  return ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    tileColor: Theme.of(context).colorScheme.surface,
                    leading: CircleAvatar(
                      backgroundColor: Color(
                        calendar.colorValue ??
                            Theme.of(context).colorScheme.primary.toARGB32(),
                      ),
                    ),
                    title: Text(calendar.name),
                    subtitle: Text(count == 1 ? '1 event' : '$count events'),
                    trailing: PopupMenuButton<VoyagerMenuCatalogEntry>(
                      onSelected: (action) async {
                        switch (action) {
                          case VoyagerMenuCatalogEntry.rename:
                            await _renameCalendar(calendar);
                          case VoyagerMenuCatalogEntry.changeColor:
                            await _pickColor(calendar);
                          case VoyagerMenuCatalogEntry.delete:
                            await _deleteCalendar(calendar);
                          default:
                            break;
                        }
                      },
                      itemBuilder: (context) => buildCatalogMenu(
                        context,
                        from: calendar.id == legacyCalendarId
                            ? defaultEntityManageMenuEntries
                            : entityManageMenuEntries,
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context, _createdCalendarId),
          label: 'Close',
        ),
        GlassButton(
          dense: true,
          onPressed: _createCalendar,
          icon: const Icon(PhosphorIconsRegular.plus),
          label: 'New calendar',
        ),
      ],
    );
  }
}
