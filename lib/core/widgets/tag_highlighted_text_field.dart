import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/utils/journal_tags.dart';

class TagHighlightedTextField extends StatefulWidget {
  const TagHighlightedTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onChanged,
    this.hintText,
    this.style,
    this.contentPadding = const EdgeInsets.all(16),
    this.expands = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.tagColorFor,
    this.decoration = const InputDecoration(),
    this.highlightDebounce = const Duration(milliseconds: 200),
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged;
  final String? hintText;
  final TextStyle? style;
  final EdgeInsetsGeometry contentPadding;
  final bool expands;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final int Function(String tag)? tagColorFor;
  final InputDecoration decoration;
  final Duration highlightDebounce;

  @override
  State<TagHighlightedTextField> createState() =>
      _TagHighlightedTextFieldState();
}

class _TagHighlightedTextFieldState extends State<TagHighlightedTextField> {
  static const _textHeightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: false,
    applyHeightToLastDescent: false,
  );

  late final ScrollController _scrollController;
  Timer? _highlightTimer;
  String _highlightedText = '';

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _highlightedText = widget.controller.text;
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant TagHighlightedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
    if (widget.controller.text != _highlightedText) {
      _highlightedText = widget.controller.text;
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    widget.controller.removeListener(_handleControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    _scheduleHighlightRepaint();
  }

  void _scheduleHighlightRepaint() {
    if (widget.highlightDebounce == Duration.zero) {
      _highlightTimer?.cancel();
      _applyHighlightText(widget.controller.text);
      return;
    }

    _highlightTimer?.cancel();
    _highlightTimer = Timer(widget.highlightDebounce, () {
      if (!mounted) return;
      _applyHighlightText(widget.controller.text);
    });
  }

  void _applyHighlightText(String text) {
    if (_highlightedText == text) return;
    setState(() => _highlightedText = text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle =
        widget.style ??
        theme.textTheme.bodyLarge ??
        DefaultTextStyle.of(context).style;
    final strutStyle = StrutStyle.fromTextStyle(baseStyle);
    final decoration = widget.decoration.copyWith(
      hintText: widget.hintText,
      contentPadding: widget.contentPadding,
    );
    final padding = widget.contentPadding.resolve(Directionality.of(context));
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final textHeightBehavior =
        DefaultTextHeightBehavior.maybeOf(context) ?? _textHeightBehavior;
    final locale = Localizations.maybeLocaleOf(context);

    return Stack(
      fit: widget.expands ? StackFit.expand : StackFit.loose,
      textDirection: textDirection,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DefaultTextHeightBehavior(
              textHeightBehavior: textHeightBehavior,
              child: ClipRect(
                child: ListenableBuilder(
                  listenable: _scrollController,
                  builder: (context, _) {
                    final scrollOffset = _scrollController.hasClients
                        ? _scrollController.offset
                        : 0.0;
                    return Transform.translate(
                      offset: Offset(0, -scrollOffset),
                      child: Padding(
                        padding: padding,
                        child: _TagHighlightLayer(
                          text: _highlightedText,
                          style: baseStyle,
                          strutStyle: strutStyle,
                          textDirection: textDirection,
                          textScaler: textScaler,
                          textHeightBehavior: textHeightBehavior,
                          locale: locale,
                          tagColorFor: widget.tagColorFor ?? colorForTag,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        DefaultTextHeightBehavior(
          textHeightBehavior: textHeightBehavior,
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            scrollController: _scrollController,
            expands: widget.expands,
            maxLines: widget.expands ? null : widget.maxLines,
            minLines: widget.expands ? null : widget.minLines,
            keyboardType: widget.keyboardType,
            textAlignVertical: TextAlignVertical.top,
            strutStyle: strutStyle,
            style: baseStyle,
            cursorColor: theme.colorScheme.primary,
            onChanged: widget.onChanged,
            decoration: decoration,
          ),
        ),
      ],
    );
  }
}

class _TagHighlightLayer extends StatelessWidget {
  const _TagHighlightLayer({
    required this.text,
    required this.style,
    required this.strutStyle,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.locale,
    required this.tagColorFor,
  });

  final String text;
  final TextStyle style;
  final StrutStyle strutStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior textHeightBehavior;
  final Locale? locale;
  final int Function(String tag) tagColorFor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: textDirection,
          textScaler: textScaler,
          strutStyle: strutStyle,
          textHeightBehavior: textHeightBehavior,
          locale: locale,
          maxLines: null,
        )..layout(maxWidth: constraints.maxWidth);

        return CustomPaint(
          size: Size(constraints.maxWidth, textPainter.height),
          painter: _TagHighlightPainter(
            textPainter: textPainter,
            fontSize: style.fontSize ?? textPainter.preferredLineHeight,
            tagColorFor: tagColorFor,
          ),
        );
      },
    );
  }
}

class _TagHighlightPainter extends CustomPainter {
  _TagHighlightPainter({
    required this.textPainter,
    required this.fontSize,
    required this.tagColorFor,
  });

  final TextPainter textPainter;
  final double fontSize;
  final int Function(String tag) tagColorFor;

  static const _tagHorizontalPadding = 3.0;
  static const _tagVerticalPadding = 2.0;
  static const _tagCornerRadius = 8.0;
  static final _tagDescenderPattern = RegExp(r'[gjpqy]');

  Rect _tagHighlightRect(TextBox box, String tagName) {
    final hasDescender = _tagDescenderPattern.hasMatch(tagName);
    // Selection boxes include the full line descent; visible glyphs are shorter.
    final textBodyHeight = fontSize * (hasDescender ? 0.86 : 0.72);
    final pillHeight = textBodyHeight + _tagVerticalPadding * 2;

    final boxHeight = box.bottom - box.top;
    final slack = boxHeight - textBodyHeight;
    // Keep the trimmed bottom, extend upward so text sits centered in the pill.
    final topExtension = fontSize * 0.08 + 1.0;
    final bottom = box.top + slack * 0.08 + textBodyHeight + _tagVerticalPadding;
    final top = bottom - pillHeight - topExtension;

    return Rect.fromLTRB(
      box.left - _tagHorizontalPadding,
      top,
      box.right + _tagHorizontalPadding,
      bottom,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final text = textPainter.text?.toPlainText() ?? '';
    if (text.isEmpty) return;

    for (final match in journalTagPattern.allMatches(text)) {
      final tagName = match.group(1)!;
      final tagColor = Color(tagColorFor(tagName));
      final backgroundPaint = Paint()
        ..color = tagColor.withValues(alpha: 0.3);

      final boxes = textPainter.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      for (final box in boxes) {
        final rect = _tagHighlightRect(box, tagName);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect,
            const Radius.circular(_tagCornerRadius),
          ),
          backgroundPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TagHighlightPainter oldDelegate) {
    return oldDelegate.textPainter.text != textPainter.text ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.textPainter.preferredLineHeight !=
            textPainter.preferredLineHeight ||
        oldDelegate.tagColorFor != tagColorFor;
  }
}
