import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/glass_button.dart';

void main() {
  testWidgets('GlassButton renders label and icon and responds to taps',
      (WidgetTester tester) async {
    bool tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassButton(
              onPressed: () => tapped = true,
              label: 'Sync Google',
              icon: const Icon(Icons.sync),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Sync Google'), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(tapped, isFalse);

    await tester.tap(find.byType(GlassButton));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
  });

  testWidgets('GlassButton supports custom color (recolorable) and size (resizeable)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassButton(
              onPressed: () {},
              label: 'Custom Glass',
              color: Colors.purple,
              width: 200,
              height: 50,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Custom Glass'), findsOneWidget);
    final Size buttonSize = tester.getSize(find.byType(GlassButton));
    expect(buttonSize.width, equals(200.0));
    expect(buttonSize.height, equals(50.0));
  });

  testWidgets('GlassButton handles disabled state correctly',
      (WidgetTester tester) async {
    bool tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassButton(
              onPressed: () => tapped = true,
              label: 'Disabled Glass',
              enabled: false,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(GlassButton));
    await tester.pumpAndSettle();

    expect(tapped, isFalse);
  });

  testWidgets('GlassButton renders in tight constraints without throwing layout assertion',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 15,
              height: 10,
              child: GlassButton(
                onPressed: () {},
                label: 'Constrained',
                dense: true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(GlassButton), findsOneWidget);
  });

  testWidgets('GlassButton renders inside ListTile.trailing without consuming full tile width',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 500,
              child: ListTile(
                title: const Text('Title'),
                subtitle: const Text('Subtitle'),
                trailing: GlassButton(
                  icon: const Icon(Icons.copy),
                  dense: true,
                  onPressed: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final Size buttonSize = tester.getSize(find.byType(GlassButton));
    expect(buttonSize.width, lessThan(100.0));
  });

  testWidgets('GlassButton renders label with normal font weight (not bolded)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassButton(
              onPressed: () {},
              label: 'Unbolded Text',
            ),
          ),
        ),
      ),
    );

    final Text textWidget = tester.widget(find.text('Unbolded Text'));
    expect(textWidget.style?.fontWeight, equals(FontWeight.normal));
  });

  testWidgets('GlassButton centers text vertically inside constrained height container',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 48,
              child: GlassButton(
                onPressed: () {},
                label: 'Add',
              ),
            ),
          ),
        ),
      ),
    );

    final Rect buttonRect = tester.getRect(find.byType(GlassButton));
    final Rect textRect = tester.getRect(find.text('Add'));

    final double topSpace = textRect.top - buttonRect.top;
    final double bottomSpace = buttonRect.bottom - textRect.bottom;

    // Verify top and bottom padding surrounding the text inside the button are balanced
    expect((topSpace - bottomSpace).abs(), lessThan(1.0));
  });

  testWidgets('GlassButton standardizes text and icon color to black text',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: GlassButton(
              onPressed: () {},
              label: 'Standardized Black Text',
              icon: const Icon(Icons.star),
              color: Colors.blue,
            ),
          ),
        ),
      ),
    );

    final Text textWidget = tester.widget(find.text('Standardized Black Text'));
    expect(textWidget.style?.color, equals(Colors.black87));

    final IconTheme iconThemeWidget = tester.widget(find.ancestor(
      of: find.byIcon(Icons.star),
      matching: find.byType(IconTheme),
    ).first);
    expect(iconThemeWidget.data.color, equals(Colors.black87));
  });
}
