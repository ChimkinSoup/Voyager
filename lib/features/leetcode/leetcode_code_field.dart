import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:highlight/highlight_core.dart' show Mode;
import 'package:highlight/languages/cpp.dart' as lang_cpp;
import 'package:highlight/languages/cs.dart' as lang_cs;
import 'package:highlight/languages/go.dart' as lang_go;
import 'package:highlight/languages/java.dart' as lang_java;
import 'package:highlight/languages/javascript.dart' as lang_javascript;
import 'package:highlight/languages/python.dart' as lang_python;
import 'package:highlight/languages/rust.dart' as lang_rust;
import 'package:highlight/languages/typescript.dart' as lang_typescript;
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/text/typing_rewrites.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_comment_stripper.dart';
import 'package:voyager/features/leetcode/leetcode_type_highlight.dart';

/// The highlight grammar for a stored `codeLanguage` key, falling back to
/// Python for anything unrecognised. Public because inline `` `code` `` in the
/// prose fields is tokenized with the same grammar the code block uses.
Mode leetCodeHighlightMode(String language) => _modeForLanguage(language);

// Built once: [CodeController] registers a grammar per distinct [Mode]
// instance, so a fresh copy per controller would pile up registrations.
final _java = injectPascalCaseTypes(lang_java.java);
final _cpp = injectPascalCaseTypes(lang_cpp.cpp);
final _typescript = injectPascalCaseTypes(lang_typescript.typescript);
final _csharp = injectPascalCaseTypes(lang_cs.cs);

Mode _modeForLanguage(String language) => switch (language) {
  'java' => _java,
  'cpp' => _cpp,
  'javascript' => lang_javascript.javascript,
  'typescript' => _typescript,
  'go' => lang_go.go,
  'rust' => lang_rust.rust,
  'csharp' => _csharp,
  _ => lang_python.python,
};

Map<String, TextStyle> _themeFor(Brightness brightness) =>
    brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme;

/// Atom One's `root` style carries a [TextStyle.backgroundColor] meant for
/// the editor chrome. [SpanBuilder] would otherwise paint it behind every
/// glyph — and a second time on a selected newline, which is exactly the
/// double-dark empty line this field was showing. The container already
/// fills that colour; spans only need the foreground tokens.
Map<String, TextStyle> _spanStyles(Map<String, TextStyle> theme) => {
  for (final entry in theme.entries)
    entry.key: entry.value.copyWith(backgroundColor: null),
};

/// Token colours for [brightness], keyed by highlight class name — the same
/// Atom One palette the code block paints, so an inline `` `for` `` in the
/// prose is the colour it would be inside the code box.
Map<String, TextStyle> leetCodeSyntaxStyles(Brightness brightness) =>
    _spanStyles(_themeFor(brightness));

/// The code box's own paper: the Atom One `root` background the surface fills
/// with, and the foreground its untokenized text takes.
///
/// Exported because chrome mounted *on* the box — the scratch pad's notepad
/// header — sits on that paper rather than on the app's surface, and Atom One
/// dark is dark in both app themes. Reading `onSurface` there would put black
/// text on a near-black strip in light mode.
({Color background, Color foreground}) leetCodeCodePalette(
  BuildContext context,
) {
  final theme = Theme.of(context);
  final root = _themeFor(theme.brightness)['root'];
  return (
    background: root?.backgroundColor ?? theme.colorScheme.surface,
    foreground: root?.color ?? theme.colorScheme.onSurface,
  );
}

/// Size and leading are pinned rather than inherited. Left unset, the two
/// columns resolve them from different theme slots — the line numbers'
/// [TextField] falls back to `bodyLarge`, while a bare code [TextField]
/// seeds its default from `titleMedium` — so their alignment would silently
/// depend on those slots staying identical, which they are today only by
/// coincidence of the Material 3 scale.
final _codeTextStyle = AppFonts.style(
  fontSize: 16,
).copyWith(fontFamily: AppFonts.monoFamily);

/// One line of [LeetCodeCodeSurface], and the inset above its first one.
///
/// Public because anything laid out beside the editor line-for-line — the
/// cheat sheet's per-line complexity field — has to match both or its lines
/// drift out of step with the code they belong to.
final double kLeetCodeCodeLineHeight =
    (_codeTextStyle.fontSize ?? 16) * (_codeTextStyle.height ?? 1);
final double kLeetCodeCodeTopInset = _codeContentPadding.top;

/// Width every language capsule takes, wide enough for the longest label
/// ("javascript"/"typescript") so none of them has to ellipsize.
const _kLanguagePillWidth = 84.0;
const _lineNumberColumnWidth = 34.0;
const _lineNumberGap = 8.0;
const _codeGutterPad = 8.0;

/// Same padding [CodeField] used on its inner [TextField], plus the 8px
/// left inset [CodeField] put on its container when the built-in gutter is
/// hidden. Overlay and field must share this exactly.
const _codeContentPadding = EdgeInsets.fromLTRB(_codeGutterPad, 16, 0, 16);
const _codeDecoration = InputDecoration(
  isCollapsed: true,
  contentPadding: _codeContentPadding,
  disabledBorder: InputBorder.none,
  border: InputBorder.none,
  focusedBorder: InputBorder.none,
);

/// Tab inserts spaces / Shift+Tab outdents. Without these, Tab falls through to
/// focus traversal and leaves the code box for the title field.
class _CodeTabIntent extends Intent {
  const _CodeTabIntent();
}

class _CodeOutdentIntent extends Intent {
  const _CodeOutdentIntent();
}

const _codeEditorShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.tab): _CodeTabIntent(),
  SingleActivator(LogicalKeyboardKey.tab, shift: true): _CodeOutdentIntent(),
};

/// Line numbers rendered as their own borderless [TextField], configured
/// identically (padding, decoration, text style) to the code [TextField],
/// instead of using [GutterStyle]'s built-in numbers column.
///
/// [GutterStyle] lays its numbers out in a `Table` of single-line cells,
/// entirely separate from the code's own multi-line paragraph. The two are
/// supposed to produce identical per-line heights for a shared [TextStyle],
/// but in practice that depends on the exact font the platform resolves —
/// verified to match in a test harness but to visibly drift on a real
/// Windows build. Using the same widget with the same configuration for
/// both columns removes the dependency on that coincidence: whatever a
/// given platform/font does to line height, it does identically to both,
/// since they run the exact same code path in lockstep.
class _LineNumbers extends StatefulWidget {
  const _LineNumbers({required this.source, required this.color});

  final TextEditingController source;
  final Color? color;

  @override
  State<_LineNumbers> createState() => _LineNumbersState();
}

class _LineNumbersState extends State<_LineNumbers> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _numbersFor(widget.source.text));
    _focusNode = FocusNode(canRequestFocus: false);
    widget.source.addListener(_onSourceChanged);
  }

  @override
  void didUpdateWidget(covariant _LineNumbers oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source.removeListener(_onSourceChanged);
      widget.source.addListener(_onSourceChanged);
      _controller.text = _numbersFor(widget.source.text);
    }
  }

  @override
  void dispose() {
    widget.source.removeListener(_onSourceChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSourceChanged() {
    final numbers = _numbersFor(widget.source.text);
    if (_controller.text != numbers) {
      _controller.text = numbers;
    }
  }

  String _numbersFor(String text) {
    final lineCount = '\n'.allMatches(text).length + 1;
    return List.generate(lineCount, (i) => '${i + 1}').join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _lineNumberColumnWidth,
      child: IgnorePointer(
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          readOnly: true,
          showCursor: false,
          maxLines: null,
          textAlign: TextAlign.right,
          style: _codeTextStyle.copyWith(color: widget.color),
          decoration: const InputDecoration(
            isCollapsed: true,
            contentPadding: EdgeInsets.symmetric(vertical: 16),
            disabledBorder: InputBorder.none,
            border: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
      ),
    );
  }
}

/// The decorated code box: background, border, line-number column and the
/// editor itself. Everything a caller wraps around it — a size, a language
/// row, a tap target — is that caller's own chrome.
///
/// Public because the scratch code pad mounts the same surface with a
/// different frame around it: it fills its parent instead of taking a fixed
/// 160–320px, and its toolbar lives above the whole pad rather than above the
/// box.
class LeetCodeCodeSurface extends StatelessWidget {
  const LeetCodeCodeSurface({
    super.key,
    required this.controller,
    this.focusNode,
    this.readOnly = false,
    this.scrollable = true,
    this.framed = true,
  });

  final CodeController controller;

  /// Supplied when the caller needs to focus the editor itself — the tap
  /// target in [LeetCodeCodeInput], the `C` shortcut in a session.
  final FocusNode? focusNode;

  final bool readOnly;

  /// Whether the box scrolls its own overflow. Off for a surface that is
  /// already inside a scrolling page, which would otherwise nest two.
  final bool scrollable;

  /// Whether the box draws its own paper, border and corners. Off for a caller
  /// that has already framed it — the scratch pad, whose expand strip and
  /// editor share one notepad border.
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeTheme = _themeFor(theme.brightness);
    final palette = leetCodeCodePalette(context);
    final lineNumberColor = palette.foreground.withValues(alpha: 0.5);
    final textStyle = _codeTextStyle.copyWith(color: palette.foreground);

    // The Vim scope wraps the whole box rather than the editor inside it. The
    // mode badge hangs off the bottom-right of whatever the scope calls "the
    // field" (see VimTextScope's *Mode badge placement*), and the editor is as
    // tall as the code it holds and scrolls inside this box — so anchoring to
    // it pinned the badge to the last line, where scrolling up took it out of
    // view entirely. The box is the part with a fixed height, so hanging the
    // badge off that keeps it in the corner it belongs in.
    return VimTextScope(
      enabled: VimEnabledScope.of(context) && vimSuitsField(readOnly: readOnly),
      // Hard off, per SNIPPET.md §2.3. Tab here indents the code (see
      // [_codeEditorShortcuts]), and a prose trigger firing inside a code
      // block would corrupt the very text it is meant to be showing verbatim.
      snippetsAllowed: false,
      // Hard off, per AUTOCORRECT.md §4.1. Code is the one place where a word
      // that is not in the dictionary is almost always exactly right.
      autocorrectAllowed: false,
      // Hard off, per CAPS_LOCK.md §2.2 — a mark riding beside the caret
      // through code is chrome the editor never asked for, and the gutter,
      // highlight and Vim block are already competing for that strip.
      capsLockIndicatorAllowed: false,
      // `>>` / `<<` move by the same width Tab does.
      shiftWidth: kLeetCodeEditorParams.tabSpaces,
      // `o` opens the body of a `:` or `{` line, as Enter does here.
      smartIndent: true,
      controller: controller,
      multiline: true,
      accentColor: theme.colorScheme.primary,
      builder: (context, vim) {
        final Widget body = Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LineNumbers(source: controller, color: lineNumberColor),
              const SizedBox(width: _lineNumberGap),
              Expanded(
                child: _LeetCodeCodeEditor(
                  controller: controller,
                  vim: vim,
                  focusNode: focusNode,
                  readOnly: readOnly,
                  textStyle: textStyle,
                  cursorColor: palette.foreground,
                ),
              ),
            ],
          ),
        );

        final Widget box = CodeTheme(
          data: CodeThemeData(styles: _spanStyles(codeTheme)),
          child: Theme(
            data: theme.copyWith(
              inputDecorationTheme: const InputDecorationTheme(),
            ),
            child: scrollable ? VoyagerScrollView(child: body) : body,
          ),
        );
        if (!framed) return box;

        return Container(
          decoration: BoxDecoration(
            color: palette.background,
            borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
            ),
          ),
          child: box,
        );
      },
    );
  }
}

/// Editable, syntax-highlighted code input for the Track modal. The code
/// pasted here is display-only text with highlighting — never compiled or
/// executed by the app.
class LeetCodeCodeInput extends StatefulWidget {
  const LeetCodeCodeInput({
    super.key,
    required this.controller,
    required this.language,
    required this.onLanguageChanged,
  });

  final CodeController controller;
  final String language;
  final ValueChanged<String> onLanguageChanged;

  @override
  State<LeetCodeCodeInput> createState() => _LeetCodeCodeInputState();
}

class _LeetCodeCodeInputState extends State<LeetCodeCodeInput> {
  /// Owned here rather than inside [_LeetCodeCodeEditor] so the tap target
  /// below can focus the field — see [_focusCodeAtEnd].
  late final FocusNode _codeFocusNode;

  @override
  void initState() {
    super.initState();
    _codeFocusNode = FocusNode();
    widget.controller.language = _modeForLanguage(widget.language);
  }

  @override
  void didUpdateWidget(covariant LeetCodeCodeInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.language != widget.language) {
      widget.controller.language = _modeForLanguage(widget.language);
    }
  }

  @override
  void dispose() {
    _codeFocusNode.dispose();
    super.dispose();
  }

  /// Drops the selected language's line comments from the buffer.
  ///
  /// The rewrite goes through [CodeController.fullText] rather than [value]:
  /// [CodeController] reconstructs an assigned value from a length diff, which
  /// misreads a multi-line deletion as a single backspace. [fullText] leaves
  /// the selection unset, so the caret is placed afterwards — clamped, since
  /// the text it used to sit in may be gone.
  void _stripComments() {
    final controller = widget.controller;
    final source = controller.fullText;
    // Comments first, then the trailing blank line — stripping a lone comment
    // off the last line leaves exactly that blank line behind, so the second
    // pass has to see what the first one produced.
    final stripped = stripLeetCodeTrailingBlankLine(
      stripLeetCodeLineComments(source, widget.language),
    );
    if (stripped == source) return;
    final caret = controller.selection.baseOffset;
    controller.fullText = stripped;
    controller.selection = TextSelection.collapsed(
      offset: caret < 0 ? stripped.length : caret.clamp(0, stripped.length),
    );
  }

  /// The box is 160px tall from empty, but a [TextField] only occupies — and
  /// so only hit-tests — the lines it actually holds. Everything under the
  /// last line reads as part of the field and does nothing when clicked, so
  /// the whole box takes taps and hands them to the editor, caret at the end
  /// of the buffer the way clicking past the last line does in a code editor.
  ///
  /// [HitTestBehavior.translucent] leaves the field's own recognizer in the
  /// arena, and hit testing enters it first, so a tap that lands on text still
  /// places the caret where it landed rather than jumping to the end.
  void _focusCodeAtEnd() {
    final controller = widget.controller;
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    _codeFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: leetCodeCodeLanguages.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final lang = leetCodeCodeLanguages[index];
                    // One width for every language, so the row reads as a set of
                    // equal choices rather than a ragged run sized by how long each
                    // language happens to be spelled ("go" next to "typescript").
                    return SizedBox(
                      width: _kLanguagePillWidth,
                      child: SelectorPill(
                        dense: true,
                        label: labelForLeetCodeLanguage(lang),
                        isActive: lang == widget.language,
                        // The whole capsule takes the accent when chosen. A border
                        // alone is a thin cue to carry the one thing this row says.
                        fillWhenActive: true,
                        onTap: () => widget.onLanguageChanged(lang),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              GlassButton(
                dense: true,
                height: 32,
                icon: const Icon(Icons.comments_disabled_outlined),
                label: 'Strip',
                tooltip:
                    'Remove ${labelForLeetCodeLanguage(widget.language)} '
                    'comments and the trailing blank line',
                onPressed: _stripComments,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 160, maxHeight: 320),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _focusCodeAtEnd,
            child: LeetCodeCodeSurface(
              controller: widget.controller,
              focusNode: _codeFocusNode,
            ),
          ),
        ),
      ],
    );
  }
}

/// Read-only syntax-highlighted code display, used in the Detail View.
class LeetCodeCodeView extends StatefulWidget {
  const LeetCodeCodeView({
    super.key,
    required this.code,
    required this.language,
  });

  final String code;
  final String language;

  @override
  State<LeetCodeCodeView> createState() => _LeetCodeCodeViewState();
}

class _LeetCodeCodeViewState extends State<LeetCodeCodeView> {
  late CodeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LeetCodeCodeController(
      text: widget.code,
      language: _modeForLanguage(widget.language),
    );
  }

  @override
  void didUpdateWidget(covariant LeetCodeCodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.language != widget.language) {
      _controller.dispose();
      _controller = LeetCodeCodeController(
        text: widget.code,
        language: _modeForLanguage(widget.language),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LeetCodeCodeSurface(
      controller: _controller,
      readOnly: true,
      scrollable: false,
    );
  }
}

/// Syntax-highlighted code [TextField] that paints selection with
/// [SelectionHighlightLayer] instead of Flutter's native highlight.
///
/// [CodeField] is a [TextField] that does not expose `selectionWidthStyle`,
/// so on Windows it keeps `BoxWidthStyle.max`. That style emits two
/// overlapping boxes on a selected empty line, and the translucent
/// selection colour double-blends into a darker band. This widget is the
/// same editor chrome — no wrap, longest-line intrinsic width, same
/// padding — with the layer the rest of the app already uses for that bug.
class _LeetCodeCodeEditor extends StatefulWidget {
  const _LeetCodeCodeEditor({
    required this.controller,
    required this.vim,
    required this.textStyle,
    required this.cursorColor,
    this.focusNode,
    this.readOnly = false,
  });

  final CodeController controller;

  /// The binding from the [VimTextScope] the whole box is wrapped in — see
  /// [LeetCodeCodeSurface.build] for why the scope sits up there and not here.
  final VimFieldBinding vim;

  /// Supplied when the caller needs to focus the field itself; one is created
  /// and owned here otherwise.
  final FocusNode? focusNode;

  final TextStyle textStyle;
  final Color cursorColor;
  final bool readOnly;

  @override
  State<_LeetCodeCodeEditor> createState() => _LeetCodeCodeEditorState();
}

class _LeetCodeCodeEditorState extends State<_LeetCodeCodeEditor> {
  FocusNode? _ownFocusNode;
  String _longestLine = '';

  FocusNode get _focusNode => widget.focusNode ?? _ownFocusNode!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) _ownFocusNode = FocusNode();
    widget.controller.addListener(_onTextChanged);
    _longestLine = _longestLineOf(widget.controller.text);
  }

  @override
  void didUpdateWidget(covariant _LeetCodeCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _longestLine = _longestLineOf(widget.controller.text);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _ownFocusNode?.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final next = _longestLineOf(widget.controller.text);
    if (next != _longestLine) setState(() => _longestLine = next);
  }

  static String _longestLineOf(String text) {
    var longest = '';
    for (final line in text.split('\n')) {
      if (line.length > longest.length) longest = line;
    }
    return longest;
  }

  @override
  Widget build(BuildContext context) {
    final vim = widget.vim;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final selectionColor = resolveSelectionColor(context);
    final strutStyle = StrutStyle.fromTextStyle(
      widget.textStyle,
      forceStrutHeight: true,
    );
    // InputDecorator still applies visual density to a collapsed field, so
    // the overlay has to take the same inset the other text overlays do —
    // otherwise the highlight sits a few pixels below the glyphs.
    final overlayPadding = withCaretMargin(
      withDensityShift(_codeContentPadding, theme.visualDensity),
      cursorWidth: vim.overlayCaretWidth,
    );

    // [VimTextOverlay] draws the Visual selection; [SelectionHighlightLayer]
    // the ordinary one. One layer, not two.
    final ownSelection = !vim.overlayPaintsSelection;

    final editor = FocusableActionDetector(
      // Read-only views still need the detector so Tab doesn't get a dead
      // binding from a parent that expects an editable code box.
      enabled: !widget.readOnly,
      shortcuts: _codeEditorShortcuts,
      actions: <Type, Action<Intent>>{
        _CodeTabIntent: CallbackAction<_CodeTabIntent>(
          onInvoke: (_) {
            widget.controller.onTabKeyAction();
            return null;
          },
        ),
        _CodeOutdentIntent: CallbackAction<_CodeOutdentIntent>(
          onInvoke: (_) {
            widget.controller.outdentSelection();
            return null;
          },
        ),
      },
      child: TextSelectionTheme(
        data: const TextSelectionThemeData(selectionColor: Colors.transparent),
        child: Stack(
          children: [
            if (ownSelection)
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: overlayPadding,
                    child: SelectionHighlightLayer(
                      controller: widget.controller,
                      focusNode: _focusNode,
                      style: widget.textStyle,
                      strutStyle: strutStyle,
                      color: selectionColor,
                    ),
                  ),
                ),
              ),
            // [LeetCodeCodeController] reads an incoming value by keystroke
            // shape, and a restored one is not a keystroke — Ctrl+Z over a
            // space typed into an indent came back outdented.
            TypingRewriteUndoGuard(
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                readOnly: widget.readOnly,
                style: widget.textStyle,
                strutStyle: strutStyle,
                // Held back for [VimTextOverlay] below — see
                // [overlayCaretColor].
                cursorColor: vim.overlayCaretColor(widget.cursorColor),
                cursorWidth: vim.overlayCaretWidth,
                undoController: vim.undoController,
                maxLines: null,
                autocorrect: false,
                enableSuggestions: false,
                scrollPadding: kVoyagerFieldScrollPadding,
                scrollPhysics: const VoyagerFieldScrollPhysics(),
                decoration: _codeDecoration,
              ),
            ),
            // Vim alone, unlike the prose fields, which mount this for a
            // snippet session too: this one turns snippets off at the scope
            // above, so there are never tabstop marks here to draw.
            if (vim.session != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: overlayPadding,
                    child: VimTextOverlay(
                      session: vim.session!,
                      controller: widget.controller,
                      focusNode: _focusNode,
                      style: widget.textStyle,
                      strutStyle: strutStyle,
                      accentColor: accent,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return VoyagerScrollView(
          scrollDirection: Axis.horizontal,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: 0,
                    minWidth: constraints.maxWidth,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(_longestLine, style: widget.textStyle),
                  ),
                ),
                // The layers don't clip themselves; this keeps the Vim caret
                // and the selection inside the box.
                ClipRect(child: editor),
              ],
            ),
          ),
        );
      },
    );
  }
}
