// Copying a profile link reports through a toast, not the page's bottom bar.
//
// A SnackBar slides in from the bottom edge of the whole page, which is a long
// way from the buttons at the top of the header that raised it — and it is the
// same bar undo prompts and errors use, so a one-word confirmation read as
// something that needed reading.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/jobs/jobs_header.dart';

Widget _header() => const MaterialApp(
  home: Scaffold(
    body: JobsHeader(
      lifetimeTotal: 3,
      statusCounts: [],
      dailyCounts: [],
      stages: [],
      includeArchived: false,
      onIncludeArchivedChanged: _ignoreBool,
      activeStatuses: {},
      onStatusTapped: _ignoreString,
      statusColors: _grey,
      profileLinkedInUrl: 'https://linkedin.com/in/example',
    ),
  ),
);

Color _grey(String _) => const Color(0xFF888888);

void _ignoreBool(bool _) {}
void _ignoreString(String _) {}

void main() {
  testWidgets('copying a profile link raises a toast, not a SnackBar', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(_header());
    await tester.pump();

    await tester.tap(find.byTooltip('Copy LinkedIn URL'));
    await tester.pumpAndSettle();

    expect(copied, ['https://linkedin.com/in/example']);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('LinkedIn copied'), findsOneWidget);
  });
}
