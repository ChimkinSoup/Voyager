import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/domain/models/snippet.dart';

/// The values a [SnippetEditor] hands back on save.
class SnippetDraft {
  const SnippetDraft({
    required this.trigger,
    required this.replacement,
    required this.autoExpand,
    required this.wordBoundary,
  });

  final String trigger;
  final String replacement;
  final bool autoExpand;
  final bool wordBoundary;
}

/// One snippet's row while it is being written.
///
/// Shared by the two places a snippet can be created: the row editor in the
/// settings list (`showSnippetsDialog`) and the right-click quick-add popover
/// (`showQuickAddSnippet`), so the form is written once and both flows look
/// and validate the same.
///
/// Owns its own controllers so the list around it can rebuild without
/// disturbing the text being typed — same shape as `_QuoteEditor`.
class SnippetEditor extends StatefulWidget {
  const SnippetEditor({
    super.key,
    required this.original,
    required this.error,
    required this.onSave,
    required this.onCancel,
    this.initialTrigger,
    this.focusReplacement = false,
    this.showPlaceholderWarning = true,
    this.card = true,
  });

  /// Null while a new snippet is being written.
  final Snippet? original;
  final String? error;
  final ValueChanged<SnippetDraft> onSave;
  final VoidCallback onCancel;

  /// Seeds the trigger box of a *new* snippet — the word or selection the
  /// quick-add flow was opened on. Ignored when [original] is set, which
  /// carries a trigger of its own.
  final String? initialTrigger;

  /// Puts the initial focus on Replacement rather than Trigger, for the
  /// quick-add flow where the trigger arrives already filled in.
  final bool focusReplacement;

  /// Whether to warn that `${…}` placeholders are inserted literally. Off in
  /// the quick-add popover, which stays short.
  final bool showPlaceholderWarning;

  /// Whether to draw the [Card] the settings list separates its rows with.
  /// Off in the quick-add popover, which is already a surface of its own.
  final bool card;

  @override
  State<SnippetEditor> createState() => _SnippetEditorState();
}

class _SnippetEditorState extends State<SnippetEditor> {
  late final TextEditingController _trigger = TextEditingController(
    text: widget.original?.trigger ?? widget.initialTrigger ?? '',
  );
  late final TextEditingController _replacement = TextEditingController(
    text: widget.original?.replacement ?? '',
  );
  final _triggerFocus = FocusNode();
  final _replacementFocus = FocusNode();

  late bool _autoExpand = widget.original?.autoExpand ?? false;
  late bool _wordBoundary = widget.original?.wordBoundary ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (widget.focusReplacement ? _replacementFocus : _triggerFocus)
          .requestFocus();
    });
  }

  @override
  void dispose() {
    _trigger.dispose();
    _replacement.dispose();
    _triggerFocus.dispose();
    _replacementFocus.dispose();
    super.dispose();
  }

  void _save() {
    widget.onSave(
      SnippetDraft(
        trigger: _trigger.text,
        replacement: _replacement.text,
        autoExpand: _autoExpand,
        wordBoundary: _wordBoundary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholders =
        widget.showPlaceholderWarning &&
        snippetUsesPlaceholders(_replacement.text);
    final body = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 150,
                  child: LabeledTextField(
                    label: 'Trigger',
                    controller: _trigger,
                    focusNode: _triggerFocus,
                    dense: true,
                    borderRadius: 12,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    // The one field in the app that must never expand a
                    // snippet — see [showSnippetsDialog].
                    snippetsAllowed: false,
                    onSubmitted: (_) => _save(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LabeledTextField(
                    label: 'Replacement',
                    controller: _replacement,
                    focusNode: _replacementFocus,
                    dense: true,
                    borderRadius: 12,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    snippetsAllowed: false,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _save(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              VoyagerCheckbox(
                value: _autoExpand,
                // No confetti in settings: the burst is the To-Do list's
                // "you finished something", and a snippet option is a
                // preference being set, not an accomplishment.
                celebrateOnComplete: false,
                onChanged: (v) => setState(() => _autoExpand = v),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Expand automatically',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 16),
              VoyagerCheckbox(
                value: _wordBoundary,
                celebrateOnComplete: false,
                onChanged: (v) => setState(() => _wordBoundary = v),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Only at word boundaries',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const Spacer(),
              GlassButton(
                dense: true,
                onPressed: widget.onCancel,
                icon: const Icon(PhosphorIconsRegular.x),
                tooltip: 'Cancel',
              ),
              const SizedBox(width: 4),
              GlassButton(
                dense: true,
                onPressed: _save,
                icon: const Icon(PhosphorIconsRegular.check),
                tooltip: 'Save snippet',
              ),
            ],
          ),
          if (placeholders)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                r'${…} placeholders are not supported yet — that text will '
                'be inserted literally.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (widget.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Text(
                widget.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
    if (!widget.card) return body;
    // The settings list draws each row on its own card; the quick-add popover
    // is already a surface, so it takes the bare form.
    return Card(margin: const EdgeInsets.symmetric(vertical: 6), child: body);
  }
}

/// Rejects the two things that would make a snippet unusable rather than
/// merely odd: nothing to type, and a trigger some other snippet already
/// owns. Everything else — an empty replacement, a `$` with no digits — is
/// legal, just unhelpful.
///
/// [id] is the record being edited, so a snippet never collides with itself;
/// null while a new one is being written.
String? validateSnippetTrigger(
  List<Snippet> existing,
  String? id,
  String trigger,
) {
  if (trigger.isEmpty) return 'Give the snippet a trigger.';
  for (final snippet in existing) {
    if (snippet.id != id && snippet.trigger == trigger) {
      return 'Another snippet already uses "$trigger".';
    }
  }
  return null;
}
