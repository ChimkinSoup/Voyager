import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/calendar_models.dart';

/// Picks which of the other live [calendars] [host] also shows.
///
/// Returns the checked ids in [calendars]' order, or null when cancelled.
Future<List<String>?> showCalendarOverlayDialog(
  BuildContext context, {
  required Calendar host,
  required List<Calendar> calendars,
}) {
  return showVoyagerDialog<List<String>>(
    context: context,
    builder: (context) =>
        _CalendarOverlayDialog(host: host, calendars: calendars),
  );
}

class _CalendarOverlayDialog extends StatefulWidget {
  const _CalendarOverlayDialog({required this.host, required this.calendars});

  final Calendar host;
  final List<Calendar> calendars;

  @override
  State<_CalendarOverlayDialog> createState() => _CalendarOverlayDialogState();
}

class _CalendarOverlayDialogState extends State<_CalendarOverlayDialog> {
  late final List<Calendar> _others = [
    for (final calendar in widget.calendars)
      if (calendar.id != widget.host.id && calendar.deletedAt == null) calendar,
  ];
  late final Set<String> _checked = {
    ...visibleOverlayCalendarIds(widget.host.id, widget.calendars),
  };

  void _toggle(String id, bool value) =>
      setState(() => value ? _checked.add(id) : _checked.remove(id));

  void _save() => Navigator.pop(context, [
    for (final calendar in _others)
      if (_checked.contains(calendar.id)) calendar.id,
  ]);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Show on "${widget.host.name}"'),
      content: SizedBox(
        width: 400,
        child: _others.isEmpty
            ? Text(
                'There are no other calendars to show.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final calendar in _others)
                    InkWell(
                      onTap: () => _toggle(
                        calendar.id,
                        !_checked.contains(calendar.id),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            VoyagerCheckbox(
                              value: _checked.contains(calendar.id),
                              onChanged: (value) => _toggle(calendar.id, value),
                              celebrateOnComplete: false,
                            ),
                            const SizedBox(width: 10),
                            CircleAvatar(
                              radius: 6,
                              backgroundColor: Color(
                                calendar.colorValue ??
                                    theme.colorScheme.primary.toARGB32(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                calendar.name,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
        ),
        GlassButton(dense: true, onPressed: _save, label: 'Save'),
      ],
    );
  }
}
