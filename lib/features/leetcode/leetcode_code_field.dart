import 'package:flutter/material.dart';
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
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/widgets/selector_pill.dart';

Mode _modeForLanguage(String language) => switch (language) {
  'java' => lang_java.java,
  'cpp' => lang_cpp.cpp,
  'javascript' => lang_javascript.javascript,
  'typescript' => lang_typescript.typescript,
  'go' => lang_go.go,
  'rust' => lang_rust.rust,
  'csharp' => lang_cs.cs,
  _ => lang_python.python,
};

Map<String, TextStyle> _themeFor(Brightness brightness) =>
    brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme;

/// Size and leading are pinned rather than inherited. Left unset, the two
/// columns resolve them from different theme slots — the line numbers'
/// [TextField] falls back to `bodyLarge`, while [CodeField] seeds its own
/// default from `titleMedium` — so their alignment would silently depend on
/// those slots staying identical, which they are today only by coincidence
/// of the Material 3 scale.
final _codeTextStyle =
    AppFonts.style(fontSize: 16).copyWith(fontFamily: AppFonts.monoFamily);
const _lineNumberColumnWidth = 34.0;
const _lineNumberGap = 8.0;

/// Line numbers rendered as their own borderless [TextField], configured
/// identically (padding, decoration, text style) to [CodeField]'s internal
/// one, instead of using [GutterStyle]'s built-in numbers column.
///
/// [GutterStyle] lays its numbers out in a `Table` of single-line cells,
/// entirely separate from the code's own multi-line paragraph inside
/// [CodeField]'s `TextField`. The two are supposed to produce identical
/// per-line heights for a shared [TextStyle], but in practice that depends on
/// the exact font the platform resolves — verified to match in a test
/// harness but to visibly drift on a real Windows build. Using the same
/// widget with the same configuration for both columns removes the
/// dependency on that coincidence: whatever a given platform/font does to
/// line height, it does identically to both, since they run the exact same
/// code path in lockstep.
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
  @override
  void initState() {
    super.initState();
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeTheme = _themeFor(theme.brightness);
    final background = codeTheme['root']?.backgroundColor ?? theme.colorScheme.surface;
    final lineNumberColor = (codeTheme['root']?.color ?? theme.colorScheme.onSurface)
        .withValues(alpha: 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 32,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: leetCodeCodeLanguages.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final lang = leetCodeCodeLanguages[index];
              return SelectorPill(
                dense: true,
                label: labelForLeetCodeLanguage(lang),
                isActive: lang == widget.language,
                onTap: () => widget.onLanguageChanged(lang),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 160, maxHeight: 320),
          child: Container(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
            ),
            child: CodeTheme(
              data: CodeThemeData(styles: codeTheme),
              child: Theme(
                data: theme.copyWith(inputDecorationTheme: const InputDecorationTheme()),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _LineNumbers(source: widget.controller, color: lineNumberColor),
                        const SizedBox(width: _lineNumberGap),
                        Expanded(
                          child: CodeField(
                            controller: widget.controller,
                            textStyle: _codeTextStyle,
                            gutterStyle: GutterStyle.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Read-only syntax-highlighted code display, used in the Detail View.
class LeetCodeCodeView extends StatefulWidget {
  const LeetCodeCodeView({super.key, required this.code, required this.language});

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
    _controller = CodeController(
      text: widget.code,
      language: _modeForLanguage(widget.language),
    );
  }

  @override
  void didUpdateWidget(covariant LeetCodeCodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code || oldWidget.language != widget.language) {
      _controller.dispose();
      _controller = CodeController(
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
    final theme = Theme.of(context);
    final codeTheme = _themeFor(theme.brightness);
    final background = codeTheme['root']?.backgroundColor ?? theme.colorScheme.surface;
    final lineNumberColor = (codeTheme['root']?.color ?? theme.colorScheme.onSurface)
        .withValues(alpha: 0.5);
    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: CodeTheme(
        data: CodeThemeData(styles: codeTheme),
        child: Theme(
          data: theme.copyWith(inputDecorationTheme: const InputDecorationTheme()),
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LineNumbers(source: _controller, color: lineNumberColor),
                const SizedBox(width: _lineNumberGap),
                Expanded(
                  child: CodeField(
                    controller: _controller,
                    readOnly: true,
                    textStyle: _codeTextStyle,
                    gutterStyle: GutterStyle.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
