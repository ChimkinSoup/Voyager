import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_list_actions.dart';
import 'package:voyager/features/trash/trash_dialog.dart';
import 'package:voyager/features/trash/trash_kinds.dart';

/// Create, rename, recolour, overlay and delete calendars, behind the header
/// gear.
///
/// The journal and todo twins carry a Settings row; a calendar has no
/// per-entity settings sheet to open, so its default is set from its menu
/// here instead.
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

  /// Only the first load shows the spinner; later reloads keep the rows on
  /// screen until the fresh ones land.
  Future<void> _reload() async {
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

  Future<void> _editOverlays(Calendar calendar) async {
    await editCalendarOverlays(context, ref, calendar, _calendars);
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

  /// Setting a default clears whichever calendar held it before, because
  /// [AppSettings.defaultCalendarId] is a single field.
  Future<void> _saveDefaultCalendar(
    Calendar calendar, {
    required bool isDefault,
  }) async {
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final settings = await settingsRepo.getSettings();
    await settingsNotifier.saveSettings(
      isDefault
          ? settings.copyWith(defaultCalendarId: calendar.id)
          : settings.copyWith(clearDefaultCalendarId: true),
    );
  }

  /// The names of the calendars [calendar] also shows, in its list's order.
  List<String> _overlayNames(Calendar calendar) {
    final names = {for (final item in _calendars) item.id: item.name};
    return [
      for (final id in visibleOverlayCalendarIds(calendar.id, _calendars))
        names[id]!,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final defaultCalendarId = ref
        .watch(settingsProvider)
        .valueOrNull
        ?.defaultCalendarId;
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
                  final overlayNames = _overlayNames(calendar);
                  final isDefault = calendar.id == defaultCalendarId;
                  final countLabel = Text(
                    [
                      count == 1 ? '1 event' : '$count events',
                      if (isDefault) 'Default',
                    ].join(' · '),
                  );
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
                    // The count stays the calendar's own events; what it
                    // also shows is a quieter line under it.
                    subtitle: overlayNames.isEmpty
                        ? countLabel
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              countLabel,
                              Text(
                                'Also shows ${overlayNames.join(', ')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                    trailing: ContextMenuButton(
                      items: catalogContextMenuItems(
                        [
                          VoyagerMenuCatalogEntry.rename,
                          VoyagerMenuCatalogEntry.changeColor,
                          VoyagerMenuCatalogEntry.alsoShow,
                          isDefault
                              ? VoyagerMenuCatalogEntry.clearDefault
                              : VoyagerMenuCatalogEntry.setDefault,
                          // The last calendar stays: its events would have
                          // nowhere to go.
                          if (_calendars.length > 1)
                            VoyagerMenuCatalogEntry.delete,
                        ],
                        (action) async {
                          switch (action) {
                            case VoyagerMenuCatalogEntry.rename:
                              await _renameCalendar(calendar);
                            case VoyagerMenuCatalogEntry.changeColor:
                              await _pickColor(calendar);
                            case VoyagerMenuCatalogEntry.alsoShow:
                              await _editOverlays(calendar);
                            case VoyagerMenuCatalogEntry.setDefault:
                              await _saveDefaultCalendar(
                                calendar,
                                isDefault: true,
                              );
                            case VoyagerMenuCatalogEntry.clearDefault:
                              await _saveDefaultCalendar(
                                calendar,
                                isDefault: false,
                              );
                            case VoyagerMenuCatalogEntry.delete:
                              await _deleteCalendar(calendar);
                            default:
                              break;
                          }
                        },
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () async {
            await showTrashDialog(context, feature: TrashFeature.calendar);
            if (mounted) await _reload();
          },
          icon: const Icon(PhosphorIconsRegular.trash),
          label: 'Recently deleted',
        ),
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
