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

/// The gutter shows only line numbers here — no static-analysis issues or
/// foldable blocks are ever produced for a plain display/paste code box — so
/// the issue/folding columns are turned off and the numbers column is
/// narrowed, leaving more width for the code itself.
const _codeGutterStyle = GutterStyle(
  width: 36,
  margin: 6,
  showErrors: false,
  showFoldingHandles: false,
);

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
          child: CodeTheme(
            data: CodeThemeData(styles: codeTheme),
            child: SingleChildScrollView(
              child: CodeField(
                controller: widget.controller,
                textStyle: const TextStyle(fontFamily: 'monospace'),
                gutterStyle: _codeGutterStyle,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.3),
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
class LeetCodeCodeView extends StatelessWidget {
  const LeetCodeCodeView({super.key, required this.code, required this.language});

  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = CodeController(
      text: code,
      language: _modeForLanguage(language),
    );
    final codeTheme = _themeFor(theme.brightness);
    final background = codeTheme['root']?.backgroundColor ?? theme.colorScheme.surface;
    return CodeTheme(
      data: CodeThemeData(styles: codeTheme),
      child: CodeField(
        controller: controller,
        readOnly: true,
        textStyle: const TextStyle(fontFamily: 'monospace'),
        gutterStyle: _codeGutterStyle,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }
}
