import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/voyager_app.dart';

void main() {
  testWidgets('app renders login screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: VoyagerApp()));
    await tester.pumpAndSettle();
    expect(find.text('Voyager'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
