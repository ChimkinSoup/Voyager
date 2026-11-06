import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_markdown.dart';

void main() {
  group('gaiaMarkdownBlocks', () {
    test('cuts at a blank line before an unindented line', () {
      expect(gaiaMarkdownBlocks('One\ntwo\n\nThree\n\n# Four'), [
        'One\ntwo',
        'Three',
        '# Four',
      ]);
    });

    test('keeps a fence whole, blank lines and all, even unclosed', () {
      const fenced = '```dart\nfinal a = 1;\n\nfinal b = 2;\n```';
      expect(gaiaMarkdownBlocks('Intro\n\n$fenced\n\nAfter'), [
        'Intro',
        fenced,
        'After',
      ]);
      expect(gaiaMarkdownBlocks('Intro\n\n```\nopen\n\nstill code'), [
        'Intro',
        '```\nopen\n\nstill code',
      ]);
    });

    test('keeps a loose list together, and an indented continuation', () {
      expect(gaiaMarkdownBlocks('1. a\n\n2. b\n\n   more of b\n\nAfter'), [
        '1. a\n\n2. b\n\n   more of b',
        'After',
      ]);
    });

    test('the finished blocks keep their text as more streams in', () {
      final early = gaiaMarkdownBlocks('Para one.\n\nPara tw');
      final later = gaiaMarkdownBlocks('Para one.\n\nPara two.\n\n- a');
      expect(later.first, early.first);
    });
  });

  group('gaiaLinkTarget', () {
    test('follows only http and https', () {
      expect(gaiaLinkTarget('https://example.com/a'), isNotNull);
      expect(gaiaLinkTarget('http://example.com'), isNotNull);
      expect(gaiaLinkTarget('javascript:alert(1)'), isNull);
      expect(gaiaLinkTarget('file:///C:/Windows'), isNull);
      expect(gaiaLinkTarget('mailto:a@b.c'), isNull);
    });

    test('a path only when it exists here, a cited line aside', () {
      final dir = Directory.systemTemp.createTempSync('gaia_md');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}notes.txt')
        ..writeAsStringSync('x');
      expect(gaiaLinkTarget(file.path), Uri.file(file.path, windows: true));
      expect(gaiaLinkTarget('${file.path}:12'), isNotNull);
      expect(gaiaLinkTarget(dir.path), isNotNull);
      expect(gaiaLinkTarget(r'C:\no\such\place_gaia.txt'), isNull);
    }, testOn: 'windows');

    test('a path written before it exists links once it does', () async {
      final dir = Directory.systemTemp.createTempSync('gaia_md');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}later.txt';
      expect(gaiaLinkTarget(path), isNull);
      File(path).writeAsStringSync('x');
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(gaiaLinkTarget(path), isNotNull);
    }, testOn: 'windows');
  });

  group('gaiaOpensDirectly', () {
    bool opens(String path) => gaiaOpensDirectly(Uri.file(path, windows: true));

    test('a URL, and a file of a type that runs nothing', () {
      expect(gaiaOpensDirectly(Uri.parse('https://a.com/b.exe')), isTrue);
      expect(opens(r'C:\a b\notes.txt'), isTrue);
      expect(opens(r'C:\a\REPORT.PDF'), isTrue);
    });

    test('not a program, a script or a type it does not know', () {
      for (final path in [
        r'C:\a\payload.exe',
        r'C:\a\payload.BAT',
        r'C:\a\payload.lnk',
        r'C:\a\payload.ps1',
        r'C:\a\payload.py',
        r'C:\a\payload.js',
        r'C:\a\page.html',
        r'C:\a\book.xlsm',
        r'C:\a\notes.txt.exe',
        r'C:\a\no_extension',
        r'C:\a\payload.exe.',
      ]) {
        expect(opens(path), isFalse, reason: path);
      }
    });

    test('a folder, whatever its name', () {
      final dir = Directory.systemTemp.createTempSync('gaia_md');
      addTearDown(() => dir.deleteSync(recursive: true));
      final folder = Directory('${dir.path}${Platform.pathSeparator}odd.exe')
        ..createSync();
      expect(opens(folder.path), isTrue);
    }, testOn: 'windows');
  });

  group('gaiaHrefTarget', () {
    test("leaves a URL's escapes as they are", () {
      expect(
        '${gaiaHrefTarget('https://a.com/?q=a%26b')}',
        'https://a.com/?q=a%26b',
      );
      expect(
        '${gaiaHrefTarget('https://a.com/caf%E9')}',
        'https://a.com/caf%E9',
      );
    });

    test('unescapes a path, as the parser escapes its backslashes', () {
      final dir = Directory.systemTemp.createTempSync('gaia md');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(gaiaHrefTarget(Uri.encodeFull(dir.path)), isNotNull);
    }, testOn: 'windows');

    test("a path that doesn't decode stays text", () {
      expect(gaiaHrefTarget('C:/caf%E9'), isNull);
    });
  });

  Future<void> pump(WidgetTester tester, String text) => tester.pumpWidget(
    MaterialApp(
      theme: VoyagerTheme.dark(),
      home: Scaffold(
        body: SizedBox(width: 600, child: GaiaMarkdown(text: text)),
      ),
    ),
  );

  String plain(WidgetTester tester) => [
    for (final element in find.byType(RichText).evaluate())
      (element.widget as RichText).text.toPlainText(),
  ].join('|');

  testWidgets('renders blocks without their syntax', (tester) async {
    await pump(
      tester,
      '# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n\n'
      '> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |',
    );
    final text = plain(tester);
    expect(text, contains('Title'));
    expect(text, contains('Some bold and code.'));
    expect(text, isNot(contains('**')));
    expect(text, contains('•'));
    expect(text, contains('one'));
    expect(text, contains('quoted'));
    expect(find.byType(Table), findsOneWidget);
  });

  /// Every span that's a link.
  List<TextSpan> links(WidgetTester tester) {
    final found = <TextSpan>[];
    for (final element in find.byType(RichText).evaluate()) {
      (element.widget as RichText).text.visitChildren((span) {
        if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
          found.add(span);
        }
        return true;
      });
    }
    return found;
  }

  String linkText(WidgetTester tester) =>
      links(tester).map((span) => span.text).join();

  testWidgets(
    'with no menu given, right-click shows the platform one',
    (tester) async {
      await pump(tester, 'Some words to select.');
      final word = tester.getCenter(find.byType(RichText));
      // A double click selects the word under it.
      await tester.tapAt(word, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(word, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tapAt(
        word,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  group('references', () {
    test('a text with a definition stays one block', () {
      const text = 'See [docs][ref].\n\nMore.\n\n[ref]: https://example.com';
      expect(gaiaMarkdownBlocks(text), [text]);
    });

    testWidgets('a link finds its definition in a later block', (tester) async {
      await pump(tester, 'See [docs][ref].\n\n[ref]: https://example.com');
      expect(plain(tester), isNot(contains('[ref]')));
      expect(linkText(tester), 'docs');
    });

    testWidgets('a footnote finds its note in a later block', (tester) async {
      await pump(tester, 'A claim.[^1]\n\n[^1]: The note.');
      expect(plain(tester), isNot(contains('[^1]')));
      expect(plain(tester), contains('The note.'));
    });
  });

  group('link text', () {
    testWidgets('keeps its formatting, every part of it the link', (
      tester,
    ) async {
      await pump(tester, '[**bold** and `code` link](https://example.com)');
      expect(linkText(tester), 'bold and code link');
      expect(links(tester).first.style!.fontWeight, FontWeight.w700);
    });

    testWidgets('of an image is its alt text', (tester) async {
      await pump(tester, '[![build](https://x.com/b.png)](https://x.com)');
      expect(linkText(tester), 'build');
    });
  });

  testWidgets('a task item counts in its list', (tester) async {
    await pump(tester, '1. [x] done\n2. plain\n3. last');
    final text = plain(tester);
    expect(text, contains('2.'));
    expect(text, contains('3.'));
    expect(text, isNot(contains('1.')));
  });

  group('task checkboxes', () {
    final circles = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          (widget.decoration as BoxDecoration?)?.shape == BoxShape.circle,
    );

    testWidgets('nest their items under their text', (tester) async {
      await pump(tester, '- [ ] Parent:\n  - [x] Child\n  - Bullet');
      final parent = tester.getTopLeft(circles.first).dx;
      expect(tester.getTopLeft(circles.last).dx, greaterThan(parent));
      expect(
        tester.getTopLeft(find.text('◦')).dx,
        closeTo(tester.getTopLeft(circles.last).dx, 0.5),
      );
    });

    testWidgets('are centred where a bullet is', (tester) async {
      await pump(tester, '- Bullet\n- [ ] Task');
      expect(
        tester.getCenter(find.text('•')).dx,
        closeTo(tester.getCenter(circles.first).dx, 0.5),
      );
      // The task's text follows its checkbox's placeholder in one paragraph.
      final task = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains('Task'),
        ),
      );
      final taskText = task.localToGlobal(
        task.getOffsetForCaret(const TextPosition(offset: 1), Rect.zero),
      );
      expect(
        tester.getTopLeft(find.text('Bullet')).dx,
        closeTo(taskText.dx, 0.5),
      );
    });
    const text = '- [x] one\n- [ ] two\n\nBetween.\n\n- [ ] three';

    Future<void> pumpTasks(
      WidgetTester tester,
      Set<int> checks,
      ValueChanged<int>? onCheck,
    ) => tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: GaiaMarkdown(text: text, checks: checks, onCheck: onCheck),
        ),
      ),
    );

    testWidgets('are circles, ticked as written', (tester) async {
      await pumpTasks(tester, const {}, null);
      expect(circles, findsNWidgets(3));
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(plain(tester), isNot(contains('☑')));
    });

    testWidgets('tap with their index through every block', (tester) async {
      final tapped = <int>[];
      await pumpTasks(tester, const {}, tapped.add);
      for (var i = 0; i < 3; i++) {
        await tester.tap(circles.at(i));
      }
      expect(tapped, [0, 1, 2]);
    });

    testWidgets('show the other way for each index checked', (tester) async {
      await pumpTasks(tester, const {}, (_) {});
      await pumpTasks(tester, const {0, 2}, (_) {});
      // One untick, two left as written, three ticked.
      expect(find.byIcon(Icons.check), findsOneWidget);
      final ticked = tester.widget<Container>(circles.at(2));
      expect((ticked.decoration! as BoxDecoration).color, isNotNull);
    });

    testWidgets('ticked in a later block leave earlier ones unbuilt', (
      tester,
    ) async {
      RichText between() => tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('Between'),
        ),
      );
      await pumpTasks(tester, const {}, (_) {});
      final before = between();
      await pumpTasks(tester, const {2}, (_) {});
      expect(between(), same(before));
    });

    testWidgets('copy as the box for how each is shown', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await pumpTasks(tester, const {0, 2}, (_) {});
      await tester.tapAt(
        tester.getCenter(find.textContaining('Between')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .contextMenuButtonItems
          .firstWhere((button) => button.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
      expect(copied, '☐ one\n☐ two\nBetween.\n☑ three');
    });
  });

  test('a text part keeps its checks through JSON', () {
    final part = const GaiaTextPart(
      '- [ ] a',
    ).withCheck(0, true).withCheck(3, true);
    final back = GaiaPart.fromJson(part.toJson()) as GaiaTextPart;
    expect(back.checks, {0, 3});
    expect(back.withCheck(0, false).checks, {3});
    expect(back.withCheck(3, true).checks, {0, 3});
    expect(const GaiaTextPart('x').toJson().containsKey('checks'), isFalse);
  });

  testWidgets('a code block copies its code', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await pump(tester, 'Run:\n\n```dart\nvoid main() {\n  print(1);\n}\n```');
    expect(find.text('dart'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();
    expect(copied, 'void main() {\n  print(1);\n}');
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byIcon(Icons.content_copy), findsOneWidget);
  });

  testWidgets('a streaming reply rebuilds only its last block', (tester) async {
    await pump(tester, 'First paragraph.\n\nSecond');
    final first = tester.renderObject<RenderParagraph>(
      find.byType(RichText).first,
    );
    await pump(tester, 'First paragraph.\n\nSecond, longer now');
    expect(
      tester.renderObject<RenderParagraph>(find.byType(RichText).first),
      same(first),
    );
    expect(plain(tester), contains('Second, longer now'));
  });

  testWidgets('an unclosed fence shows as code while it streams', (
    tester,
  ) async {
    await pump(tester, 'Here:\n\n```python\nx = 1\n');
    expect(find.byType(GaiaCodeBlock), findsOneWidget);
    expect(plain(tester), contains('x = 1'));
  });

  group('math', () {
    /// Each equation's style, failing on one that didn't parse.
    Iterable<MathStyle> typeset(WidgetTester tester) => tester
        .widgetList<Math>(find.byType(Math))
        .map(
          (math) => math.parseError == null ? math.mathStyle : fail('$math'),
        );

    testWidgets('typesets inline and display LaTeX without its delimiters', (
      tester,
    ) async {
      await pump(
        tester,
        r'Euler: $e^{i\pi} + 1 = 0$ and \(a_1 * b_2\).'
        '\n\n'
        r'$$\int_0^1 x\,dx = \frac{1}{2}$$'
        '\n\n'
        r'\[x^2\]',
      );
      expect(typeset(tester), [
        MathStyle.text,
        MathStyle.text,
        MathStyle.display,
        MathStyle.display,
      ]);
      expect(plain(tester), isNot(contains(r'$')));
      expect(plain(tester), isNot(contains(r'\')));
    });

    testWidgets('leaves prices, escaped dollars and code alone', (
      tester,
    ) async {
      await pump(
        tester,
        r'It costs $5 to $10, or \$3 each.'
        '\n\n'
        r'Run `echo $HOME $PATH`.',
      );
      expect(find.byType(Math), findsNothing);
      expect(plain(tester), contains(r'It costs $5 to $10, or $3 each.'));
      expect(plain(tester), contains(r'echo $HOME $PATH'));
    });

    testWidgets('leaves an escaped link alone', (tester) async {
      await pump(tester, r'An \[escaped link\](x) and \[y^2\] after.');
      expect(typeset(tester), [MathStyle.display]);
      expect(plain(tester), contains('An [escaped link](x) and'));
    });

    testWidgets('leaves shell variables alone', (tester) async {
      await pump(
        tester,
        r'Set $HOME/$PATH, $FOO,$BAR and ${A}/${B}, or $(a)/$(b).',
      );
      expect(find.byType(Math), findsNothing);
      expect(plain(tester), contains(r'$HOME/$PATH, $FOO,$BAR'));
    });

    testWidgets('an equation is typeset once it closes, mid-stream', (
      tester,
    ) async {
      await pump(tester, r'So $$\frac{a}{b');
      expect(find.byType(Math), findsNothing);
      await pump(tester, r'So $$\frac{a}{b}$$ and $x');
      expect(typeset(tester), [MathStyle.display]);
      expect(plain(tester), contains(r'and $x'));
      await pump(tester, r'So $$\frac{a}{b}$$ and $x$');
      expect(typeset(tester), [MathStyle.display, MathStyle.text]);
    });

    testWidgets('display math on lines of its own stays TeX, line by line', (
      tester,
    ) async {
      await pump(tester, 'So\n\$\$\na\n- b\n=\nc\n\$\$\nafter');
      expect(typeset(tester), [MathStyle.display]);
      expect(find.text('•'), findsNothing);
      expect(plain(tester), startsWith('So|'));
      expect(plain(tester), contains('after'));
    });

    testWidgets('display math with text after it stays in its paragraph', (
      tester,
    ) async {
      await pump(tester, r'$$x^2$$ is the area.');
      expect(typeset(tester), [MathStyle.display]);
      expect(plain(tester), contains('is the area.'));
    });

    testWidgets('unclosed display math streams as text, not a list', (
      tester,
    ) async {
      await pump(tester, '\$\$\na\n- b');
      expect(find.byType(Math), findsNothing);
      expect(find.text('•'), findsNothing);
      expect(plain(tester), '\$\$\na\n- b');
      await pump(tester, '\$\$\na\n- b\n\$\$');
      expect(typeset(tester), [MathStyle.display]);
    });

    testWidgets('LaTeX that does not parse shows as written', (tester) async {
      await pump(tester, r'Bad: $\frac{a$');
      expect(find.text(r'$\frac{a$'), findsOneWidget);
    });
  });

  testWidgets('a selection across blocks copies them a line apart', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await pump(tester, 'One para.\n\n- item\n\n```\ncode\n```');
    final region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    // Dragged with the mouse, from the first word to past the code.
    final gesture = await tester.startGesture(
      tester.getTopLeft(find.textContaining('One para.')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(tester.getBottomRight(find.byType(GaiaCodeBlock)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    region.contextMenuButtonItems
        .firstWhere((button) => button.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();
    expect(copied, 'One para.\nitem\ncode');
  });

  group('a selection copies the TeX it crosses as written', () {
    late String? copied;
    setUp(() => copied = null);

    Future<void> copy(WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .contextMenuButtonItems
          .firstWhere((button) => button.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
    }

    const text = 'Area \$x^2\$ and\n\n\$\$y_1\$\$\n\n- a \\(z\\)\n\nend';
    const written = 'Area \$x^2\$ and\n\$\$y_1\$\$\na \\(z\\)\nend';

    testWidgets('dragged across', (tester) async {
      await pump(tester, text);
      final gesture = await tester.startGesture(
        tester.getTopLeft(find.textContaining('Area')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(tester.getBottomRight(find.textContaining('end')));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await copy(tester);
      expect(copied, written);
    });

    testWidgets('a long inline list wraps at its commas, copied whole', (
      tester,
    ) async {
      const long =
          r'$S_1 = \{P, \neg Q, \neg R, S, \neg T\}, \{\neg Q\}, '
          r'\{P, \neg R, \neg S\}, \{Q, R, \neg S\}, \{P, \neg Q, R, S, \neg T\}, '
          r'\{\neg P, \neg Q, \neg S, \neg T\}, \{P, \neg Q, R, \neg T\}, '
          r'\{Q, \neg R, S, T\}, \{P, \neg Q, R, S\}, \{\neg P, S\}, '
          r'\{P, \neg Q, T\}$';
      await pump(tester, long);
      expect(tester.takeException(), isNull);
      expect(find.byType(Math), findsNWidgets(11));
      await tester.tapAt(
        tester.getCenter(find.byType(Math).first),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      await copy(tester);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(copied, long);
    });

    testWidgets('inline math with a group-wide command stays whole', (
      tester,
    ) async {
      for (final tex in [r'$a, b \over c$', r'$\color{red} x, y$']) {
        await pump(tester, tex);
        expect(find.byType(Math), findsOneWidget, reason: tex);
      }
    });

    testWidgets('all selected', (tester) async {
      await pump(tester, text);
      await tester.tapAt(
        tester.getCenter(find.textContaining('end')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      await copy(tester);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(copied, written);
    });
  });
}
