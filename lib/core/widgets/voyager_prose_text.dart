import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/text/styled_runs.dart';
import 'package:voyager/core/widgets/prose_highlight_underlay.dart';

/// Stored prose, shown the way the editor shows it: bold, italic, underline
/// and highlight applied, and every delimiter collapsed to nothing
/// (EMPHASIS_FORMATTING.md §5.3).
///
/// A drop-in for the plain [Text] a read surface used to show body text with.
/// It is deliberately *not* what the richer surfaces use — search results,
/// study cards and LeetCode prose each slice their text up for tag pills,
/// `$…$` math or `` `code` `` chips, and layer [proseReadRanges] onto those
/// slices themselves so a pair straddling a boundary still applies.
class VoyagerProseText extends StatelessWidget {
  const VoyagerProseText(
    this.text, {
    super.key,
    this.style,
    this.accentColor,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;

  /// Null inherits the ambient [DefaultTextStyle], exactly as [Text] does.
  final TextStyle? style;

  /// What `==highlight==` fills with. Falls back to the scheme's primary.
  final Color? accentColor;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final emphasis = ProseEmphasisTheme.of(
      scheme,
      accentColor ?? scheme.primary,
    );
    final ranges = proseReadRanges(text, emphasis);
    if (ranges.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    // `==highlight==` comes back marked, not filled: only the underlay can
    // round its corners — see [kProseHighlightMark].
    return ProseHighlightUnderlay(
      color: emphasis.highlightColor!,
      child: Text.rich(
        buildStyledRuns(
          text,
          style ?? DefaultTextStyle.of(context).style,
          ranges,
        ),
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      ),
    );
  }
}
