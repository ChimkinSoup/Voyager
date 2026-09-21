import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/text/prose_paste.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';

/// Smart paste (EMPHASIS_FORMATTING.md §7) through the real field stack: the
/// HTML converter has its own tests, so what these cover is the routing — who
/// claims Ctrl+V, and which fields get markers rather than plain text.
///
/// The plain-text half goes through the framework's own clipboard channel; the
/// HTML half through [readClipboardHtml], the seam the platform clipboard is
/// read behind.
void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  String? plainText;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
    plainText = null;
    readClipboardHtml = () async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return plainText == null
                ? null
                : <String, dynamic>{'text': plainText};
          }
          return null;
        });
  });

  tearDown(() {
    readClipboardHtml = () async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pumpField(
    WidgetTester tester, {
    int? maxLines,
    bool autocorrectAllowed = true,
    bool insideMediaScope = false,
  }) async {
    Widget field = Scaffold(
      body: LabeledTextField(
        label: 'Body',
        controller: controller,
        focusNode: focusNode,
        maxLines: maxLines,
        autocorrectAllowed: autocorrectAllowed,
      ),
    );
    if (insideMediaScope) {
      field = MediaPasteScope(
        collection: 'journal',
        documentId: 'one',
        clipboard: const _NoMediaClipboard(),
        child: field,
      );
    }
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: field)));
    focusNode.requestFocus();
    await tester.pump();
  }

  Future<void> pressPaste(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('rich HTML pastes as markers', (tester) async {
    readClipboardHtml = () async => 'a <b>bold</b> word';
    await pumpField(tester, maxLines: null);
    await pressPaste(tester);
    expect(controller.text, 'a **bold** word');
  });

  testWidgets('plain text pastes unchanged, markers and all', (tester) async {
    // §7 rule 1: a clipboard with no HTML in it is inserted as-is.
    plainText = 'already **marked**';
    await pumpField(tester, maxLines: null);
    await pressPaste(tester);
    expect(controller.text, 'already **marked**');
  });

  testWidgets('a single-line field never converts', (tester) async {
    // Excluded from emphasis in v1 (§10), so its markers stay literal — and
    // so does anything pasted into it.
    readClipboardHtml = () async => 'a <b>bold</b> word';
    plainText = 'a bold word';
    await pumpField(tester, maxLines: 1);
    await pressPaste(tester);
    expect(controller.text, 'a bold word');
  });

  testWidgets('a literal-text field never converts', (tester) async {
    // The §4.1 exclusions all pass autocorrectAllowed: false.
    readClipboardHtml = () async => 'a <b>bold</b> word';
    plainText = 'a bold word';
    await pumpField(tester, maxLines: null, autocorrectAllowed: false);
    await pressPaste(tester);
    expect(controller.text, 'a bold word');
  });

  testWidgets('the paste lands at the caret, not at the end', (tester) async {
    readClipboardHtml = () async => '<i>in</i>';
    await pumpField(tester, maxLines: null);
    controller.value = const TextEditingValue(
      text: 'ab',
      selection: TextSelection.collapsed(offset: 1),
    );
    await tester.pump();
    await pressPaste(tester);
    expect(controller.text, 'a*in*b');
    expect(controller.selection.baseOffset, 5);
  });

  testWidgets('a selection is replaced', (tester) async {
    readClipboardHtml = () async => '<b>new</b>';
    await pumpField(tester, maxLines: null);
    controller.value = const TextEditingValue(
      text: 'old text',
      selection: TextSelection(baseOffset: 0, extentOffset: 3),
    );
    await tester.pump();
    await pressPaste(tester);
    expect(controller.text, '**new** text');
  });

  testWidgets('a field inside a media paste scope still converts', (
    tester,
  ) async {
    // The scope owns Ctrl+V for its gallery, so the field must not claim it —
    // the scope routes the text half through the same converter instead.
    readClipboardHtml = () async => 'a <mark>lit</mark> word';
    await pumpField(tester, maxLines: null, insideMediaScope: true);
    await pressPaste(tester);
    expect(controller.text, 'a ==lit== word');
  });
}

/// A clipboard holding text and no image, so [MediaPasteScope] routes to the
/// field rather than to its gallery.
class _NoMediaClipboard extends MediaClipboard {
  const _NoMediaClipboard();

  @override
  Future<({bool hasText, bool hasImage})> peek() async =>
      (hasText: true, hasImage: false);

  @override
  Future<MediaClipboardContents> read() async =>
      const MediaClipboardContents(text: '', imageBytes: null);
}
