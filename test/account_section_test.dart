// Settings → Account's change-password dialog, while the change is out.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/features/settings/account_section.dart';

/// Signed in with a password, and every change held until [held] completes.
class _HeldAuthRepository extends InMemoryAuthRepository {
  final held = Completer<void>();

  @override
  Future<void> changePassword(String currentPassword, String newPassword) =>
      held.future;
}

Finder _field(String label) => find.descendant(
  of: find.widgetWithText(LabeledTextField, label),
  matching: find.byType(TextField),
);

void main() {
  testWidgets('a spinner shows on Change while the password is changed', (
    tester,
  ) async {
    final auth = _HeldAuthRepository();
    await auth.signInWithEmail('me@example.com', 'old');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
        child: const MaterialApp(
          home: Scaffold(body: AccountSettingsSection()),
        ),
      ),
    );
    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    final spinner = find.byType(CircularProgressIndicator);
    expect(spinner, findsNothing);

    await tester.enterText(_field('Current password'), 'old');
    await tester.enterText(_field('New password'), 'new');
    await tester.enterText(_field('Confirm new password'), 'new');
    await tester.tap(find.text('Change'));
    await tester.pump();
    expect(spinner, findsOneWidget);

    auth.held.complete();
    await tester.pumpAndSettle();
    expect(spinner, findsNothing);
    expect(find.text('Password changed'), findsOneWidget);
  });
}
