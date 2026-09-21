import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';

/// Pumps a bare app and hands back the root overlay, which is what every call
/// site captures before its delete.
Future<OverlayState> pumpHost(WidgetTester tester) async {
  late OverlayState overlay;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          overlay = Overlay.of(context, rootOverlay: true);
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );
  return overlay;
}

void main() {
  testWidgets('the toast names the deletion and offers Undo', (tester) async {
    final overlay = await pumpHost(tester);

    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage('Groceries', fallback: 'transaction'),
      delete: () async {},
      restore: () async {},
    );
    await tester.pump();

    expect(find.text('Deleted "Groceries"'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    // The label is always "Undo", never "Restore".
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets('pressing Undo runs the restore', (tester) async {
    final overlay = await pumpHost(tester);
    var deleted = false;
    var restored = false;

    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted task',
      delete: () async => deleted = true,
      restore: () async => restored = true,
    );
    await tester.pump();
    expect(deleted, isTrue);
    expect(restored, isFalse);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(restored, isTrue);

    // The card goes as soon as the offer is taken.
    await tester.pumpAndSettle();
    expect(find.text('Deleted task'), findsNothing);
  });

  testWidgets('the offer expires after the dwell, restoring nothing', (
    tester,
  ) async {
    final overlay = await pumpHost(tester);
    var restored = false;

    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted task',
      delete: () async {},
      restore: () async => restored = true,
    );
    await tester.pump();
    expect(find.text('Undo'), findsOneWidget);

    await tester.pump(kSoftDeleteUndoDwell);
    await tester.pumpAndSettle();
    expect(find.text('Deleted task'), findsNothing);
    expect(restored, isFalse);
  });

  testWidgets('a delete that throws offers no undo and says so', (
    tester,
  ) async {
    final overlay = await pumpHost(tester);
    var restored = false;

    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted task',
      delete: () async => throw StateError('write failed'),
      restore: () async => restored = true,
    );
    await tester.pump();

    // Offering to undo something that never happened is worse than saying
    // nothing — but so is saying nothing at all. Most callers have already
    // closed their panel or dropped the row by the time the write runs, so a
    // silent throw left the row alive on disk with the surface gone.
    expect(find.text('Deleted task'), findsNothing);
    expect(find.text('Could not delete.'), findsOneWidget);
    expect(restored, isFalse);
    expect(tester.takeException(), isA<StateError>());
  });

  testWidgets('a restore that throws still dismisses the toast', (
    tester,
  ) async {
    final overlay = await pumpHost(tester);

    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted task',
      delete: () async {},
      restore: () async => throw StateError('restore failed'),
    );
    await tester.pump();

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted task'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second delete replaces the first offer', (tester) async {
    final overlay = await pumpHost(tester);

    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted first',
      delete: () async {},
      restore: () async {},
    );
    await tester.pump();
    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted second',
      delete: () async {},
      restore: () async {},
    );
    await tester.pumpAndSettle();

    // One offer at a time per overlay — the first undo is lost, which is the
    // documented v1 behaviour rather than an accident.
    expect(find.text('Deleted second'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('an undo whose row is already back says so instead', (
    tester,
  ) async {
    final overlay = await pumpHost(tester);

    await softDeleteWithUndo(
      overlay: overlay,
      message: 'Deleted task',
      delete: () async {},
      // What every restore now does once a re-read finds the row live on disk:
      // a pull brought it back during the window, and writing the older
      // snapshot over it would discard the other device's copy.
      restore: () async => throw const RestoreSuperseded(),
    );
    await tester.pump();

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted task'), findsNothing);
    // Not silence: the press would otherwise look like it did nothing at all.
    expect(find.text('Already restored'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('hide streak', () {
    test('hiddenMessage quotes the title or names the type', () {
      expect(hiddenMessage('Pay rent', fallback: 'bill'), 'Hidden "Pay rent"');
      expect(hiddenMessage('  ', fallback: 'event'), 'Hidden event');
      expect(
        hiddenMessage('x' * 60, fallback: 'task'),
        'Hidden "${'x' * 48}…"',
      );
    });

    testWidgets('a second hide joins the first and Undo returns both', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);
      final restored = <String>[];

      showHideUndoToast(
        overlay: overlay,
        keys: ['a'],
        message: 'Hidden "A"',
        restore: (keys) async => restored.addAll(keys),
      );
      await tester.pump();
      expect(find.text('Hidden "A"'), findsOneWidget);

      showHideUndoToast(
        overlay: overlay,
        keys: ['b', 'c', 'a'],
        message: 'Hidden "B"',
        restore: (keys) async => restored.addAll(keys),
      );
      await tester.pump();
      expect(find.text('Hidden 3 items'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(restored, unorderedEquals(['a', 'b', 'c']));
    });

    testWidgets('joining restarts the dwell', (tester) async {
      final overlay = await pumpHost(tester);
      showHideUndoToast(
        overlay: overlay,
        keys: ['a'],
        message: 'Hidden "A"',
        restore: (_) async {},
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      showHideUndoToast(
        overlay: overlay,
        keys: ['b'],
        message: 'Hidden "B"',
        restore: (_) async {},
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Hidden 2 items'), findsOneWidget);
    });

    testWidgets('a delete ends the streak, and the next hide starts over', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);
      showHideUndoToast(
        overlay: overlay,
        keys: ['a'],
        message: 'Hidden "A"',
        restore: (_) async {},
      );
      await tester.pump();
      showSoftDeleteUndoToast(
        overlay: overlay,
        message: 'Deleted note',
        restore: () async {},
      );
      await tester.pumpAndSettle();
      expect(find.text('Deleted note'), findsOneWidget);
      expect(find.textContaining('Hidden'), findsNothing);

      final restored = <String>[];
      showHideUndoToast(
        overlay: overlay,
        keys: ['b'],
        message: 'Hidden "B"',
        restore: (keys) async => restored.addAll(keys),
      );
      await tester.pumpAndSettle();
      expect(find.text('Deleted note'), findsNothing);
      expect(find.text('Hidden "B"'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(restored, ['b']);
    });

    testWidgets('a hide after Undo was pressed gets its own offer', (
      tester,
    ) async {
      final overlay = await pumpHost(tester);
      showHideUndoToast(
        overlay: overlay,
        keys: ['a'],
        message: 'Hidden "A"',
        restore: (_) async {},
      );
      await tester.pump();
      await tester.tap(find.text('Undo'));
      // Mid fade-out: the old card is still in the slot.
      await tester.pump();
      showHideUndoToast(
        overlay: overlay,
        keys: ['b'],
        message: 'Hidden "B"',
        restore: (_) async {},
      );
      await tester.pumpAndSettle();
      expect(find.text('Hidden "B"'), findsOneWidget);
    });
  });
}
