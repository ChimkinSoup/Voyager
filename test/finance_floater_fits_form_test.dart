// The finance floater's window is a fixed size the form cannot talk back to,
// so the size has to be the form's own: room for the one line it routinely
// grows by — the error under the amount field — and nothing beyond that, or it
// opens above a band of dead background. Measured in the real theme and faces,
// which is what the form is actually laid out in: the stock Material theme
// puts the figure 50-odd pixels out.
//
// The failed-save line is the exception. Its message carries an exception
// string, so no fixed height covers it; the form reports how tall it is and
// the window grows by that instead of scrolling.

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
const _bottomPadding = 24.0;

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

      // The failed-save line's height, as the floater would be told it.
      var saveErrorHeight = 0.0;
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
                onSaved: () async => throw Exception('x' * 120),
                onSaveErrorHeight: (h) => saveErrorHeight = h,
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

      // An amount over the cap puts the error line under the field: the
      // tallest the form goes on its own, and the window's own height.
      await tester.enterText(find.byType(EditableText).first, '999999999.99');
      await tester.pump();
      expect(find.text('Max ${formatCents(kMaxAmountCents)}'), findsOneWidget);
      expect(formHeight(), kFinanceFloaterSize.height);

      // Without it the form is that one line short of the window, and no more:
      // the line's room is reserved, nothing else is.
      await tester.enterText(find.byType(EditableText).first, '12.50');
      await tester.pump();
      expect(formHeight(), lessThan(kFinanceFloaterSize.height));
      expect(
        kFinanceFloaterSize.height - formHeight(),
        lessThanOrEqualTo(24.0),
      );
      expect(saveErrorHeight, 0);

      // A failed save adds a message of no predictable height. It overflows
      // the window, and the reported height is what the window grows by, so
      // the form still does not have to scroll.
      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.textContaining('Saved, but the step after it failed'),
        findsOneWidget,
      );
      expect(formHeight(), greaterThan(kFinanceFloaterSize.height));
      expect(saveErrorHeight, greaterThan(0));
      expect(
        formHeight(),
        lessThanOrEqualTo(kFinanceFloaterSize.height + saveErrorHeight),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
