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

  @override
  State<TagHighlightedTextField> createState() =>
      _TagHighlightedTextFieldState();
}

class _TagHighlightedTextFieldState extends State<TagHighlightedTextField> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant TagHighlightedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle =
        widget.style ??
        theme.textTheme.bodyLarge ??
        DefaultTextStyle.of(context).style;
    final strutStyle = StrutStyle.fromTextStyle(
      baseStyle,
      forceStrutHeight: true,
    );
    final fieldStyle = baseStyle.copyWith(color: Colors.transparent);
    final decoration = widget.decoration.copyWith(
      hintText: widget.hintText,
      contentPadding: widget.contentPadding,
    );
    final padding = widget.contentPadding.resolve(Directionality.of(context));
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final textHeightBehavior =
        DefaultTextHeightBehavior.maybeOf(context) ??
        const TextHeightBehavior();
    final locale = Localizations.maybeLocaleOf(context);
    final text = widget.controller.text;

    return Stack(
      fit: StackFit.expand,
      textDirection: textDirection,
      children: [
        Positioned.fill(
          child: IgnorePointer(
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
                        text: text,
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
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          scrollController: _scrollController,
          expands: widget.expands,
          maxLines: widget.expands ? null : widget.maxLines,
          minLines: widget.expands ? null : widget.minLines,
          keyboardType: widget.keyboardType,
          textAlignVertical: TextAlignVertical.top,
          strutStyle: strutStyle,
          style: fieldStyle,
          cursorColor: theme.colorScheme.primary,
          onChanged: widget.onChanged,
          decoration: decoration,
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
            text: text,
            textPainter: textPainter,
            tagColorFor: tagColorFor,
          ),
        );
      },
    );
  }
}

class _TagHighlightPainter extends CustomPainter {
  _TagHighlightPainter({
    required this.text,
    required this.textPainter,
    required this.tagColorFor,
  });

  final String text;
  final TextPainter textPainter;
  final int Function(String tag) tagColorFor;

  static const _tagHorizontalPadding = 2.0;
  static const _tagVerticalPadding = 1.0;
  static const _tagCornerRadius = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
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
        final bounds = box.toRect();
        final rect = Rect.fromLTRB(
          bounds.left - _tagHorizontalPadding,
          bounds.top - _tagVerticalPadding,
          bounds.right + _tagHorizontalPadding,
          bounds.bottom + _tagVerticalPadding,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect,
            const Radius.circular(_tagCornerRadius),
          ),
          backgroundPaint,
        );
      }
    }

    textPainter.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(covariant _TagHighlightPainter oldDelegate) {
    return oldDelegate.text != text ||
        oldDelegate.textPainter.text != textPainter.text ||
        oldDelegate.textPainter.preferredLineHeight !=
            textPainter.preferredLineHeight ||
        oldDelegate.tagColorFor != tagColorFor;
  }
}
