import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/snippets/snippet_session.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/vim/vim_text_ops.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// WCAG relative-luminance cutoff: below this the accent reads as dark and the
/// glyph on the block switches to a constant light foreground.
const double kVimDarkCaretLuminanceThreshold = 0.5;

/// Constant foreground for the glyph repainted on the block caret — the same
/// regardless of syntax or tag colouring underneath, like VS Code.
Color vimBlockCaretForeground(Color caretColor) {
  return caretColor.computeLuminance() < kVimDarkCaretLuminanceThreshold
      ? const Color(0xFFFFFFFF)
      : const Color(0xFF000000);
}

/// The character the block caret sits on when the document itself has none: the
/// first letter of the field's placeholder, which is on screen exactly while
/// [text] is empty. Null when there is nothing to sit on.
///
/// Split out and public for the tests: the width it drives is unobservable in a
/// widget test, where every glyph of the test font — a space included — is one
/// em wide.
String? vimHintCaretGlyph({required String text, required String? hintText}) {
  if (text.isNotEmpty || hintText == null || hintText.isEmpty) return null;
  // Runes, not `hintText[0]`: a code unit on its own would split a surrogate
  // pair into an unpaintable half.
  return String.fromCharCodes(hintText.runes.take(1));
}

/// Top-left passed to [TextPainter.paint] so [probe]'s glyph ink lands on
/// [blockRect] — the same character's box from the paragraph under the caret.
///
/// Painting at [TextPainter.getOffsetForCaret] instead leaves the inverted
/// glyph a hair above the real one whenever strut / line-height put leading
/// above the ink (dream-journal `bodySmall` is the obvious case): the caret
/// origin is the top of the line box, while a single-character [TextPainter]
/// lays its glyph out relative to *its* own metrics, and the two tops do not
/// coincide.
Offset vimCaretGlyphPaintOrigin({
  required TextPainter probe,
  required int glyphLength,
  required Rect blockRect,
}) {
  final boxes = probe.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: glyphLength),
  );
  if (boxes.isEmpty) return blockRect.topLeft;
  final probeBox = boxes.first.toRect();
  return Offset(
    blockRect.left - probeBox.left,
    blockRect.top - probeBox.top,
  );
}

/// Paints Vim's own caret, Visual-mode selection and search highlights over a
/// text field, instead of letting Flutter's [EditableText] draw them.
///
/// Everything here exists because `EditableText` exposes no hook for the three
/// things Vim needs:
///
///  * **The block caret.** `cursorWidth` is a single number, so a block sized
///    for "m" swallows the letter after an "l" and half-covers an "m" in a
///    proportional face. Measuring the glyph under the caret is the only way
///    to get a block that is exactly one character wide (and as tall as the
///    line, like a terminal cell — a tight ink box with rounded corners was
///    shaving the letter and reading as a vertical jump).
///  * **A caret in Visual mode.** Flutter hides the caret whenever the
///    selection is not collapsed, and Visual mode *is* a selection — so the
///    cursor disappeared for the whole time you were extending one.
///  * **A blink you cannot switch off.** `EditableText` owns its blink timer;
///    a Normal-mode block that pulses reads as an unresponsive field, and it
///    repaints the field twice a second for nothing.
///
/// Selection is drawn here too, for a reason of its own: a linewise (`V`)
/// selection spans the newline at the end of each line, and a covered newline
/// is not a character the paragraph can measure. [_fillRange] therefore splits
/// the range at newlines and asks for each line's own boxes, which buys two
/// different things:
///
///  * **A blank line gets marked at all.** It has no glyphs, so
///    [TextPainter.getBoxesForSelection] returns nothing for it and skipping
///    it would leave a hole in the middle of the highlight. It is the one case
///    that needs drawing rather than measuring — it gets the same space-wide
///    mark the OS selection leaves there.
///  * **A short line stays short.** At [BoxWidthStyle.max] a covered break is
///    given the width of the widest line in the paragraph, so `V` over a
///    ragged block paints a solid rectangle out to the longest line rather
///    than tracing the text. The default [BoxWidthStyle.tight] used here does
///    not do that on its own, so this is belt-and-braces — but `max` is
///    `RenderEditable`'s desktop default, and "match the field" is an easy
///    change to make by accident.
///
/// Positioned by its caller exactly like `SpellCheckSquiggleLayer`: same
/// [style]/[strutStyle]/padding as the field, inside a `Positioned.fill` under
/// an `IgnorePointer`, so the [TextPainter] here lays the text out identically
/// and every box it reports lands where the real glyph is.
///
/// Unlike the squiggle layer this one goes *above* the field, not behind it.
/// Material paints a caret beneath the text on Windows and Android
/// (`paintCursorAboveText: false`), so the block caret is drawn here instead
/// of in [EditableText]. The block is fully opaque; the glyph it sits on is
/// repainted on top in a constant high-contrast colour (like VS Code's block
/// cursor), switching to white when the accent's relative luminance is low.
class VimTextOverlay extends StatefulWidget {
  const VimTextOverlay({
    super.key,
    required this.session,
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.accentColor,
    this.snippetSession,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.scrollController,
    this.hintText,
  });

  /// Null on a field that has snippets but not Vim, where this layer exists
  /// only to draw the tabstop marks.
  final VimSession? session;

  /// The field's snippet runtime, when it has one. Only its remaining tabstops
  /// are read — the dotted marks in [_paintTabstops] — and only while a session
  /// is live, so a field with no expansion open pays one listener and paints
  /// nothing.
  final SnippetSession? snippetSession;

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final Color accentColor;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;

  /// The field's placeholder, if it has one.
  ///
  /// The hint stays up in Normal and Visual mode — it only goes away once the
  /// document has text in it — so on an empty field the block caret does have a
  /// glyph to sit on after all: the placeholder's first character. Without this
  /// the block falls back to one space's advance width, which is narrower than
  /// most letters, and a hint like "Start writing..." left half its "S" poking
  /// out past the block's edge.
  ///
  /// Only sound because the hint is painted with the field's own text metrics
  /// (see `fieldHintStyle`), so the glyph measured here in [style] is the width
  /// the placeholder actually drew.
  final String? hintText;

  /// The same [ScrollController] the field's [TextField] was given, when it
  /// can scroll internally.
  final ScrollController? scrollController;

  @override
  State<VimTextOverlay> createState() => _VimTextOverlayState();
}

class _VimTextOverlayState extends State<VimTextOverlay> {
  @override
  void initState() {
    super.initState();
    _listen(widget);
  }

  @override
  void didUpdateWidget(covariant VimTextOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.snippetSession != widget.snippetSession ||
        oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode) {
      _unlisten(oldWidget);
      _listen(widget);
    }
  }

  @override
  void dispose() {
    _unlisten(widget);
    super.dispose();
  }

  void _listen(VimTextOverlay w) {
    w.controller.addListener(_repaint);
    w.focusNode.addListener(_repaint);
    final session = w.session;
    if (session != null) {
      session.modeListenable.addListener(_repaint);
      session.searchHighlightListenable.addListener(_repaint);
      // Not redundant with the controller: in linewise Visual the caret moves
      // without the selection changing — see [VimSession.caretListenable].
      session.caretListenable.addListener(_repaint);
    }
    // Fires on expansion, on Tab, and on the edits that push the stops along
    // the text — the controller listener above repaints on the same edit, so
    // both have to be current for a mark to stay on its character.
    w.snippetSession?.marksListenable.addListener(_repaint);
  }

  void _unlisten(VimTextOverlay w) {
    w.controller.removeListener(_repaint);
    w.focusNode.removeListener(_repaint);
    final session = w.session;
    if (session != null) {
      session.modeListenable.removeListener(_repaint);
      session.searchHighlightListenable.removeListener(_repaint);
      session.caretListenable.removeListener(_repaint);
    }
    w.snippetSession?.marksListenable.removeListener(_repaint);
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final mode = session?.mode ?? VimMode.insert;
    final highlightPattern = session?.searchHighlightListenable.value ?? '';
    final marks =
        widget.snippetSession?.marksListenable.value ?? SnippetMarks.none;
    // Insert mode with nothing highlighted and no tabstops open is the ordinary
    // case and the field draws its own caret there, so this whole layer paints
    // nothing.
    final idle =
        mode == VimMode.insert && highlightPattern.isEmpty && marks.isEmpty;
    if (idle || !widget.focusNode.hasFocus) return const SizedBox.shrink();

    // Only the placeholder's first character can ever fall under the caret, so
    // that character is all the painter is given. Resolved here so the first
    // keystroke — which takes the hint off screen — reaches [shouldRepaint] as
    // an ordinary field change.
    final hintGlyph = vimHintCaretGlyph(
      text: widget.controller.text,
      hintText: widget.hintText,
    );

    final painter = _VimOverlayPainter(
      text: widget.controller.text,
      hintGlyph: hintGlyph,
      style: widget.style,
      strutStyle: widget.strutStyle,
      textAlign: widget.textAlign,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
      caretOffset: mode == VimMode.insert ? null : session?.caretOffset,
      selection: mode.isVisual ? widget.controller.selection : null,
      searchOffsets: session?.searchHighlightOffsets ?? const [],
      searchLength: session?.searchHighlightLength ?? 0,
      tabstops: marks,
      accentColor: widget.accentColor,
      // Deliberately not the accent: the point of the search marks is to be
      // told apart from the caret and the selection at a glance, and every
      // other piece of Vim chrome in this field is already accent-coloured.
      searchColor: const Color(0xFFF2B705),
    );

    final scrollController = widget.scrollController;
    if (scrollController == null) {
      return ClipRect(child: CustomPaint(painter: painter));
    }
    return ClipRect(
      child: ListenableBuilder(
        listenable: scrollController,
        builder: (context, _) {
          final offset = scrollController.hasClients
              ? scrollController.offset
              : 0.0;
          return Transform.translate(
            offset: Offset(0, -offset),
            child: CustomPaint(painter: painter),
          );
        },
      ),
    );
  }
}

class _VimOverlayPainter extends CustomPainter {
  _VimOverlayPainter({
    required this.text,
    required this.hintGlyph,
    required this.style,
    required this.strutStyle,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.caretOffset,
    required this.selection,
    required this.searchOffsets,
    required this.searchLength,
    required this.tabstops,
    required this.accentColor,
    required this.searchColor,
  });

  final String text;

  /// First character of the field's placeholder while [text] is empty and so
  /// the placeholder is showing; null otherwise. See [VimTextOverlay.hintText].
  final String? hintGlyph;

  final TextStyle style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior? textHeightBehavior;

  /// Null in Insert mode, where the field draws its own thin caret.
  final int? caretOffset;

  /// The Visual-mode selection, or null outside Visual mode.
  final TextSelection? selection;

  final List<int> searchOffsets;
  final int searchLength;

  /// Snippet tabstops still to visit. Empty whenever no expansion is open.
  final SnippetMarks tabstops;

  final Color accentColor;
  final Color searchColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      strutStyle: strutStyle,
      textHeightBehavior: textHeightBehavior,
    )..layout(maxWidth: size.width);

    if (searchLength > 0) {
      final paint = Paint()..color = searchColor.withValues(alpha: 0.35);
      for (final offset in searchOffsets) {
        _fillRange(canvas, painter, offset, offset + searchLength, paint);
      }
    }

    final sel = selection;
    if (sel != null && sel.isValid && !sel.isCollapsed) {
      final paint = Paint()..color = accentColor.withValues(alpha: 0.30);
      _fillRange(canvas, painter, sel.start, sel.end, paint);
    }

    if (!tabstops.isEmpty) _paintTabstops(canvas, painter);

    final caret = caretOffset;
    if (caret != null) _paintCaret(canvas, painter, caret);

    painter.dispose();
  }

  /// A faint dotted stub at every tabstop the user has still to visit.
  ///
  /// Dotted rather than solid so it never reads as a second caret: the real one
  /// is a continuous bar (Insert) or a filled block (Normal), and the whole
  /// point of these marks is that they are places the caret *will* go, not
  /// places it is. Drawn under the caret so a mark at the current position
  /// never sits on top of it.
  ///
  /// The next stop is drawn at full strength and the rest are halved, which is
  /// enough to read the order at a glance without turning the field into a
  /// column of dashes.
  void _paintTabstops(Canvas canvas, TextPainter painter) {
    final paint = Paint()
      ..color = accentColor.withValues(alpha: _kTabstopAlpha)
      ..strokeWidth = _kTabstopWidth
      ..strokeCap = StrokeCap.round;
    final laterPaint = Paint()
      ..color = accentColor.withValues(alpha: _kTabstopAlpha * 0.45)
      ..strokeWidth = _kTabstopWidth
      ..strokeCap = StrokeCap.round;

    for (final offset in tabstops.offsets) {
      if (offset < 0 || offset > text.length) continue;
      final position = TextPosition(offset: offset);
      final origin = painter.getOffsetForCaret(position, Rect.zero);
      final height = painter.getFullHeightForCaret(position, Rect.zero);
      if (height <= 0) continue;
      final active = offset == tabstops.nextOffset;
      // Inset top and bottom so the dashes sit inside the line box rather than
      // touching the line above and below.
      final top = origin.dy + height * _kTabstopInset;
      final bottom = origin.dy + height * (1 - _kTabstopInset);
      final x = origin.dx + _kTabstopWidth / 2;
      for (var y = top; y < bottom; y += _kTabstopDash + _kTabstopGap) {
        final end = math.min(y + _kTabstopDash, bottom);
        canvas.drawLine(
          Offset(x, y),
          Offset(x, end),
          active ? paint : laterPaint,
        );
      }
    }
  }

  /// Width of the mark standing in for a covered empty line, in fractions of
  /// that line's height — see [_fillRange].
  static const double _emptyLineSliverRatio = 0.25;

  /// Fills `[start, end)` line by line, skipping the newline that ends each
  /// one — see the class doc for why the whole range can't just be handed to
  /// [TextPainter.getBoxesForSelection] in one go.
  void _fillRange(
    Canvas canvas,
    TextPainter painter,
    int start,
    int end,
    Paint paint,
  ) {
    var lo = start.clamp(0, text.length);
    final hi = end.clamp(0, text.length);
    while (lo < hi) {
      final lineEnd = math.min(hi, vimLineEnd(text, lo));
      if (lineEnd > lo) {
        for (final box in painter.getBoxesForSelection(
          TextSelection(baseOffset: lo, extentOffset: lineEnd),
        )) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(box.toRect(), const Radius.circular(2)),
            paint,
          );
        }
      } else {
        // An empty line: `lo` is a newline that the range covers, so the line
        // has no glyphs to ask for boxes for and skipping it would leave a
        // hole in the middle of the highlight. Mark it with a mark about a
        // space wide, matching what the OS selection does and what
        // `SelectionHighlightLayer` draws outside Visual mode.
        _paintEmptyLine(canvas, painter, lo, paint);
      }
      // Past the newline (or, on the last line, past `hi` — the loop ends).
      lo = lineEnd + 1;
    }
  }

  void _paintEmptyLine(
    Canvas canvas,
    TextPainter painter,
    int offset,
    Paint paint,
  ) {
    final position = TextPosition(offset: offset);
    final origin = painter.getOffsetForCaret(position, Rect.zero);
    final height = painter.getFullHeightForCaret(position, Rect.zero);
    final width = height * _emptyLineSliverRatio;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          textDirection == TextDirection.rtl ? origin.dx - width : origin.dx,
          origin.dy,
          width,
          height,
        ),
        const Radius.circular(2),
      ),
      paint,
    );
  }

  /// Delegates to [vimBlockCaretForeground].
  static Color _caretForegroundFor(Color caretColor) =>
      vimBlockCaretForeground(caretColor);

  /// A block exactly as wide as the glyph it sits on, and as tall as the line
  /// (same cell a terminal Vim caret occupies). Tight glyph boxes alone used
  /// to size the fill — with a 2px corner radius that clipped the ink and made
  /// the character under the caret look like it had jumped up a hair.
  /// Positions the document has no glyph for fall to [_paintEmptyCaretBlock].
  void _paintCaret(Canvas canvas, TextPainter painter, int offset) {
    final clamped = offset.clamp(0, text.length);
    final blockPaint = Paint()..color = accentColor;
    final lineEnd = vimLineEnd(text, clamped);

    if (clamped < lineEnd) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: clamped, extentOffset: clamped + 1),
      );
      if (boxes.isNotEmpty) {
        final glyphRect = boxes.first.toRect();
        final position = TextPosition(offset: clamped);
        final caretTop = painter.getOffsetForCaret(position, Rect.zero).dy;
        final height = painter.getFullHeightForCaret(position, Rect.zero);
        final blockRect = Rect.fromLTWH(
          glyphRect.left,
          caretTop,
          glyphRect.width,
          height,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(blockRect, const Radius.circular(2)),
          blockPaint,
        );
        // Align ink to [glyphRect]; clip to the full-height cell so corners
        // of the block never shave the letter — see [vimCaretGlyphPaintOrigin].
        _paintCaretGlyph(
          canvas,
          text[clamped],
          glyphRect,
          clipRect: blockRect,
        );
        return;
      }
    }

    _paintEmptyCaretBlock(canvas, painter, clamped, blockPaint);
  }

  /// Block caret where the document has no glyph — empty lines, empty
  /// documents, and any other position [getBoxesForSelection] cannot measure.
  ///
  /// On an empty field the placeholder is still on screen, so the block is
  /// sized to *its* first character rather than to a space, and that character
  /// is repainted on top like any glyph the caret sits on — the field paints the
  /// hint below this layer, where the opaque block would otherwise swallow it.
  void _paintEmptyCaretBlock(
    Canvas canvas,
    TextPainter painter,
    int offset,
    Paint paint,
  ) {
    final position = TextPosition(offset: offset);
    final origin = painter.getOffsetForCaret(position, Rect.zero);
    final height = painter.getFullHeightForCaret(position, Rect.zero);
    final glyph = hintGlyph;
    final width = _advanceWidth(glyph ?? ' ');
    final rect = Rect.fromLTWH(
      textDirection == TextDirection.rtl ? origin.dx - width : origin.dx,
      origin.dy,
      width,
      height,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2)),
      paint,
    );
    if (glyph != null) {
      // [rect] is a full-height caret here, not a tight glyph box — keep the
      // caret-origin paint so the hint letter is not pinned to the line top.
      _paintCaretGlyph(
        canvas,
        glyph,
        rect,
        origin: Offset(rect.left, origin.dy),
      );
    }
  }

  /// Advance width of [glyph] in [style] — used to size a block where the
  /// document has nothing to measure, from a space to a placeholder's first
  /// letter.
  double _advanceWidth(String glyph) {
    final probe = TextPainter(
      text: TextSpan(text: glyph, style: style),
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      strutStyle: strutStyle,
      textHeightBehavior: textHeightBehavior,
    )..layout();
    final width = probe.width;
    probe.dispose();
    return width;
  }

  /// Repaints the character under the caret on top of the opaque block.
  ///
  /// When [origin] is null, the probe glyph's ink is aligned to [blockRect]
  /// (the paragraph's own box for that character) — see
  /// [vimCaretGlyphPaintOrigin]. Pass an explicit [origin] only when
  /// [blockRect] is a full-height empty caret rather than a tight glyph box
  /// (the empty-field hint path).
  ///
  /// [clipRect] defaults to [blockRect]. Callers that size the fill to a
  /// full-height cell while aligning ink to a tight glyph box pass the cell
  /// here so the rounded corners never clip the letter.
  void _paintCaretGlyph(
    Canvas canvas,
    String glyph,
    Rect blockRect, {
    Offset? origin,
    Rect? clipRect,
  }) {
    final charPainter = TextPainter(
      text: TextSpan(
        text: glyph,
        style: style.copyWith(color: _caretForegroundFor(accentColor)),
      ),
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      strutStyle: strutStyle,
      textHeightBehavior: textHeightBehavior,
    )..layout();

    final paintOrigin =
        origin ??
        vimCaretGlyphPaintOrigin(
          probe: charPainter,
          glyphLength: glyph.length,
          blockRect: blockRect,
        );

    final clip = clipRect ?? blockRect;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(clip, const Radius.circular(2)),
    );
    charPainter.paint(canvas, paintOrigin);
    canvas.restore();
    charPainter.dispose();
  }

  @override
  bool shouldRepaint(covariant _VimOverlayPainter old) {
    return old.text != text ||
        old.hintGlyph != hintGlyph ||
        old.style != style ||
        old.caretOffset != caretOffset ||
        old.selection != selection ||
        old.searchLength != searchLength ||
        old.tabstops != tabstops ||
        old.accentColor != accentColor ||
        !_sameOffsets(old.searchOffsets, searchOffsets);
  }

  static bool _sameOffsets(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Geometry of a dotted tabstop mark — see [_VimOverlayPainter._paintTabstops].
/// A 1.5px stroke with 2px dashes on 2px gaps reads as dotted at every text
/// size the app uses without turning into a solid line on the dense fields.
const double _kTabstopWidth = 1.5;
const double _kTabstopDash = 2.0;
const double _kTabstopGap = 2.0;
const double _kTabstopAlpha = 0.75;

/// Fraction of the line height left clear above and below each mark.
const double _kTabstopInset = 0.12;

/// Material 3 default [InputDecoration.contentPadding] for an outlined field
/// when the decoration leaves it null. Must stay in lockstep with
/// `InputDecorator` (`input_decorator.dart`).
const kM3OutlinedContentPadding = EdgeInsets.fromLTRB(12, 20, 12, 12);

/// Same as [kM3OutlinedContentPadding] for [InputDecoration.isDense] fields.
const kM3OutlinedDenseContentPadding = EdgeInsets.fromLTRB(12, 16, 12, 8);

/// Padding that lines a [VimTextOverlay] up with the glyphs in a [TextField].
///
/// Mirrors InputDecorator: density shift, optional outline `inputGap`, and
/// RenderEditable's caret strip. [contentPadding] is the decoration's own
/// value (explicit, or the Material 3 default for that border) *before* the
/// gap.
///
/// [outlineCenter] is for an outlined field that keeps Material's default
/// [TextAlignVertical.center]. InputDecorator then places the input in the
/// vertical *center* of the container and ignores uneven content padding —
/// M3's dense outlined default is 16 top / 8 bottom, which would otherwise
/// leave this overlay 4px below the glyphs. Top-aligned fields (multiline,
/// `expands`) must leave this false.
EdgeInsets vimOverlayPadding({
  required EdgeInsets contentPadding,
  required VisualDensity density,
  double cursorWidth = 2.0,
  bool outlineGap = false,
  bool outlineCenter = false,
}) {
  var padded = outlineGap ? withInputGap(contentPadding) : contentPadding;
  padded = withDensityShift(padded, density);
  if (outlineCenter) {
    final vertical = (padded.top + padded.bottom) / 2.0;
    padded = padded.copyWith(top: vertical, bottom: vertical);
  }
  return withCaretMargin(padded, cursorWidth: cursorWidth);
}

/// Keeps a [TextSelectionTheme] mounted across Vim mode changes.
///
/// Inserting or removing this inherited widget above a field recreates
/// [EditableTextState], which drops the platform text-input connection
/// without a focus change — the box looks focused but swallows keystrokes.
/// The same failure is why [VimTextScope] keys its field across the mode
/// badge mounting. Toggle only [hideNativeSelection], never whether this
/// wrapper is in the tree.
Widget vimSelectionTheme({
  required BuildContext context,
  required bool hideNativeSelection,
  required Widget child,
}) {
  return TextSelectionTheme(
    data: TextSelectionThemeData(
      selectionColor: hideNativeSelection
          ? Colors.transparent
          : TextSelectionTheme.of(context).selectionColor,
    ),
    child: child,
  );
}

/// Stacks [VimTextOverlay] over a raw [TextField] the same way
/// `VoyagerTextField` does, without changing the field's own chrome.
///
/// [underlay] is painted behind the field with the same [overlayPadding]
/// (spellcheck squiggles, for example). Flutter's Visual-mode selection is
/// blanked while the overlay is drawing it, so the two never stack.
class VimOverlayHost extends StatelessWidget {
  const VimOverlayHost({
    super.key,
    required this.session,
    required this.overlayPaintsSelection,
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.accentColor,
    required this.overlayPadding,
    required this.child,
    this.snippetSession,
    this.scrollController,
    this.hintText,
    this.strutStyle,
    this.underlay,
    this.fit = StackFit.passthrough,
  });

  final VimSession? session;

  /// The field's snippet runtime, when it has one. Mounting the overlay for
  /// this alone is what puts dotted tabstop marks on a field with Vim off.
  final SnippetSession? snippetSession;
  final bool overlayPaintsSelection;
  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final Color accentColor;
  final EdgeInsets overlayPadding;
  final Widget child;
  final ScrollController? scrollController;
  final String? hintText;
  final StrutStyle? strutStyle;
  final Widget? underlay;
  final StackFit fit;

  @override
  Widget build(BuildContext context) {
    final overlayNeeded = session != null || snippetSession != null;
    if (!overlayNeeded && underlay == null) return child;

    Widget field = Stack(
      fit: fit,
      children: [
        if (underlay != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(padding: overlayPadding, child: underlay),
            ),
          ),
        child,
        if (overlayNeeded)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: overlayPadding,
                child: VimTextOverlay(
                  session: session,
                  snippetSession: snippetSession,
                  controller: controller,
                  focusNode: focusNode,
                  style: style,
                  // EditableText falls back to forceStrutHeight when the
                  // field is not given a strut — match it or the inverted
                  // glyph on the block sits a couple of pixels off the
                  // real one (editable_text.dart, `strutStyle` getter).
                  strutStyle:
                      strutStyle ??
                      StrutStyle.fromTextStyle(style, forceStrutHeight: true),
                  accentColor: accentColor,
                  scrollController: scrollController,
                  hintText: hintText,
                ),
              ),
            ),
          ),
      ],
    );
    // Always wrap while a session is live, not only in Visual: mounting this
    // inherited widget on `V` and unmounting it on Esc rebuilt the field and
    // killed typing on the following `i`.
    if (session != null) {
      field = vimSelectionTheme(
        context: context,
        hideNativeSelection: overlayPaintsSelection,
        child: field,
      );
    }
    return field;
  }
}
