// The finance floater's window opens at the form's own height, or it opens
// above a band of dead background, and then follows the height the form
// reports: the amount's error line and a failed save's message grow it.
// Measured in the real theme and faces, which is what the form is actually
// laid out in: the stock Material theme puts the figure 50-odd pixels out.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';

import 'fakes/fake_weather_api_client.dart';
import 'narrow_window_harness.dart';

/// The form's bottom padding, below the Add button.
const _bottomPadding = 14.0;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'the finance floater fits the form, error line and all',
    (tester) async {
      await loadRealFonts(tester);
      tester.view.physicalSize = kFinanceFloaterSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      await container.read(transactionsProvider.future);

      // The form's height, as the floater would be told it.
      var reportedHeight = 0.0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: Scaffold(
              body: financeTransactionForm(
                container: container,
                onClose: () {},
                // Runs after the row is written, so this is the long
                // "saved, but the step after it failed" message.
                onSaved: (_) async => throw Exception('x' * 120),
                onHeight: (h) => reportedHeight = h,
                leading: const FloaterAppIcon(
                  PhosphorIconsRegular.wallet,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      double formHeight() =>
          tester.getRect(find.byType(GlassButton)).bottom + _bottomPadding;

      // The window opens at the empty form's height, to the pixel, and what
      // the form reports is the whole of it.
      expect(formHeight(), lessThanOrEqualTo(kFinanceFloaterSize.height));
      expect(kFinanceFloaterSize.height - formHeight(), lessThan(1.0));
      expect(reportedHeight, closeTo(formHeight(), 0.01));
      final opened = reportedHeight;

      // An amount over the cap puts the error line under the field, and the
      // reported height grows to take it in.
      await tester.enterText(find.byType(EditableText).first, '999999999.99');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Max ${formatCents(kMaxAmountCents)}'), findsOneWidget);
      expect(reportedHeight, greaterThan(opened));
      expect(reportedHeight, closeTo(formHeight(), 0.01));

      // A valid amount takes it away again.
      await tester.enterText(find.byType(EditableText).first, '12.50');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(reportedHeight, opened);

      // A failed save adds a message of no predictable height, which the
      // reported height takes in too.
      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.textContaining('Saved, but the step after it failed'),
        findsOneWidget,
      );
      expect(reportedHeight, greaterThan(opened));
      expect(reportedHeight, closeTo(formHeight(), 0.01));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
