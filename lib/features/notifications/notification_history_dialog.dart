import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/notifications/notification_history.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

/// Every notification this device showed in the last 30 days, newest first.
Future<void> showNotificationHistoryDialog(BuildContext context) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => const _NotificationHistoryDialog(),
  );
}

class _NotificationHistoryDialog extends StatelessWidget {
  const _NotificationHistoryDialog();

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Clear notification history?',
      message: 'Removes every notification recorded on this device.',
      confirmLabel: 'Clear',
    );
    if (confirmed) NotificationHistory.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final history = NotificationHistory.instance;

    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final records = history.records;
        return AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('Notification history')),
              if (records.isNotEmpty)
                GlassButton(
                  dense: true,
                  onPressed: () => _clear(context),
                  icon: const Icon(PhosphorIconsRegular.broom, size: 18),
                  label: 'Clear',
                ),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          content: SizedBox(
            width: 600,
            height: 480,
            child: records.isEmpty
                ? Center(
                    child: Text(
                      'No notifications yet. Everything shown on this device '
                      'stays here for 30 days.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView(children: _rows(context, records)),
          ),
          actions: [
            GlassButton(
              dense: true,
              onPressed: () => Navigator.of(context).pop(),
              label: 'Close',
            ),
          ],
        );
      },
    );
  }

  List<Widget> _rows(BuildContext context, List<NotificationRecord> records) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    // UTC midnights, so a daylight-saving day's 23 or 25 hours still count
    // as one day.
    final today = DateTime.utc(now.year, now.month, now.day);
    final time = DateFormat.jm();
    final rows = <Widget>[];
    DateTime? day;
    for (final record in records) {
      final recordDay = DateUtils.dateOnly(record.at);
      if (recordDay != day) {
        day = recordDay;
        final daysAgo = today
            .difference(
              DateTime.utc(recordDay.year, recordDay.month, recordDay.day),
            )
            .inDays;
        rows.add(
          Padding(
            padding: EdgeInsets.fromLTRB(12, rows.isEmpty ? 0 : 16, 12, 4),
            child: Text(
              daysAgo == 0
                  ? 'Today'
                  : daysAgo == 1
                  ? 'Yesterday'
                  : DateFormat.MMMEd().format(recordDay),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      // Where it came from first, so a column of them reads down the page.
      final subtitle = [?record.origin, ?record.detail].join(' · ');
      rows.add(
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(switch (record.source) {
            NotificationSource.app => PhosphorIconsRegular.chatCircleText,
            NotificationSource.reminder => PhosphorIconsRegular.bellRinging,
          }, size: 20),
          title: Text(record.message),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          trailing: Text(
            time.format(record.at),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return rows;
  }
}
