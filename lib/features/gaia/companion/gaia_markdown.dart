import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:highlight/highlight.dart' as hl;
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/core/theme/app_fonts.dart';

/// A message's text rendered as Markdown (§9.5): the one renderer for the
/// companion, the Gaia page and the phone. Selectable across its blocks,
/// with a copy button on each code block, its URLs and paths clickable and
/// its LaTeX typeset.
///
/// Cut into top-level blocks, each built once for its text, so a streaming
/// reply rebuilds only its last.
///
/// Its task-list checkboxes are circles, shown the other way from how
/// they're written for each task index in [checks] (counted through the
/// text); tapping one calls [onCheck] with its index.
class GaiaMarkdown extends StatefulWidget {
  const GaiaMarkdown({
    super.key,
    required this.text,
    this.contextMenuBuilder,
    this.checks = const {},
    this.onCheck,
  });

  final String text;
  final Set<int> checks;

  /// Null where the checkboxes can't be ticked.
  final ValueChanged<int>? onCheck;

  /// The selection's right-click menu; the platform's when null.
  final SelectableRegionContextMenuBuilder? contextMenuBuilder;

  @override
  State<GaiaMarkdown> createState() => _GaiaMarkdownState();
}

class _GaiaMarkdownState extends State<GaiaMarkdown> {
  /// The last build's blocks, by their text: the same widget again is one
  /// Flutter doesn't rebuild.
  var _built = <String, _Block>{};

  /// How many tasks each block has, by its text.
  var _tasks = <String, int>{};
  final _selection = _LineSelection();

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final built = <String, _Block>{};
    final tasks = <String, int>{};
    final sources = gaiaMarkdownBlocks(widget.text);
    var firstTask = 0;
    final blocks = <Widget>[];
    for (final (i, source) in sources.indexed) {
      // Only a later block needs the count: the last, as it streams, isn't
      // parsed twice.
      final count = i < sources.length - 1
          ? tasks[source] ??=
                _tasks[source] ?? _taskCount(_BlockState._parse(source))
          : null;
      final old = built[source] ?? _built[source];
      final block =
          old != null &&
              old.firstTask == firstTask &&
              old.tickable == (widget.onCheck != null) &&
              _sameChecks(old, widget.checks, count)
          ? old
          : _Block(
              source: source,
              firstTask: firstTask,
              checks: widget.checks,
              onCheck: widget.onCheck,
            );
      built[source] ??= block;
      blocks.add(block);
      if (count != null) firstTask += count;
    }
    _built = built;
    _tasks = tasks;
    return SelectionArea(
      contextMenuBuilder:
          widget.contextMenuBuilder ??
          (context, state) => AdaptiveTextSelectionToolbar.selectableRegion(
            selectableRegionState: state,
          ),
      child: SelectionContainer(
        delegate: _selection,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _spaced(blocks, _blockGap),
        ),
      ),
    );
  }
}

/// Whether [block] shows the same [checks] as it was built with, among the
/// [count] tasks it has; all after its first, for the last block's null.
bool _sameChecks(_Block block, Set<int> checks, int? count) {
  bool mine(int task) =>
      task >= block.firstTask &&
      (count == null || task < block.firstTask + count);
  return setEquals(
    block.checks.where(mine).toSet(),
    checks.where(mine).toSet(),
  );
}

/// The task-list checkboxes in [nodes].
int _taskCount(List<md.Node> nodes) {
  var count = 0;
  for (final node in nodes) {
    if (node is! md.Element) continue;
    if (node.tag == 'input') count++;
    count += _taskCount(node.children ?? const []);
  }
  return count;
}

/// Between blocks.
const _blockGap = 8.0;

/// Between a list's items.
const _itemGap = 4.0;

List<Widget> _spaced(List<Widget> children, double gap) => [
  for (var i = 0; i < children.length; i++) ...[
    if (i > 0) SizedBox(height: gap),
    children[i],
  ],
];

/// [text] cut into its top-level blocks: at a blank line before an
/// unindented line, outside a fence. A list's items stay together, so it
/// keeps its numbering, and an indented line stays with what it continues.
///
/// A text with a link or footnote definition isn't cut: what refers to one
/// can only find it in the same parse.
List<String> gaiaMarkdownBlocks(String text) {
  if (_definition.hasMatch(text)) return [text.trimRight()];
  final lines = text.split('\n');
  final blocks = <String>[];
  var start = 0;
  String? fence;
  var blank = false;
  var started = false;
  var list = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (fence != null) {
      if (_fenceClose(line, fence)) fence = null;
      continue;
    }
    if (line.trim().isEmpty) {
      blank = true;
      continue;
    }
    final item = _listItem.hasMatch(line);
    if (!started) {
      started = true;
      list = item;
    } else if (blank && !line.startsWith(RegExp('[ \t]')) && !(list && item)) {
      blocks.add(lines.sublist(start, i).join('\n').trimRight());
      start = i;
      list = item;
    }
    blank = false;
    fence = _fenceOpen.firstMatch(line)?.group(1);
  }
  final last = lines.sublist(start).join('\n').trimRight();
  if (last.isNotEmpty || blocks.isEmpty) blocks.add(last);
  return blocks;
}

final _definition = RegExp(r'^ {0,3}\[[^\]\n]+\]:', multiLine: true);
final _listItem = RegExp(r'^(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)');
final _fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})');

bool _fenceClose(String line, String fence) {
  final trimmed = line.trimLeft();
  return line.length - trimmed.length <= 3 &&
      trimmed.startsWith(fence) &&
      trimmed.replaceAll(fence[0], '').trim().isEmpty;
}

/// Joins what's selected in each of its texts with a line break, where
/// [SelectionArea] runs paragraphs together.
///
/// Its texts are in reading order as they're built, not as they're laid
/// out: the screen order it would otherwise sort by needs every text laid
/// out, which a reply streaming while kept alive out of view isn't.
class _LineSelection extends StaticSelectionContainerDelegate {
  @override
  Comparator<Selectable> get compareOrder => (a, b) {
    // Each text registers through a SelectionContainer of its own, whose
    // State is the selectable; anything else goes by the screen.
    if (a is! State || b is! State) return super.compareOrder(a, b);
    final pathA = _path((a as State).context as Element);
    final pathB = _path((b as State).context as Element);
    var i = 0;
    while (i < pathA.length && i < pathB.length && pathA[i] == pathB[i]) {
      i++;
    }
    if (i == pathA.length || i == pathB.length || i == 0) {
      return pathA.length.compareTo(pathB.length);
    }
    var order = 0;
    pathA[i - 1].visitChildren((child) {
      if (order != 0) return;
      if (child == pathA[i]) order = -1;
      if (child == pathB[i]) order = 1;
    });
    return order;
  };

  /// [element]'s ancestors down from this delegate's container, then it.
  List<Element> _path(Element element) {
    final path = [element];
    element.visitAncestorElements((ancestor) {
      path.add(ancestor);
      final widget = ancestor.widget;
      return widget is! SelectionContainer || widget.delegate != this;
    });
    return path.reversed.toList();
  }

  @override
  SelectedContent? getSelectedContent() {
    final parts = [
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final content?)
          content.plainText,
    ];
    // Without the line break a triple click takes with its line, which a
    // terminal would run the command on as it's pasted.
    return parts.isEmpty
        ? null
        : SelectedContent(
            plainText: parts.join('\n').replaceFirst(_trailingBreaks, ''),
          );
  }
}

final _trailingBreaks = RegExp(r'[\r\n]+$');

/// One top-level block, parsed once for its [source].
class _Block extends StatefulWidget {
  const _Block({
    required this.source,
    required this.firstTask,
    required this.checks,
    required this.onCheck,
  });

  final String source;

  /// The index, through the whole text, of this block's first task.
  final int firstTask;
  final Set<int> checks;
  final ValueChanged<int>? onCheck;

  bool get tickable => onCheck != null;

  @override
  State<_Block> createState() => _BlockState();
}

class _BlockState extends State<_Block> {
  late var _nodes = _parse(widget.source);

  /// The last block, as it streams, is the same block with more text.
  @override
  void didUpdateWidget(_Block old) {
    super.didUpdateWidget(old);
    if (widget.source != old.source) _nodes = _parse(widget.source);
  }

  static List<md.Node> _parse(String source) => md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: const [_DisplayMathSyntax()],
    inlineSyntaxes: [_MathSyntax()],
    encodeHtml: false,
  ).parse(source);

  /// A link's, by its target, kept for the block's life.
  final _taps = <String, TapGestureRecognizer>{};

  @override
  void dispose() {
    for (final tap in _taps.values) {
      tap.dispose();
    }
    super.dispose();
  }

  /// The next task's index through the whole text, as the build meets them
  /// in reading order.
  var _task = 0;

  @override
  Widget build(BuildContext context) {
    _task = widget.firstTask;
    final children = _blocks(
      context,
      _nodes,
      DefaultTextStyle.of(context).style,
    );
    return children.length == 1
        ? children.single
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _spaced(children, _blockGap),
          );
  }

  List<Widget> _blocks(
    BuildContext context,
    List<md.Node> nodes,
    TextStyle style, {
    int depth = 0,
  }) {
    final theme = Theme.of(context);
    final widgets = <Widget>[];
    // Inline nodes beside blocks, as in a tight list's item, make a
    // paragraph of their own.
    final inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      widgets.add(_paragraph(context, [...inline], style));
      inline.clear();
    }

    for (final node in nodes) {
      if (node is! md.Element || !_blockTags.contains(node.tag)) {
        inline.add(node);
        continue;
      }
      flush();
      if (_displayMathOnly(node) case final math?) {
        widgets.add(Center(child: _math(math, style, scrolls: true)));
        continue;
      }
      widgets.add(switch (node.tag) {
        'p' => _paragraph(context, node.children ?? const [], style),
        'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _paragraph(
            context,
            node.children ?? const [],
            style.copyWith(
              fontSize: (style.fontSize ?? 14) * _headingScale[node.tag]!,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        'ul' || 'ol' => _list(context, node, style, depth),
        'blockquote' => Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _spaced(
              _blocks(
                context,
                node.children ?? const [],
                style.copyWith(color: theme.colorScheme.onSurfaceVariant),
                depth: depth,
              ),
              _blockGap,
            ),
          ),
        ),
        'pre' => _codeBlock(node),
        'hr' => Divider(height: 1, color: theme.colorScheme.outlineVariant),
        'table' => _table(context, node, style),
        _ => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _spaced(
            _blocks(context, node.children ?? const [], style, depth: depth),
            _blockGap,
          ),
        ),
      });
    }
    flush();
    return widgets;
  }

  /// The math of a paragraph that's display math alone, set as a block.
  static md.Element? _displayMathOnly(md.Element node) {
    if (node.tag != 'p') return null;
    final children = [
      for (final child in node.children ?? const <md.Node>[])
        if (child is! md.Text || child.text.trim().isNotEmpty) child,
    ];
    return switch (children) {
      [final md.Element math]
          when math.tag == 'math' && math.attributes['display'] == 'true' =>
        math,
      _ => null,
    };
  }

  /// A [_MathSyntax] element typeset, copying as written; as written if it
  /// doesn't parse. Scrolling sideways inside what's selected, if [scrolls]:
  /// a selection the scrollable passes on loses the drag past it.
  static Widget _math(
    md.Element math,
    TextStyle style, {
    bool scrolls = false,
  }) {
    final source = math.attributes['source']!;
    final display = math.attributes['display'] == 'true';
    // Not bold in a table's header or bold text, as KaTeX resets the weight:
    // Math.tex swaps any weight for upright bold glyphs, laid out by the
    // regular ones' metrics, so they spilled out of its box and were cut.
    // Its source, should it not parse, keeps the weight as any text.
    final upright = style.copyWith(fontWeight: FontWeight.normal);
    final typeset = Math.tex(
      math.textContent,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: upright,
      onErrorFallback: (_) => Text(source, style: style),
    );
    final measured = _MeasuredMath(
      id: (math.textContent, display, style),
      child: typeset,
    );
    final shown = scrolls
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: measured,
          )
        : measured;
    return typeset.parseError == null
        ? _SelectableMath(source: source, child: shown)
        : shown;
  }

  /// Inline [math] cut after each comma outside any brackets that a space
  /// follows, each piece with the space after it: where a line too narrow
  /// for it wraps, as a list like `\{P\}, \{Q\}` would in prose. Whole if
  /// there's none, or a piece doesn't typeset alone. The pieces' sources
  /// and spaces are the whole source, so a selection copies it as written.
  static final _texWord = RegExp('[a-zA-Z]+');
  static final _space = RegExp(r'\s+');

  /// TeX's infix fractions and its switches, which reach to the end of the
  /// group they're in.
  static const _groupWide = {
    'over', 'atop', 'choose', 'above', 'brace', 'brack', //
    'displaystyle', 'textstyle', 'scriptstyle', 'scriptscriptstyle', //
    'color', 'bf', 'it', 'rm', 'sf', 'tt', 'cal', 'frak', 'Bbb', //
    'tiny', 'scriptsize', 'footnotesize', 'small', 'normalsize', //
    'large', 'Large', 'LARGE', 'huge', 'Huge',
  };

  static List<(md.Element, String)> _mathPieces(md.Element math) {
    final whole = [(math, '')];
    final source = math.attributes['source']!;
    final tex = math.textContent;
    final texStart = source.indexOf(tex);
    final cuts = <(int, int)>[];
    var depth = 0;
    for (var i = 0; i < tex.length; i++) {
      switch (tex[i]) {
        case r'\':
          final word = _texWord.matchAsPrefix(tex, i + 1)?[0];
          // It acts on the rest of the group, so on pieces after a cut too.
          if (depth == 0 && _groupWide.contains(word)) return whole;
          if (word == 'left' || word == 'begin') depth++;
          if (word == 'right' || word == 'end') depth--;
          if (word == null && i + 1 < tex.length) {
            if (tex[i + 1] == '{') depth++;
            if (tex[i + 1] == '}') depth--;
          }
          i += word?.length ?? 1;
        case '{' || '(' || '[':
          depth++;
        case '}' || ')' || ']':
          depth--;
        case ',' when depth == 0:
          final gap = _space.matchAsPrefix(tex, i + 1);
          if (gap != null) cuts.add((texStart + i + 1, texStart + gap.end));
      }
      if (depth < 0) return whole;
    }
    if (depth != 0 || cuts.isEmpty) return whole;
    final pieces = <(md.Element, String)>[];
    var at = 0;
    for (final (end, next) in [...cuts, (source.length, source.length)]) {
      final pieceSource = source.substring(at, end);
      final pieceTex = source
          .substring(max(at, texStart), min(end, texStart + tex.length))
          .trim();
      if (Math.tex(pieceTex).parseError != null) return whole;
      pieces.add((
        md.Element('math', [md.Text(pieceTex)])
          ..attributes['display'] = math.attributes['display']!
          ..attributes['source'] = pieceSource,
        source.substring(end, next),
      ));
      at = next;
    }
    return pieces;
  }

  Widget _paragraph(
    BuildContext context,
    List<md.Node> nodes,
    TextStyle style,
  ) => Text.rich(TextSpan(children: _spans(context, nodes, style)));

  Widget _codeBlock(md.Element pre) {
    final code = pre.children?.firstOrNull;
    final language = code is md.Element
        ? code.attributes['class']?.replaceFirst('language-', '')
        : null;
    // The parser keeps the newline before the closing fence.
    var text = pre.textContent;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    return GaiaCodeBlock(code: text, language: language);
  }

  Widget _list(
    BuildContext context,
    md.Element list,
    TextStyle style,
    int depth,
  ) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = [
      for (final item in list.children ?? const <md.Node>[])
        if (item is md.Element && item.tag == 'li') item,
    ];
    final fontSize = style.fontSize ?? 14;
    final markerWidth = ordered
        ? fontSize * (0.6 * '${start + items.length}'.length + 0.9)
        // A task's checkbox and its gap.
        : fontSize * 1.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _spaced([
        for (final (i, item) in items.indexed)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A task's checkbox is its marker.
              if (item.attributes['class'] != 'task-list-item')
                SelectionContainer.disabled(
                  child: SizedBox(
                    width: markerWidth,
                    child: ordered
                        ? Text('${start + i}.', style: style)
                        // Centred where a task's checkbox is.
                        : Padding(
                            padding: EdgeInsets.only(right: fontSize * 0.4),
                            child: Text(
                              _bullets[depth % _bullets.length],
                              style: style,
                              textAlign: TextAlign.center,
                            ),
                          ),
                  ),
                ),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _spaced([
                    for (final (j, block) in _blocks(
                      context,
                      item.children ?? const [],
                      style,
                      depth: depth + 1,
                    ).indexed)
                      // Under a task's text, past its checkbox.
                      if (j > 0 && item.attributes['class'] == 'task-list-item')
                        Padding(
                          padding: EdgeInsets.only(left: fontSize * 1.5),
                          child: block,
                        )
                      else
                        block,
                  ], _itemGap),
                ),
              ),
            ],
          ),
      ], _itemGap),
    );
  }

  Widget _table(BuildContext context, md.Element table, TextStyle style) {
    final outline = Theme.of(context).colorScheme.outlineVariant;
    final rows = <TableRow>[];
    for (final section in table.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element || row.tag != 'tr') continue;
        final cells = [
          for (final cell in row.children ?? const <md.Node>[])
            if (cell is md.Element) cell,
        ];
        rows.add(
          TableRow(
            children: [
              for (final cell in cells)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: _spans(
                        context,
                        cell.children ?? const [],
                        cell.tag == 'th'
                            ? style.copyWith(fontWeight: FontWeight.w600)
                            : style,
                      ),
                    ),
                    textAlign: switch (cell.attributes['align']) {
                      'center' => TextAlign.center,
                      'right' => TextAlign.right,
                      _ => TextAlign.left,
                    },
                  ),
                ),
            ],
          ),
        );
      }
    }
    // A row the parser left short would fail the table.
    final columns = rows.fold(0, (most, row) => max(most, row.children.length));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const MinColumnWidth(
          IntrinsicColumnWidth(),
          FixedColumnWidth(320),
        ),
        border: TableBorder.all(color: outline),
        children: [
          for (final row in rows)
            TableRow(
              children: [
                ...row.children,
                for (var i = row.children.length; i < columns; i++)
                  const SizedBox.shrink(),
              ],
            ),
        ],
      ),
    );
  }

  List<InlineSpan> _spans(
    BuildContext context,
    List<md.Node> nodes,
    TextStyle style,
  ) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        spans.addAll(_withPaths(context, node.text, style));
        continue;
      }
      if (node is! md.Element) continue;
      final children = node.children ?? const <md.Node>[];
      switch (node.tag) {
        case 'strong':
          spans.addAll(
            _spans(
              context,
              children,
              style.copyWith(fontWeight: FontWeight.w700),
            ),
          );
        case 'em':
          spans.addAll(
            _spans(
              context,
              children,
              style.copyWith(fontStyle: FontStyle.italic),
            ),
          );
        case 'del':
          spans.addAll(
            _spans(
              context,
              children,
              style.copyWith(decoration: TextDecoration.lineThrough),
            ),
          );
        case 'code':
          final code = node.textContent;
          final codeStyle = style.copyWith(
            fontFamily: AppFonts.monoFamily,
            backgroundColor: theme.colorScheme.onSurface.withValues(
              alpha: 0.08,
            ),
          );
          final target = gaiaLinkTarget(code.trim());
          spans.add(
            target == null
                ? TextSpan(text: code, style: codeStyle)
                : _link(context, code, target, codeStyle),
          );
        case 'a':
          final href = node.attributes['href'];
          final target = href == null ? null : gaiaHrefTarget(href);
          if (target == null) {
            spans.addAll(_spans(context, children, style));
          } else {
            // A recognizer acts only on the span it's on, so on each part.
            for (final span in _spans(
              context,
              children,
              _linkStyle(context, style),
            )) {
              spans.add(
                span is TextSpan && span.recognizer == null
                    ? TextSpan(
                        text: span.text,
                        style: span.style,
                        mouseCursor: SystemMouseCursors.click,
                        recognizer: _tap(target),
                      )
                    : span,
              );
            }
          }
        case 'math':
          for (final (piece, gap) in _mathPieces(node)) {
            spans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                // A piece still wider than the line scrolls, not cut off.
                child: _math(piece, style, scrolls: true),
              ),
            );
            if (gap.isNotEmpty) spans.add(TextSpan(text: gap, style: style));
          }
        case 'br':
          spans.add(const TextSpan(text: '\n'));
        case 'img':
          spans.add(TextSpan(text: node.attributes['alt'] ?? '', style: style));
        case 'input':
          final task = _task++;
          final checked =
              (node.attributes['checked'] == 'true') !=
              widget.checks.contains(task);
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              // Copies as the box character for how it's shown.
              child: _SelectableMath(
                source: checked ? '☑ ' : '☐ ',
                child: Padding(
                  padding: EdgeInsets.only(right: (style.fontSize ?? 14) * 0.4),
                  child: _TaskCircle(
                    checked: checked,
                    size: (style.fontSize ?? 14) * 1.1,
                    onTap: switch (widget.onCheck) {
                      final onCheck? => () => onCheck(task),
                      null => null,
                    },
                  ),
                ),
              ),
            ),
          );
        default:
          spans.addAll(_spans(context, children, style));
      }
    }
    return spans;
  }

  /// [text] with the paths in it that exist here as links.
  List<InlineSpan> _withPaths(
    BuildContext context,
    String text,
    TextStyle style,
  ) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final match in _pathInText.allMatches(text)) {
      final path = match[0]!.replaceFirst(_trailingPunctuation, '');
      final target = gaiaLinkTarget(path);
      if (target == null) continue;
      if (match.start > at) {
        spans.add(
          TextSpan(text: text.substring(at, match.start), style: style),
        );
      }
      spans.add(_link(context, path, target, style));
      at = match.start + path.length;
    }
    if (at < text.length) {
      spans.add(TextSpan(text: text.substring(at), style: style));
    }
    return spans;
  }

  TextSpan _link(
    BuildContext context,
    String text,
    Uri target,
    TextStyle style,
  ) => TextSpan(
    text: text,
    style: _linkStyle(context, style),
    mouseCursor: SystemMouseCursors.click,
    recognizer: _tap(target),
  );

  TextStyle _linkStyle(BuildContext context, TextStyle style) {
    final color = Theme.of(context).colorScheme.primary;
    return style.copyWith(color: color, fontWeight: FontWeight.w500);
  }

  TapGestureRecognizer _tap(Uri target) => _taps.putIfAbsent(
    '$target',
    () => TapGestureRecognizer()..onTap = () => unawaited(_follow(target)),
  );

  static const _blockTags = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'blockquote',
    'pre',
    'hr',
    'table',
    'section',
    'div',
  };

  static const _headingScale = {
    'h1': 1.4,
    'h2': 1.25,
    'h3': 1.12,
    'h4': 1.0,
    'h5': 1.0,
    'h6': 1.0,
  };

  static const _bullets = ['•', '◦', '▪'];
}

/// A task-list checkbox: an outlined circle, filled with a tick once done.
class _TaskCircle extends StatelessWidget {
  const _TaskCircle({
    required this.checked,
    required this.size,
    required this.onTap,
  });

  final bool checked;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: checked ? scheme.primary : null,
        border: Border.all(
          color: checked ? scheme.primary : scheme.onSurfaceVariant,
          width: 1.5,
        ),
      ),
      child: checked
          ? Icon(Icons.check, size: size * 0.7, color: scheme.onPrimary)
          : null,
    );
    if (onTap == null) return circle;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: circle,
      ),
    );
  }
}

/// LaTeX in a message: `$$…$$` or `\[…\]` displayed, `\(…\)` or `$…$`
/// inline. A single `$` opens only before a non-space and closes only after
/// one and not before a digit, so prices stay text, nor before what continues
/// a shell variable's name or opens the next, so `$A/$B` does; `\$` is a
/// dollar sign. `\[…\]` right before `(` is an escaped link, `\[a\](x)`.
///
/// Matched as the block streams in, so an equation is typeset once it's
/// closed, before the reply finishes.
class _MathSyntax extends md.InlineSyntax {
  _MathSyntax() : super(_mathPattern.pattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_mathElement(match));
    return true;
  }
}

final _mathPattern = RegExp(
  r'\$\$([\s\S]+?)\$\$|\\\[((?:(?!\\\])[\s\S])+?)\\\](?!\()|\\\(([\s\S]+?)\\\)'
  r'|\$(?![\s$])((?:\\.|[^$\\\n])+?)(?<!\s)\$(?![\w{(])',
);

md.Element _mathElement(Match match) {
  final display = match[1] ?? match[2];
  final tex = (display ?? match[3] ?? match[4]!).trim();
  return md.Element('math', [md.Text(tex)])
    ..attributes['display'] = '${display != null}'
    ..attributes['source'] = match[0]!;
}

/// Display math opening a line and closing at the end of one, taken whole
/// before the other blocks: its lines that start like a list item or
/// underline a heading stay TeX. Unclosed, as it streams, it's its text
/// up to a blank line.
class _DisplayMathSyntax extends md.BlockSyntax {
  const _DisplayMathSyntax();

  @override
  RegExp get pattern => _displayMathOpen;

  @override
  bool canParse(md.BlockParser parser) => _lastLine(parser) != null;

  /// How many lines on from the current one the math ends; null when what
  /// closes it has more text after it on its line, left to [_MathSyntax].
  static int? _lastLine(md.BlockParser parser) {
    final open = _displayMathOpen.firstMatch(parser.current.content);
    if (open == null) return null;
    final close = open[1] == r'$$' ? r'$$' : r'\]';
    var rest = parser.current.content.substring(open.end);
    for (var i = 0; ; i++) {
      final at = rest.indexOf(close);
      if (at >= 0) {
        return rest.substring(at + close.length).trim().isEmpty ? i : null;
      }
      final next = parser.peek(i + 1);
      if (next == null || next.isBlankLine) return i;
      rest = next.content;
    }
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final lines = <String>[];
    for (var i = _lastLine(parser)!; i >= 0; i--) {
      lines.add(parser.current.content);
      parser.advance();
    }
    final source = lines.join('\n').trim();
    final math = _mathPattern.matchAsPrefix(source);
    return md.Element('p', [
      if (math != null && math.end == source.length)
        _mathElement(math)
      else
        md.Text(source),
    ]);
  }
}

final _displayMathOpen = RegExp(r'^ {0,3}(\$\$|\\\[)');

/// Typeset math that answers a table's width question with the size it
/// last laid out at. flutter_math_fork typesets `\binom`, `\sqrt` and
/// `\left…\right` with a LayoutBuilder, which throws when asked in debug,
/// failing the whole chat's layout, and answers 0 in release. Math not
/// laid out yet answers 0, then has what asked measure again.
class _MeasuredMath extends SingleChildRenderObjectWidget {
  const _MeasuredMath({required this.id, required super.child});

  /// The TeX, whether it's display math, and its style: what its size
  /// depends on.
  final Object id;

  /// Kept past the render object, so math built again, as when a chat
  /// scrolls back to it, sizes its table right on the first frame.
  static final _sizes = <Object, Size>{};

  @override
  _RenderMeasuredMath createRenderObject(BuildContext context) =>
      _RenderMeasuredMath(id);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasuredMath renderObject,
  ) => renderObject.id = id;
}

class _RenderMeasuredMath extends RenderProxyBox {
  _RenderMeasuredMath(this.id);

  Object id;

  /// Whether something asked its size: math in prose never is.
  var _asked = false;

  Size get _size {
    _asked = true;
    return _MeasuredMath._sizes[id] ?? Size.zero;
  }

  @override
  double computeMinIntrinsicWidth(double height) => _size.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _size.width;

  @override
  double computeMinIntrinsicHeight(double width) => _size.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _size.height;

  @override
  void performLayout() {
    super.performLayout();
    final answered = _MeasuredMath._sizes[id];
    _MeasuredMath._sizes[id] = size;
    if (!_asked || answered == size) return;
    // Not now, mid-layout, and not after this frame, when selection reads
    // the text around it: just before the next frame lays out. This clears
    // the old answer from every ancestor that cached it, up to what asked.
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (attached) markNeedsLayout();
    });
  }
}

/// An equation selected whole, copying its [source]: the typeset glyphs
/// aren't text a selection can take. A task's circle copies the same way. After Flutter's [SelectableRegion]
/// adapter sample.
class _SelectableMath extends StatefulWidget {
  const _SelectableMath({required this.source, required this.child});

  final String source;
  final Widget child;

  @override
  State<_SelectableMath> createState() => _SelectableMathState();
}

class _SelectableMathState extends State<_SelectableMath> {
  /// A container of its own, as a text has: [_LineSelection] orders what
  /// registers with it by the tree only when it's a container's State.
  final _container = StaticSelectionContainerDelegate();

  @override
  void dispose() {
    _container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) == null) return widget.child;
    return SelectionContainer(
      delegate: _container,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: _MathSelectable(
          source: widget.source,
          registrar: _container,
          child: widget.child,
        ),
      ),
    );
  }
}

class _MathSelectable extends SingleChildRenderObjectWidget {
  const _MathSelectable({
    required this.source,
    required this.registrar,
    required super.child,
  });

  final String source;
  final SelectionRegistrar registrar;

  @override
  _RenderMathSelectable createRenderObject(BuildContext context) =>
      _RenderMathSelectable(
        source,
        DefaultSelectionStyle.of(context).selectionColor!,
        registrar,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMathSelectable renderObject,
  ) {
    renderObject
      ..source = source
      ..selectionColor = DefaultSelectionStyle.of(context).selectionColor!
      ..registrar = registrar;
  }
}

class _RenderMathSelectable extends RenderProxyBox
    with Selectable, SelectionRegistrant {
  _RenderMathSelectable(this.source, this._selectionColor, SelectionRegistrar r)
    : _geometry = ValueNotifier(_noSelection) {
    registrar = r;
    _geometry.addListener(markNeedsPaint);
  }

  static const _noSelection = SelectionGeometry(
    status: SelectionStatus.none,
    hasContent: true,
  );

  String source;
  final ValueNotifier<SelectionGeometry> _geometry;

  Color _selectionColor;
  set selectionColor(Color value) {
    if (_selectionColor == value) return;
    _selectionColor = value;
    markNeedsPaint();
  }

  @override
  void addListener(VoidCallback listener) => _geometry.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _geometry.removeListener(listener);

  @override
  SelectionGeometry get value => _geometry.value;

  @override
  List<Rect> get boundingBoxes => [paintBounds];

  Offset? _start;
  Offset? _end;

  void _updateGeometry() {
    final bounds = Offset.zero & size;
    if (_start == null ||
        _end == null ||
        bounds.intersect(Rect.fromPoints(_start!, _end!)).isEmpty) {
      _geometry.value = _noSelection;
      return;
    }
    final first = SelectionPoint(
      localPosition: bounds.bottomLeft,
      lineHeight: bounds.height,
      handleType: TextSelectionHandleType.left,
    );
    final second = SelectionPoint(
      localPosition: bounds.bottomRight,
      lineHeight: bounds.height,
      handleType: TextSelectionHandleType.right,
    );
    final reversed = _start!.dy != _end!.dy
        ? _start!.dy > _end!.dy
        : _start!.dx > _end!.dx;
    _geometry.value = SelectionGeometry(
      status: SelectionStatus.uncollapsed,
      hasContent: true,
      startSelectionPoint: reversed ? second : first,
      endSelectionPoint: reversed ? first : second,
      selectionRects: [bounds],
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    var result = SelectionResult.none;
    switch (event) {
      case SelectionEdgeUpdateEvent(:final globalPosition):
        final bounds = Offset.zero & size;
        // A scrollable stands for past its end with an infinite position.
        final point = globalPosition.isInfinite
            ? Offset.infinite
            : globalToLocal(globalPosition);
        final adjusted = SelectionUtils.adjustDragOffset(bounds, point);
        if (event.type == SelectionEventType.startEdgeUpdate) {
          _start = adjusted;
        } else {
          _end = adjusted;
        }
        result = SelectionUtils.getResultBasedOnRect(bounds, point);
      case ClearSelectionEvent():
        _start = _end = null;
      case SelectAllSelectionEvent() ||
          SelectWordSelectionEvent() ||
          SelectParagraphSelectionEvent():
        _start = Offset.zero;
        _end = Offset.infinite;
      case GranularlyExtendSelectionEvent(:final forward, :final isEnd):
        if (_start == null || _end == null) {
          _start = _end = forward ? Offset.zero : Offset.infinite;
        }
        result = _extend(
          forward ? Offset.infinite : Offset.zero,
          forward,
          isEnd,
        );
      case DirectionallyExtendSelectionEvent(
        :final direction,
        :final dx,
        :final isEnd,
      ):
        final x = globalToLocal(Offset(dx, 0)).dx;
        final forward =
            direction == SelectionExtendDirection.forward ||
            direction == SelectionExtendDirection.nextLine;
        if (_start == null || _end == null) {
          _start = _end = forward ? Offset.zero : Offset.infinite;
        }
        final to = switch (direction) {
          SelectionExtendDirection.previousLine => Offset.zero,
          SelectionExtendDirection.backward =>
            x < 0 ? Offset.zero : Offset.infinite,
          SelectionExtendDirection.nextLine => Offset.infinite,
          SelectionExtendDirection.forward =>
            x > size.width ? Offset.infinite : Offset.zero,
        };
        result = _extend(to, forward, isEnd);
      default:
    }
    _updateGeometry();
    return result;
  }

  /// Moves an edge of the selection [to] one end of the equation, passing
  /// the move on when it's there already.
  SelectionResult _extend(Offset to, bool forward, bool isEnd) {
    final at = isEnd ? _end : _start;
    if (isEnd) {
      _end = to;
    } else {
      _start = to;
    }
    if (at != to) return SelectionResult.end;
    return forward ? SelectionResult.next : SelectionResult.previous;
  }

  @override
  SelectedContent? getSelectedContent() =>
      value.hasSelection ? SelectedContent(plainText: source) : null;

  @override
  SelectedContentRange? getSelection() => value.hasSelection
      ? const SelectedContentRange(startOffset: 0, endOffset: 1)
      : null;

  @override
  int get contentLength => 1;

  LayerLink? _startHandle;
  LayerLink? _endHandle;

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startHandle == startHandle && _endHandle == endHandle) return;
    _startHandle = startHandle;
    _endHandle = endHandle;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (value.hasSelection) {
      context.canvas.drawRect(offset & size, Paint()..color = _selectionColor);
    }
    super.paint(context, offset);
    for (final (link, point) in [
      (_startHandle, value.startSelectionPoint),
      (_endHandle, value.endSelectionPoint),
    ]) {
      if (link == null || point == null) continue;
      context.pushLayer(
        LeaderLayer(link: link, offset: offset + point.localPosition),
        (_, _) {},
        Offset.zero,
      );
    }
  }

  @override
  void dispose() {
    _geometry.dispose();
    _startHandle = null;
    _endHandle = null;
    super.dispose();
  }
}

/// A Windows path in running text: up to whitespace, so one with a space
/// in it is found only in a code span.
final _pathInText = RegExp(r'(?<![\w/\\])[A-Za-z]:[\\/][^\s<>"|*?`]*');
final _trailingPunctuation = RegExp(r'''[.,;:!?)\]}'"]+$''');

/// A `:12` or `:12:5` after a path, as tools cite a line.
final _lineSuffix = RegExp(r':\d+(?::\d+)?$');

/// Opens [target], or shows it in Explorer if [gaiaOpensDirectly] says no.
Future<void> _follow(Uri target) async {
  if (gaiaOpensDirectly(target)) {
    await launchUrl(target, mode: LaunchMode.externalApplication);
    return;
  }
  // Separate arguments: Dart quotes one with a space whole, which Explorer
  // can't parse.
  await Process.run('explorer', ['/select,', target.toFilePath(windows: true)]);
}

/// Whether a click may open [target] itself: a URL, a folder or a file of a
/// type that doesn't run anything when opened. The agent wrote the link, and
/// opening a program or script runs it, so anything not known to be safe is
/// only shown (§9.5).
bool gaiaOpensDirectly(Uri target) {
  if (target.scheme != 'file') return true;
  final path = target.toFilePath(windows: true);
  return FileSystemEntity.isDirectorySync(path) ||
      _opensDirectly.contains(p.windows.extension(path).toLowerCase());
}

/// Not scripts a default app may run (`.py`, `.js`, `.ps1`), pages (`.html`,
/// `.svg`) or Office files, which can hold macros.
const _opensDirectly = {
  '.txt',
  '.md',
  '.log',
  '.pdf',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
  '.json',
  '.yaml',
  '.yml',
  '.toml',
  '.dart',
  '.ts',
  '.tsx',
  '.css',
  '.rs',
  '.go',
  '.java',
  '.kt',
  '.swift',
  '.c',
  '.cpp',
  '.h',
  '.cs',
};

/// What clicking a Markdown link to [href] opens, as [gaiaLinkTarget]. Only a
/// path is unescaped, the parser having escaped its backslashes: a URL's
/// escapes are part of what it asks for. A path that doesn't decode is text.
Uri? gaiaHrefTarget(String href) {
  if (href.toLowerCase().startsWith('http')) return gaiaLinkTarget(href);
  try {
    return gaiaLinkTarget(Uri.decodeFull(href));
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// What clicking [text] opens: an http(s) URL, or a file or folder that
/// exists on this device. Null for anything else, which stays text: the
/// agent wrote it, so no other scheme is followed (§9.5).
Uri? gaiaLinkTarget(String text) {
  final uri = Uri.tryParse(text);
  if (uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty) {
    return uri;
  }
  if (!_pathStart.hasMatch(text)) return null;
  final path = text.replaceFirst(_lineSuffix, '');
  return _exists(path) ? Uri.file(path, windows: true) : null;
}

final _pathStart = RegExp(r'^[A-Za-z]:[\\/]');

/// Whether each path is there, asked again only after [_existenceLife]: a
/// message's blocks are built again as it streams and scrolls, but the agent
/// may create or delete what it named.
final _existence = <String, ({bool exists, DateTime asked})>{};
const _existenceLife = Duration(seconds: 5);

bool _exists(String path) {
  final now = DateTime.now();
  final known = _existence[path];
  if (known != null && now.difference(known.asked) < _existenceLife) {
    return known.exists;
  }
  if (_existence.length > 512) _existence.clear();
  final exists =
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  _existence[path] = (exists: exists, asked: now);
  return exists;
}

/// A fenced block of code: highlighted by its language, scrolling sideways
/// rather than wrapping, with its language and a copy button above it.
class GaiaCodeBlock extends StatefulWidget {
  const GaiaCodeBlock({super.key, required this.code, this.language});

  final String code;
  final String? language;

  @override
  State<GaiaCodeBlock> createState() => _GaiaCodeBlockState();
}

class _GaiaCodeBlockState extends State<GaiaCodeBlock> {
  /// Shows a tick for a moment after copying.
  Timer? _copied;

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.code)));
    _copied?.cancel();
    setState(
      () => _copied = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _copied = null);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.brightness == Brightness.dark
        ? atomOneDarkTheme
        : atomOneLightTheme;
    final root = palette['root'];
    final base = DefaultTextStyle.of(context).style;
    final style = base.copyWith(
      fontFamily: AppFonts.monoFamily,
      fontSize: (base.fontSize ?? 14) * 0.92,
      color: root?.color,
    );
    final label = style.copyWith(
      fontFamily: AppFonts.family,
      fontSize: style.fontSize! * 0.82,
      color: theme.colorScheme.primary.withValues(alpha: 0.7),
    );
    final language = widget.language;
    final copy = SelectionContainer.disabled(
      child: IconButton(
        tooltip: _copied == null ? 'Copy code' : 'Copied',
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        color: theme.colorScheme.onSurfaceVariant,
        onPressed: _copy,
        icon: Icon(_copied == null ? Icons.content_copy : Icons.check),
      ),
    );
    final body = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(12, language == null ? 10 : 0, 12, 10),
      child: Text.rich(
        TextSpan(
          style: style,
          children: _highlighted(widget.code, language, palette),
        ),
        softWrap: false,
      ),
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.black.withValues(alpha: 0.35),
          root?.backgroundColor ?? theme.colorScheme.surface,
        ),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.14),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      // Without a language there's no header line: the copy button sits
      // beside the code instead.
      child: language == null
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: body),
                Padding(padding: const EdgeInsets.all(4), child: copy),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectionContainer.disabled(
                          child: Text(language, style: label),
                        ),
                      ),
                      copy,
                    ],
                  ),
                ),
                body,
              ],
            ),
    );
  }
}

/// [code] coloured by [language]'s grammar; plain without one, or for one
/// the highlighter doesn't know or fails on.
List<TextSpan> _highlighted(
  String code,
  String? language,
  Map<String, TextStyle> palette,
) {
  if (language == null || language.isEmpty) return [TextSpan(text: code)];
  final List<hl.Node> nodes;
  try {
    nodes = hl.highlight.parse(code, language: language).nodes ?? const [];
  } on Object {
    return [TextSpan(text: code)];
  }
  List<TextSpan> walk(List<hl.Node> nodes) => [
    for (final node in nodes)
      TextSpan(
        text: node.value,
        style: palette[node.className],
        children: node.children == null ? null : walk(node.children!),
      ),
  ];
  return walk(nodes);
}
