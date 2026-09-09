import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/core/spellcheck/autocorrect_engine.dart';
import 'package:voyager/core/spellcheck/autocorrect_session.dart';
import 'package:voyager/core/text/prose_text_span.dart';

/// The brief tint behind a word autocorrect has just replaced
/// (AUTOCORRECT.md §9).
///
/// It exists because the correction is the one thing this feature does that
/// the user did not ask for on that keystroke. A word that changes silently
/// under a fast typist is a word they find later and cannot account for; a
/// mark that fades before the next sentence is written says *this one moved*
/// without ever being something to dismiss. There is no toast and no button —
/// Backspace already reverts it (§7.2).
///
/// Positioned by its caller exactly like [SpellCheckSquiggleLayer] and
/// [SelectionHighlightLayer] — same style, strut and padding as the field,
/// `Positioned.fill` under an `IgnorePointer` — so the [TextPainter] here
/// wraps the text identically and the boxes land on the real glyphs. It
/// belongs *beneath* the field, where the fill sits behind the letters rather
/// than washing them out.
class AutocorrectFlashLayer extends StatefulWidget {
  const AutocorrectFlashLayer({
    super.key,
    required this.session,
    required this.controller,
    required this.style,
    this.color,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.textHeightBehavior,
    this.scrollController,
    this.spanBuilder,
  });

  final AutocorrectSession session;
  final TextEditingController controller;
  final TextStyle style;

  /// The fill, at full strength — the fade multiplies its opacity. Defaults to
  /// the theme's primary.
  final Color? color;

  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextHeightBehavior? textHeightBehavior;
  final ScrollController? scrollController;

  /// Builds the paragraph this layer measures against. Null means the flat
  /// one — the text in [style] and nothing else. A field with emphasis passes
  /// [ProseEditingController.overlaySpan], because bold is wider than regular
  /// and a hidden `**` is not there at all: laid out flat, the boxes behind
  /// the corrected word would land on the wrong glyphs.
  final ProseSpanBuilder? spanBuilder;

  /// How long the mark takes to go, from full to nothing.
  ///
  /// At the top of the 300–500ms the spec allows: the mark is already faint,
  /// and a fade that finishes at 300 is easy to miss entirely at the moment
  /// the eye is on the next word being typed.
  static const Duration fadeDuration = Duration(milliseconds: 450);

  /// Peak opacity of the fill. Low enough to read as the paper changing colour
  /// rather than as a selection — a selection is something you can act on, and
  /// this is not.
  static const double peakOpacity = 0.22;

  @override
  State<AutocorrectFlashLayer> createState() => _AutocorrectFlashLayerState();
}

class _AutocorrectFlashLayerState extends State<AutocorrectFlashLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AutocorrectFlashLayer.fadeDuration,
  );

  /// The span being flashed, in the field's *current* offsets. Kept in step
  /// with the text as the user types on, rather than pinned to where the word
  /// was when it was corrected: the whole point is that typing continues.
  TextRange? _range;

  /// The text those offsets belong to, for diffing the next change against.
  String _text = '';

  @override
  void initState() {
    super.initState();
    _text = widget.controller.text;
    widget.session.flashListenable.addListener(_handleFlash);
    widget.controller.addListener(_handleTextChanged);
    // Nothing left to track once the mark is gone: the range would otherwise
    // go on being re-anchored across every edit for the life of the field.
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.completed) _clear();
    });
  }

  @override
  void didUpdateWidget(covariant AutocorrectFlashLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.flashListenable.removeListener(_handleFlash);
      widget.session.flashListenable.addListener(_handleFlash);
      _clear();
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChanged);
      widget.controller.addListener(_handleTextChanged);
      _text = widget.controller.text;
      _clear();
    }
  }

  @override
  void dispose() {
    widget.session.flashListenable.removeListener(_handleFlash);
    widget.controller.removeListener(_handleTextChanged);
    _fade.dispose();
    super.dispose();
  }

  void _handleFlash() {
    final flash = widget.session.flashListenable.value;
    if (flash == null) {
      _clear();
      return;
    }
    setState(() {
      _range = flash.range;
      _text = widget.controller.text;
    });
    _fade.forward(from: 0);
  }

  void _handleTextChanged() {
    final text = widget.controller.text;
    if (text == _text) return;
    final range = _range;
    if (range == null) {
      _text = text;
      return;
    }
    final moved = mapRangeAcrossEdit(
      range,
      autocorrectEditSpan(_text, text, widget.controller.selection),
    );
    _text = text;
    // An edit that reached into the corrected word leaves nothing to point at.
    if (moved == null) {
      _clear();
      return;
    }
    if (moved != range) setState(() => _range = moved);
  }

  void _clear() {
    _fade.stop();
    if (_range == null) return;
    setState(() => _range = null);
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    if (range == null) return const SizedBox.shrink();

    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final heightBehavior =
        widget.textHeightBehavior ?? DefaultTextHeightBehavior.maybeOf(context);

    // Deliberately not an [AnimatedBuilder]. Rebuilding the [CustomPaint] once
    // a tick handed the painter a new colour every frame, so `shouldRepaint`
    // was always true and `paint` laid a [TextPainter] out over the *whole*
    // field text ~27 times per fade — a full paragraph layout of a journal
    // entry per frame, on the keystroke after a correction, while the user is
    // still typing. Nothing the animation touches can move those boxes: the
    // text, the range, the style and the width are fixed for the life of one
    // flash, and only the alpha changes. So the painter takes the animation as
    // its `repaint` and caches the geometry, and each frame is one `drawPath`.
    Widget painted = CustomPaint(
      painter: _AutocorrectFlashPainter(
        text: _text,
        span: (widget.spanBuilder ?? flatProseSpan)(_text, widget.style),
        range: range,
        style: widget.style,
        strutStyle: widget.strutStyle,
        textAlign: widget.textAlign,
        textDirection: textDirection,
        textScaler: textScaler,
        textHeightBehavior: heightBehavior,
        color: color,
        fade: _fade,
      ),
    );

    final scrollController = widget.scrollController;
    if (scrollController != null) {
      painted = ListenableBuilder(
        listenable: scrollController,
        builder: (context, child) {
          final offset = scrollController.hasClients
              ? scrollController.offset
              : 0.0;
          return Transform.translate(offset: Offset(0, -offset), child: child);
        },
        child: painted,
      );
    }
    return ClipRect(child: painted);
  }
}

class _AutocorrectFlashPainter extends CustomPainter {
  _AutocorrectFlashPainter({
    required this.text,
    required this.span,
    required this.range,
    required this.style,
    required this.strutStyle,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.color,
    required this.fade,
  }) : super(repaint: fade);

  final String text;

  /// [text] as the field itself renders it — same weights, same slants, same
  /// collapsed delimiters — so the boxes below land on the real glyphs.
  final TextSpan span;

  final TextRange range;
  final TextStyle style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior? textHeightBehavior;

  /// The fill at full strength; [fade] multiplies its opacity.
  final Color color;

  /// 0 at the moment of the correction, 1 when the mark has gone.
  final Animation<double> fade;

  /// The boxes behind the corrected word, laid out once. Keyed on the size
  /// because the field can be resized under a live fade; every other input is
  /// fixed for the life of this painter, which is replaced (not repainted)
  /// when one of them changes.
  Path? _cachedPath;
  Size? _cachedSize;

  /// How far the fill is grown past the glyphs, in logical pixels. Without it
  /// the tint stops exactly at the first and last stems and reads as a
  /// highlighter that missed.
  static const double _bleed = 1.5;

  /// Corner radius. Small enough to still read as a band behind a word rather
  /// than as a chip around it.
  static const double _radius = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final opacity = (1.0 - fade.value) * AutocorrectFlashLayer.peakOpacity;
    if (opacity <= 0 || size.isEmpty) return;
    final path = _pathFor(size);
    if (path == null) return;
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: opacity));
  }

  Path? _pathFor(Size size) {
    if (_cachedSize == size) return _cachedPath;
    _cachedSize = size;
    return _cachedPath = _buildPath(size);
  }

  Path? _buildPath(Size size) {
    final start = range.start.clamp(0, text.length);
    final end = range.end.clamp(start, text.length);
    if (start >= end) return null;

    final painter = TextPainter(
      text: span,
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      strutStyle: strutStyle,
      textHeightBehavior: textHeightBehavior,
    )..layout(maxWidth: size.width);

    // A word normally reports one box; a word long enough to wrap reports one
    // per line, and they are filled as a single path so the overlap between
    // two boxes on the same line is never blended twice.
    final path = Path();
    for (final box in painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      boxHeightStyle: ui.BoxHeightStyle.tight,
      boxWidthStyle: ui.BoxWidthStyle.tight,
    )) {
      final rect = box.toRect();
      if (rect.isEmpty) continue;
      path.addRRect(
        RRect.fromRectAndRadius(
          rect.inflate(_bleed),
          const Radius.circular(_radius),
        ),
      );
    }
    painter.dispose();
    return path;
  }

  @override
  bool shouldRepaint(covariant _AutocorrectFlashPainter old) {
    return old.text != text ||
        old.span != span ||
        old.range != range ||
        old.style != style ||
        old.strutStyle != strutStyle ||
        old.textAlign != textAlign ||
        old.textDirection != textDirection ||
        old.textScaler != textScaler ||
        old.textHeightBehavior != textHeightBehavior ||
        old.color != color;
    // Not `fade`: the animation repaints this painter itself, through
    // `super.repaint`.
  }
}
