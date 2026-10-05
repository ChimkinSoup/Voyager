import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/auth_notifier.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/auth/login_page.dart';

/// Signed out; every e-mail sign-in is refused, and a reset is refused for
/// any address containing "bad".
class _Auth implements AuthRepository {
  @override
  String? get currentUserId => null;

  @override
  Stream<bool> get authStateChanges => const Stream.empty();

  @override
  Future<void> signInWithEmail(String email, String password) async {
    // A frame or more, as a real round trip takes, so the page rebuilds busy
    // (buttons and fields disabled) before the refusal.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    throw Exception('Wrong password.');
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (email.contains('bad')) throw Exception('No account for this email.');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Which of the page's two text fields holds focus: 0 = Email, 1 = Password.
int? _focusedField(WidgetTester tester) {
  final fields = tester
      .widgetList<EditableText>(find.byType(EditableText))
      .toList();
  for (var i = 0; i < fields.length; i++) {
    if (fields[i].focusNode.hasFocus) return i;
  }
  return null;
}

/// Whether the glass button labelled [label] draws its focus ring (the
/// 2px-spread shadow).
bool _ringOn(WidgetTester tester, String label) {
  final box = tester.widget<AnimatedContainer>(
    find
        .ancestor(
          of: find.text(label),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  final shadows = (box.decoration! as BoxDecoration).boxShadow ?? const [];
  return shadows.any((s) => s.spreadRadius == 2.0);
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

/// The keyboard tests run as Windows: the page autofocuses only off Android,
/// and flutter_test's default platform is Android.
void main() {
  Future<void> pumpLogin(WidgetTester tester) async {
    final auth = _Auth();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(auth),
          authNotifierProvider.overrideWith((ref) => AuthNotifier(auth)),
        ],
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'Email has focus on arrival, and Tab moves to Password',
    (tester) async {
      await pumpLogin(tester);
      expect(_focusedField(tester), 0);

      await _press(tester, LogicalKeyboardKey.tab);
      expect(_focusedField(tester), 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Enter and Space activate the focused button',
    (tester) async {
      await pumpLogin(tester);

      // Email → Password → Forgot password?
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.enter);
      expect(find.text('Enter your email to reset your password.'), findsOne);
      // Back in the empty field that needs filling.
      await tester.pump();
      expect(_focusedField(tester), 0);

      // Email → Password → Forgot password? → Sign in
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.space);
      expect(find.text('Email and password are required.'), findsOne);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Create account is reachable and activates by keyboard',
    (tester) async {
      await pumpLogin(tester);

      // Backwards from Email wraps to the last control on the page.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _press(tester, LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _press(tester, LogicalKeyboardKey.enter);

      expect(find.text('Sign up'), findsOne);
      expect(find.text('Have an account? Sign in'), findsOne);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a button pressed by keyboard drops its ring once it fails',
    (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(EditableText).at(0), 'qa@example.com');
      await tester.enterText(find.byType(EditableText).at(1), 'wrong');

      // Password → Forgot password? → Sign in
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.tab);
      expect(_ringOn(tester, 'Sign in'), isTrue);
      await _press(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Wrong password.'), findsOne);
      expect(_focusedField(tester), 1);
      expect(_ringOn(tester, 'Sign in'), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a password reset, refused or sent, leaves focus in Email',
    (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(EditableText).at(0), 'bad@example');

      // Email → Password → Forgot password?
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('No account for this email.'), findsOne);
      expect(_focusedField(tester), 0);

      await tester.enterText(find.byType(EditableText).at(0), 'qa@example.com');
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.tab);
      await _press(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('a password reset link has been sent'),
        findsOne,
      );
      expect(_focusedField(tester), 0);
      expect(_ringOn(tester, 'Forgot password?'), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'nothing is focused on arrival on Android',
    (tester) async {
      await pumpLogin(tester);
      expect(_focusedField(tester), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a failed sign-in leaves focus in the password field',
    (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(EditableText).at(0), 'qa@example.com');
      await tester.enterText(find.byType(EditableText).at(1), 'wrong');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('Wrong password.'), findsOne);
      expect(_focusedField(tester), 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
