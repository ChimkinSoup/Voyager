import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/notifications/notification_history.dart';
import 'package:voyager/core/notifications/recording_scaffold_messenger.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/features/notifications/notification_history_dialog.dart';

/// Pumps an app wired the way `VoyagerApp` is, and hands back a context
/// inside it.
Future<BuildContext> pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => RecordingScaffoldMessenger(child: child!),
      home: Builder(
        builder: (context) {
          ctx = context;
          return const Scaffold();
        },
      ),
    ),
  );
  return ctx;
}

void main() {
  final history = NotificationHistory.instance;
  List<String> messages() => [for (final r in history.records) r.message];

  setUp(() {
    history.clear();
    history.currentOrigin = null;
  });

  testWidgets('a finished toast is recorded', (tester) async {
    final ctx = await pumpHost(tester);
    showVoyagerToast(
      ctx,
      message: 'Workout saved',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 2),
    );
    expect(messages(), ['Workout saved']);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a working toast is recorded, and so is the result it becomes', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    final toast = showVoyagerToast(ctx, message: 'Exporting…');
    expect(messages(), ['Exporting…']);

    // Progress revises the working line rather than adding one per tick.
    toast.update(message: 'Exporting… 40%');
    expect(messages(), ['Exporting… 40%']);

    toast.update(
      message: 'Exported backup.zip',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 2),
    );
    expect(messages(), ['Exported backup.zip', 'Exporting… 40%']);

    // A later rewrite of the result revises its line, not a third one.
    toast.update(message: 'Exported backup.zip (12 MB)');
    expect(messages(), ['Exported backup.zip (12 MB)', 'Exporting… 40%']);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a working toast that is dismissed without a result is still '
      'recorded', (tester) async {
    final ctx = await pumpHost(tester);
    final toast = showVoyagerToast(ctx, message: 'Syncing…');
    await tester.pump();
    toast.dismiss();
    await tester.pumpAndSettle();
    expect(messages(), ['Syncing…']);
  });

  testWidgets('each repeat of a coalesced toast is its own line', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    for (var i = 0; i < 3; i++) {
      showVoyagerToast(
        ctx,
        message: 'Synced',
        icon: PhosphorIconsRegular.check,
        dwell: const Duration(seconds: 2),
      );
    }
    await tester.pump();
    expect(find.text('×3'), findsOneWidget);
    expect(messages(), ['Synced', 'Synced', 'Synced']);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a toast is put down to the page it was raised on, and keeps '
      'it after the user moves on', (tester) async {
    final ctx = await pumpHost(tester);
    var page = 'Settings';
    history.currentOrigin = () => page;
    final toast = showVoyagerToast(ctx, message: 'Exporting…');

    page = 'LeetCode';
    toast.update(
      message: 'Exported backup.zip',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 2),
    );
    expect(
      [for (final r in history.records) r.origin],
      ['Settings', 'Settings'],
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a toast that names its origin keeps it', (tester) async {
    final ctx = await pumpHost(tester);
    history.currentOrigin = () => 'Journal';
    showVoyagerToast(
      ctx,
      message: 'Restored 3 items',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 2),
      origin: 'Sync',
    );
    expect(history.records.single.origin, 'Sync');
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('a snackbar is recorded', (tester) async {
    final ctx = await pumpHost(tester);
    ScaffoldMessenger.of(
      ctx,
    ).showSnackBar(const SnackBar(content: Text('Image copied.')));
    expect(messages(), ['Image copied.']);
    expect(history.records.single.origin, isNull);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  test('a notification with a seen dedupe key is not recorded again', () {
    expect(history.record('Stretch', dedupeKey: 'reminder|a|1'), isNotNull);
    expect(history.record('Stretch', dedupeKey: 'reminder|a|1'), isNull);
    expect(history.record('Stretch', dedupeKey: 'reminder|a|2'), isNotNull);
    expect(messages(), ['Stretch', 'Stretch']);
  });

  test('records survive a JSON round trip', () {
    final record = NotificationRecord(
      at: DateTime(2026, 9, 28, 14, 5),
      message: 'Pay rent',
      source: NotificationSource.reminder,
      origin: 'To-Do',
      detail: 'Due today',
      dedupeKey: 'reminder|rent|1',
    );
    final back = NotificationRecord.fromJson(record.toJson());
    expect(back.at, record.at);
    expect(back.message, 'Pay rent');
    expect(back.source, NotificationSource.reminder);
    expect(back.origin, 'To-Do');
    expect(back.detail, 'Due today');
    expect(back.dedupeKey, 'reminder|rent|1');
  });

  testWidgets('the settings dialog lists what was recorded, and clears it', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    history.record(
      'Stand up',
      source: NotificationSource.reminder,
      origin: 'Reminders',
      detail: 'Every hour',
    );
    history.record('Restored 42 items', origin: 'Sync');

    showNotificationHistoryDialog(ctx);
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Stand up'), findsOneWidget);
    expect(find.text('Reminders · Every hour'), findsOneWidget);
    expect(find.text('Sync'), findsOneWidget);
    expect(find.text('Restored 42 items'), findsOneWidget);

    // Live: a notification that arrives while the dialog is open shows up.
    history.record('Snippet saved');
    await tester.pump();
    expect(find.text('Snippet saved'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(history.records, isEmpty);
    expect(find.textContaining('No notifications yet'), findsOneWidget);
  });
}
