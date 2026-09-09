import 'package:flutter/widgets.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:voyager/core/text/html_to_markers.dart';

/// The clipboard's HTML flavour, or null when it holds none.
///
/// A replaceable function rather than an injected object: prose fields are
/// built in a dozen places and none of them should have to know the clipboard
/// exists, while a test still needs a seam to put a Word fragment through.
@visibleForTesting
Future<String?> Function() readClipboardHtml = _readClipboardHtml;

Future<String?> _readClipboardHtml() async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return null;
  final reader = await clipboard.read();
  if (!reader.canProvide(Formats.htmlText)) return null;
  return reader.readValue(Formats.htmlText);
}

/// Pastes into [editable], converting rich HTML to Voyager's markers on the
/// way (EMPHASIS_FORMATTING.md §7).
///
/// Falls back to the field's own [EditableTextState.pasteText] whenever the
/// clipboard has no HTML in it, or its HTML holds no text — plain text is
/// pasted as-is, markers and all, and every rule the field already has for a
/// paste stays where it is.
///
/// The write goes through [EditableTextState.userUpdateTextEditingValue] for
/// the reasons every other programmatic write in the app does: input
/// formatters, `onChanged` (autosave and the journal CRDT), spellcheck and
/// undo history all hang off that path. It is also what keeps §7's third rule
/// true for free — a multi-character insert is not typing, so autocorrect
/// leaves the pasted tokens alone.
Future<void> pasteProse(EditableTextState editable) async {
  final html = await readClipboardHtml();
  final markers = html == null ? '' : htmlToProseMarkers(html);
  if (markers.isEmpty) {
    await editable.pasteText(SelectionChangedCause.keyboard);
    return;
  }
  if (!editable.mounted) return;
  final value = editable.textEditingValue;
  final selection = value.selection;
  if (!selection.isValid) return;
  editable.userUpdateTextEditingValue(
    TextEditingValue(
      text:
          selection.textBefore(value.text) +
          markers +
          selection.textAfter(value.text),
      selection: TextSelection.collapsed(
        offset: selection.start + markers.length,
      ),
    ),
    SelectionChangedCause.keyboard,
  );
  editable.bringIntoView(editable.textEditingValue.selection.extent);
  editable.hideToolbar();
}

/// Marks a subtree whose text field pastes rich clipboard HTML as markers.
///
/// Published by `VimTextScope`, which is what already knows a field is
/// multiline prose rather than a code editor or a snippet trigger, and read by
/// `MediaPasteScope` — the one place that has to route a paste it intercepted
/// back to a field it does not otherwise know anything about.
class ProsePasteScope extends InheritedWidget {
  const ProsePasteScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  /// Read without depending: the caller is a paste handler, not a build.
  static bool enabledAt(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ProsePasteScope>()?.enabled ??
      false;

  @override
  bool updateShouldNotify(ProsePasteScope oldWidget) =>
      oldWidget.enabled != enabled;
}
