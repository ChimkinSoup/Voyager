import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/autocorrect_session.dart';
import 'package:voyager/core/spellcheck/flagged_word_rules.dart';
import 'package:voyager/core/spellcheck/spell_check_suggestions.dart';
import 'package:voyager/core/spellcheck/word_token.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';

/// Wide enough for the word, the replacement field and the two buttons to sit
/// on one row each without the popover growing into a dialog.
const double _panelWidth = 420.0;

/// How the flag popover was closed.
enum _FlagOutcome {
  /// The flag was saved and there was nothing more to ask, or the offer was
  /// declined. Either way the flag stands.
  flagged,

  /// The flag was saved with a replacement, and the user asked for this
  /// occurrence to be rewritten too.
  replaceThisOne,
}

/// Opens "Flag as misspelling…" over [anchor] for the word at [range]
/// (`FLAGGED_WORDS.md` §6).
///
/// The one-word cousin of `showQuickAddSnippet`, and opened on the same terms:
/// the context menu that launched it is torn down on the way in, so [context]
/// must belong to the *field* — that is what the popover route, the toast and
/// the replacement write all outlive the menu against.
///
/// Saving the flag is the whole success. If a replacement was stored the
/// popover then offers to rewrite the occurrence they clicked; declining, or
/// dismissing, leaves the flag exactly where it is.
Future<void> showFlagWordPopover({
  required BuildContext context,
  required Offset anchor,
  required String word,
  required TextRange range,
  AutocorrectSession? session,
  FocusNode? restoreFocus,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);

  final outcome = await showContextualPopoverAt<_FlagOutcome>(
    context: context,
    targetRect: Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
    width: _panelWidth,
    builder: (_) => _FlagWordPanel(word: word, canReplaceHere: session != null),
  );

  restoreFocus?.requestFocus();
  if (outcome != _FlagOutcome.replaceThisOne || session == null) return;

  // The field has to actually hold the keyboard again before the write:
  // `VimTextScope` resolves no [EditableTextState] while its scope is
  // unfocused — the popover route had it — and the session drops a write it
  // cannot route through the field's own edit pipeline. [FocusNode
  // .requestFocus] applies on a microtask, so one turn of the loop is enough.
  await Future<void>.delayed(Duration.zero);

  // Read back off the session rather than carried through the route: the flag
  // has landed by now, and the stored pair is the one thing that says what
  // this occurrence should become.
  final replacement = session.replacementFor(normalizeCustomWord(word));
  if (replacement == null) return;
  if (!session.applyReplacementAt(range, replacement)) return;
  showVoyagerToastIn(
    overlay,
    message: 'Replaced with "$replacement"',
    icon: PhosphorIconsRegular.checkCircle,
    dwell: const Duration(seconds: 3),
  );
}

class _FlagWordPanel extends ConsumerStatefulWidget {
  const _FlagWordPanel({required this.word, required this.canReplaceHere});

  /// The word as it was clicked, case and all. The row is keyed on its
  /// lowercase form — flagging `Neve` flags `neve`.
  final String word;

  /// Whether there is a session to rewrite the clicked occurrence through.
  /// Without one the second question has no answer worth offering.
  final bool canReplaceHere;

  @override
  ConsumerState<_FlagWordPanel> createState() => _FlagWordPanelState();
}

class _FlagWordPanelState extends ConsumerState<_FlagWordPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  String? _error;
  var _saving = false;

  /// Set once the flag is written and a replacement went with it: the panel
  /// then shows the second question instead of the form.
  String? _savedReplacement;

  /// Filled once, from the suggestions for this word as if it were already
  /// unknown. Not recomputed on rebuild — it is a prefill, not a live list.
  var _prefilled = false;

  String get _word => normalizeCustomWord(widget.word);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Prefills the replacement with the first suggestion for this word once it
  /// is treated as unknown (`FLAGGED_WORDS.md` §6).
  ///
  /// The word has to come out of the set first: it is in the dictionary today,
  /// so the generator would otherwise answer with the word itself.
  void _prefill(Set<String> known) {
    if (_prefilled) return;
    _prefilled = true;
    if (known.isEmpty) return;
    final suggestions = generateSuggestions(
      _word,
      known.difference({_word}),
      maxResults: 1,
    );
    if (suggestions.isEmpty) return;
    _controller.text = suggestions.first;
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: suggestions.first.length,
    );
  }

  Future<void> _flag(Set<String> known, Map<String, String?> flagged) async {
    if (_saving) return;
    final word = _word;
    final wordError = validateFlagWord(word, flagged);
    if (wordError != null) {
      setState(() => _error = wordError);
      return;
    }
    final replacement = normalizeCustomWord(_controller.text);
    final replacementError = validateFlagReplacement(
      word: word,
      replacement: replacement,
      known: known,
      flagged: flagged,
    );
    if (replacementError != null) {
      setState(() => _error = replacementError);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(settingsRepositoryProvider);
    final bundled =
        ref.read(dictionaryProvider).valueOrNull ?? const <String>{};
    if (!bundled.contains(word) && replacement.isEmpty) {
      // A word the bundled list doesn't have is known only because the user
      // added it, and removing that row already makes it unknown — a flag row
      // would be a second way to say the same thing (`FLAGGED_WORDS.md` §4).
      // A replacement is the one thing only a flag row can hold, so that case
      // takes the branch below, which tombstones the custom row itself.
      await repo.removeCustomWord(word);
    } else {
      await repo.flagWord(
        word,
        replacement: replacement.isEmpty ? null : replacement,
      );
    }
    // Awaited, not merely invalidated: the second question is asked about a
    // flag the checker has to have seen already (§9).
    ref.invalidate(customWordsProvider);
    ref.invalidate(flaggedWordsProvider);
    await ref.read(customWordsProvider.future);
    await ref.read(flaggedWordsProvider.future);
    if (!mounted) return;

    if (replacement.isEmpty || !widget.canReplaceHere) {
      Navigator.of(context).pop(_FlagOutcome.flagged);
      return;
    }
    setState(() {
      _saving = false;
      _savedReplacement = replacement;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = ref.watch(voyagerSpellCheckServiceProvider);
    // Watched so the form never validates against a half-loaded set. Both are
    // warmed by the shell, so this is a first-launch sliver.
    final bundledAsync = ref.watch(dictionaryProvider);
    final flaggedAsync = ref.watch(flaggedWordsProvider);
    if (!bundledAsync.hasValue || !flaggedAsync.hasValue) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final known = service.knownWords;
    final flagged = flaggedAsync.requireValue;
    _prefill(known);

    final saved = _savedReplacement;
    final popover = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.word,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            saved == null
                ? 'Flagging marks this word everywhere, even though the '
                      'built-in dictionary has it.'
                : 'Flagged. Replace this one with "$saved"?',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (saved == null)
            ..._buildForm(theme, known, flagged)
          else
            _buildOffer(),
        ],
      ),
    );
    // Flag only: once the flag is saved, the offer's two answers are a choice
    // rather than one affirmative action.
    return CtrlEnterToSubmitScope(
      onSubmit: saved == null ? () => _flag(known, flagged) : null,
      child: popover,
    );
  }

  List<Widget> _buildForm(
    ThemeData theme,
    Set<String> known,
    Map<String, String?> flagged,
  ) {
    return [
      LabeledTextField(
        label: 'Always replace with',
        hintText: 'Optional',
        controller: _controller,
        focusNode: _focusNode,
        dense: true,
        borderRadius: 12,
        // This box exists to hold a word the checker may not like the look of
        // next to the one being flagged.
        snippetsAllowed: false,
        autocorrectAllowed: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 12,
        ),
        onSubmitted: (_) => _flag(known, flagged),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 4),
          child: Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GlassButton(
            dense: true,
            onPressed: () => Navigator.of(context).pop(),
            label: 'Cancel',
          ),
          const SizedBox(width: 8),
          GlassButton(
            dense: true,
            enabled: !_saving,
            onPressed: () => _flag(known, flagged),
            icon: const Icon(PhosphorIconsRegular.flag),
            label: 'Flag',
          ),
        ],
      ),
    ];
  }

  Widget _buildOffer() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        GlassButton(
          dense: true,
          // Dismiss and Escape mean this too: the flag is already saved.
          onPressed: () => Navigator.of(context).pop(_FlagOutcome.flagged),
          label: 'Leave it',
        ),
        const SizedBox(width: 8),
        GlassButton(
          dense: true,
          onPressed: () =>
              Navigator.of(context).pop(_FlagOutcome.replaceThisOne),
          icon: const Icon(PhosphorIconsRegular.arrowsClockwise),
          label: 'Replace this one',
        ),
      ],
    );
  }
}
