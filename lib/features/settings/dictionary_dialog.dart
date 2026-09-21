import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/dictionary_search.dart';
import 'package:voyager/core/spellcheck/flagged_word_rules.dart';
import 'package:voyager/core/spellcheck/word_token.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

/// The app-wide spell-check dictionary: look a word up, add one the checker
/// should accept, fix a typo in one already added, take one back out — or flag
/// one the bundled list has but the user does not want
/// (`FLAGGED_WORDS.md` §7).
///
/// The bundled English list itself is never edited. Removing a word here
/// removes it from the user's own additions; flagging one leaves it in the
/// bundled list and overrides it.
Future<void> showDictionaryDialog(BuildContext context) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => const _DictionaryDialog(),
  );
}

class _DictionaryDialog extends ConsumerStatefulWidget {
  const _DictionaryDialog();

  @override
  ConsumerState<_DictionaryDialog> createState() => _DictionaryDialogState();
}

class _DictionaryDialogState extends ConsumerState<_DictionaryDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// The results list keeps its element — and so its offset — across queries,
  /// so a new search would otherwise open partway down the previous one.
  final _scrollController = ScrollController();

  String _query = '';
  String? _error;

  /// Said after a rename that turned into a removal because the new spelling
  /// was already bundled — otherwise the row would just vanish.
  String? _notice;
  var _saving = false;

  /// The custom word open for renaming, and the error its last save produced.
  String? _editing;
  String? _editError;

  /// The word whose replacement editor is open — a bundled row being flagged,
  /// or a flagged row having its replacement changed — with the error its last
  /// save produced. [_replacementIsNewFlag] is which of the two it is: the
  /// first writes a flag, the second edits one in place.
  String? _replacementOpen;
  var _replacementIsNewFlag = false;
  String? _replacementError;

  /// Memo of the last search, so an unrelated rebuild (a hover, a theme
  /// change, the list scrolling) doesn't re-run it. Rebuilt when the query
  /// changes or when either word set is replaced.
  DictionarySearchResult _result = DictionarySearchResult.empty;
  String? _resultQuery;
  Set<String>? _bundledSeen;
  Set<String>? _customSeen;
  Set<String>? _flaggedSeen;

  /// Complete match list of an earlier, shorter query, and that query. A
  /// longer query can only match a subset of it, so typing on past a word rare
  /// enough to need a full scan of the 65k bundled set narrows that result
  /// instead of scanning again. See [DictionarySearchResult.candidates].
  String? _candidateQuery;
  List<String> _candidates = const [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleQueryChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleQueryChanged);
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    if (_controller.text == _query) return;
    setState(() {
      _query = _controller.text;
      _error = null;
      _notice = null;
    });
    // A different query is a different list: show it from the first match.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// Recomputes [_result] only when something it depends on actually moved.
  /// Called from `build`, where assigning state fields needs no `setState` —
  /// the frame that reads them is already running.
  void _ensureResult(
    Set<String> bundled,
    Set<String> custom,
    Set<String> flagged,
  ) {
    final query = normalizeCustomWord(_query);
    if (_resultQuery == query &&
        identical(_bundledSeen, bundled) &&
        identical(_customSeen, custom) &&
        identical(_flaggedSeen, flagged)) {
      return;
    }
    // The candidates came out of the old bundled set; a new one invalidates
    // them. A changed custom or flagged set doesn't — those only ever narrow
    // which bundled matches are *shown*, never which ones matched.
    if (!identical(_bundledSeen, bundled)) {
      _candidateQuery = null;
      _candidates = const [];
    }
    final reusable =
        _candidateQuery != null && query.startsWith(_candidateQuery!);
    final result = searchDictionary(
      query: query,
      bundled: bundled,
      custom: custom,
      flagged: flagged,
      candidates: reusable ? _candidates : null,
    );
    if (result.candidatesComplete) {
      _candidateQuery = query;
      _candidates = result.candidates;
    }
    _result = result;
    _resultQuery = query;
    _bundledSeen = bundled;
    _customSeen = custom;
    _flaggedSeen = flagged;
  }

  /// The flag map's keys, memoised on the map's identity so [_ensureResult]'s
  /// `identical` check still means "nothing moved".
  Map<String, String?>? _flaggedPairsSeen;
  Set<String> _flaggedKeysMemo = const <String>{};

  Set<String> _flaggedKeys(Map<String, String?> pairs) {
    if (identical(_flaggedPairsSeen, pairs)) return _flaggedKeysMemo;
    _flaggedPairsSeen = pairs;
    _flaggedKeysMemo = pairs.keys.toSet();
    return _flaggedKeysMemo;
  }

  static const _shapeError =
      'A dictionary word is one word: letters, and apostrophes inside it.';

  Future<void> _add(
    Set<String> bundled,
    Set<String> custom,
    Set<String> flagged,
  ) async {
    if (_saving) return;
    final word = normalizeCustomWord(_query);
    if (word.isEmpty) {
      setState(() => _error = 'Type a word to add.');
      return;
    }
    if (!isCustomWordToken(word)) {
      setState(() => _error = _shapeError);
      return;
    }
    final wasFlagged = flagged.contains(word);
    // A second row for a word the bundled list already has would change
    // nothing about spellcheck, and would make removing it later look like it
    // did something it didn't. A *flagged* bundled word is the exception:
    // adding it is how the flag is lifted (allow wins, `FLAGGED_WORDS.md` §7).
    if (!wasFlagged) {
      if (bundled.contains(word)) {
        setState(() => _error = '"$word" is already in the dictionary.');
        return;
      }
      if (custom.contains(word)) {
        setState(() => _error = 'You have already added "$word".');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    final repo = ref.read(settingsRepositoryProvider);
    if (wasFlagged) await repo.unflagWord(word);
    // Bundled and unflagged is the whole result: a custom row for a spelling
    // the bundled list has is the duplicate DICTIONARY.md already rejects.
    if (!bundled.contains(word)) await repo.addCustomWord(word);
    ref.invalidate(customWordsProvider);
    if (wasFlagged) ref.invalidate(flaggedWordsProvider);
    await ref.read(customWordsProvider.future);
    if (wasFlagged) await ref.read(flaggedWordsProvider.future);
    if (!mounted) return;
    // The query stays put: the word the user just typed is now on the list
    // below as their own, which is the confirmation. A flag lifted off a
    // bundled word leaves no row at all, so that one is said out loud.
    setState(() {
      _saving = false;
      _notice = (wasFlagged && bundled.contains(word))
          ? 'No longer flagging "$word" — it is in the dictionary again.'
          : null;
    });
    _focusNode.requestFocus();
  }

  /// Saves the replacement editor open on [word]: a new flag when it was
  /// opened from a bundled row, an in-place edit when from a flagged one.
  /// Empty text means "no replacement", which keeps the flag either way.
  Future<void> _saveReplacement(
    String word,
    String rawTo,
    Map<String, String?> flagged,
  ) async {
    final to = normalizeCustomWord(rawTo);
    final isNew = _replacementIsNewFlag;
    if (isNew) {
      final wordError = validateFlagWord(word, flagged);
      if (wordError != null) {
        setState(() => _replacementError = wordError);
        return;
      }
    }
    // The checker's own set, which already has every flag subtracted — the
    // one answer to "is this replacement a word the app accepts?".
    final known = ref.read(voyagerSpellCheckServiceProvider).knownWords;
    final error = validateFlagReplacement(
      word: word,
      replacement: to,
      known: known,
      flagged: flagged,
    );
    if (error != null) {
      setState(() => _replacementError = error);
      return;
    }

    final repo = ref.read(settingsRepositoryProvider);
    if (isNew) {
      await repo.flagWord(word, replacement: to.isEmpty ? null : to);
    } else {
      await repo.setFlaggedReplacement(word, to.isEmpty ? null : to);
    }
    ref.invalidate(customWordsProvider);
    ref.invalidate(flaggedWordsProvider);
    await ref.read(flaggedWordsProvider.future);
    if (!mounted) return;
    setState(() {
      _replacementOpen = null;
      _replacementError = null;
      _notice = isNew ? 'Flagging "$word".' : null;
    });
  }

  Future<void> _unflag(String word) async {
    setState(() {
      _notice = null;
      if (_replacementOpen == word) _replacementOpen = null;
    });
    await ref.read(settingsRepositoryProvider).unflagWord(word);
    ref.invalidate(flaggedWordsProvider);
  }

  void _openReplacementEditor(String word, {required bool isNewFlag}) {
    setState(() {
      _replacementOpen = word;
      _replacementIsNewFlag = isNewFlag;
      _replacementError = null;
      _editing = null;
    });
  }

  Future<void> _saveRename(
    String from,
    String rawTo,
    Set<String> bundled,
    Set<String> custom,
  ) async {
    final to = normalizeCustomWord(rawTo);
    if (to == from) {
      setState(() {
        _editing = null;
        _editError = null;
      });
      return;
    }
    if (to.isEmpty) {
      setState(() => _editError = 'Type a word.');
      return;
    }
    if (!isCustomWordToken(to)) {
      setState(() => _editError = _shapeError);
      return;
    }
    if (custom.contains(to)) {
      setState(() => _editError = 'You have already added "$to".');
      return;
    }

    final repo = ref.read(settingsRepositoryProvider);
    // Renaming onto a bundled word is just the removal: the new spelling is
    // already accepted, so a custom row for it would be dead weight.
    final ontoBundled = bundled.contains(to);
    if (ontoBundled) {
      await repo.removeCustomWord(from);
    } else {
      await repo.renameCustomWord(from, to);
    }
    ref.invalidate(customWordsProvider);
    await ref.read(customWordsProvider.future);
    if (!mounted) return;
    setState(() {
      _editing = null;
      _editError = null;
      _notice = ontoBundled
          ? 'Removed "$from" — "$to" is already in the dictionary.'
          : null;
    });
  }

  Future<void> _remove(String word) async {
    setState(() {
      _notice = null;
      if (_editing == word) _editing = null;
    });
    await ref.read(settingsRepositoryProvider).removeCustomWord(word);
    ref.invalidate(customWordsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bundledAsync = ref.watch(dictionaryProvider);
    final customAsync = ref.watch(customWordsProvider);
    final flaggedAsync = ref.watch(flaggedWordsProvider);
    final bundled = bundledAsync.valueOrNull ?? const <String>{};
    final custom = customAsync.valueOrNull ?? const <String>{};
    final flaggedPairs = flaggedAsync.valueOrNull ?? const <String, String?>{};
    // Rebuilt only when the map is replaced, so the search memo's identity
    // check below still holds.
    final flagged = _flaggedKeys(flaggedPairs);
    // All three sets are awaited by the shell's warmup, so this is a
    // first-launch sliver rather than a state the user normally sees. Adding
    // is held back through it: without the bundled list there is no way to
    // tell a word that needs adding from one that is already known.
    final ready =
        bundledAsync.hasValue && customAsync.hasValue && flaggedAsync.hasValue;
    _ensureResult(bundled, custom, flagged);

    final word = normalizeCustomWord(_query);
    // A flagged word is not known — adding it is how the flag comes off.
    final known =
        !flagged.contains(word) &&
        (bundled.contains(word) || custom.contains(word));
    final canAdd = ready && !_saving && word.isNotEmpty && !known;

    return AlertDialog(
      title: const Text('Dictionary'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Words you add here are accepted by the spell checker everywhere '
              'in the app, and words you flag are marked everywhere. Search to '
              'see whether a word is already known.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: LabeledTextField(
                      label: '',
                      showLabel: false,
                      hintText: 'Search or add a word',
                      controller: _controller,
                      focusNode: _focusNode,
                      dense: true,
                      // Typing a word that isn't in the dictionary yet is the
                      // whole point of this field, so it must not be a fight
                      // with squiggles or an expanding snippet. (Single-line
                      // fields are already exempt from spellcheck.)
                      snippetsAllowed: false,
                    autocorrectAllowed: false,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 8,
                      ),
                      onSubmitted: (_) => _add(bundled, custom, flagged),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    dense: true,
                    onPressed: canAdd
                        ? () => _add(bundled, custom, flagged)
                        : null,
                    icon: const Icon(PhosphorIconsRegular.plus),
                    tooltip: known && word.isNotEmpty
                        ? '"$word" is already known'
                        : 'Add word',
                  ),
                ],
              ),
            ),
            if (_error != null || _notice != null) ...[
              const SizedBox(height: 8),
              Text(
                _error ?? _notice!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _error != null
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Flexible so the list gives up height in a short window rather
            // than pushing the dialog past its bottom edge.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: !ready
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : _buildResults(theme, bundled, custom, flaggedPairs),
              ),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Done',
        ),
      ],
    );
  }

  Widget _buildResults(
    ThemeData theme,
    Set<String> bundled,
    Set<String> custom,
    Map<String, String?> flaggedPairs,
  ) {
    final result = _result;
    final customCount = result.custom.length;
    final flaggedCount = result.flagged.length;
    final bundledCount = result.bundled.length;
    if (customCount == 0 && flaggedCount == 0 && bundledCount == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          _query.trim().isEmpty
              ? "You haven't added any extra words for the checker to accept, "
                    'or flagged any for it to mark. Search the dictionary or '
                    'type a word to add it.'
              : 'No matches.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // One flat builder over all three groups: the bundled one can be a hundred
    // rows, and only the handful on screen should ever be built.
    final hintRows = result.truncated ? 1 : 0;
    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      itemCount: customCount + flaggedCount + bundledCount + hintRows,
      itemBuilder: (context, index) {
        if (index < customCount) {
          final word = result.custom[index];
          if (word == _editing) {
            return _WordEditor(
              // Keyed on the word so opening a different row builds a fresh
              // controller seeded with its text, not the previous row's.
              key: ValueKey('edit-$word'),
              word: word,
              error: _editError,
              onSave: (text) => _saveRename(word, text, bundled, custom),
              onCancel: () => setState(() {
                _editing = null;
                _editError = null;
              }),
            );
          }
          return _CustomWordRow(
            word: word,
            onEdit: () => setState(() {
              _editing = word;
              _editError = null;
            }),
            onRemove: () => _remove(word),
          );
        }
        index -= customCount;
        if (index < flaggedCount) {
          final word = result.flagged[index];
          if (word == _replacementOpen) {
            return _buildReplacementEditor(word, flaggedPairs);
          }
          return _FlaggedWordRow(
            word: word,
            replacement: flaggedPairs[word],
            onEdit: () => _openReplacementEditor(word, isNewFlag: false),
            onUnflag: () => _unflag(word),
          );
        }
        index -= flaggedCount;
        if (index < bundledCount) {
          final word = result.bundled[index];
          if (word == _replacementOpen) {
            return _buildReplacementEditor(word, flaggedPairs);
          }
          return _BundledWordRow(
            word: word,
            onFlag: () => _openReplacementEditor(word, isNewFlag: true),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
          child: Text(
            'Showing the first $dictionarySearchLimit matches — '
            'type more to narrow.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }

  Widget _buildReplacementEditor(
    String word,
    Map<String, String?> flaggedPairs,
  ) {
    return _WordEditor(
      // Keyed on what is being edited as well as on the word: flagging a
      // bundled row and editing a flagged one seed the field differently.
      key: ValueKey('replace-$word-$_replacementIsNewFlag'),
      word: flaggedPairs[word] ?? '',
      label: _replacementIsNewFlag
          ? 'Flag "$word" — always replace with'
          : 'Replace "$word" with',
      hintText: 'Optional',
      saveTooltip: _replacementIsNewFlag ? 'Flag word' : 'Save replacement',
      error: _replacementError,
      onSave: (text) => _saveReplacement(word, text, flaggedPairs),
      onCancel: () => setState(() {
        _replacementOpen = null;
        _replacementError = null;
      }),
    );
  }
}

/// One of the user's own words: renameable, removable.
class _CustomWordRow extends StatelessWidget {
  const _CustomWordRow({
    required this.word,
    required this.onEdit,
    required this.onRemove,
  });

  final String word;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4),
      // The whole row opens the editor, so a word added with a typo in it is
      // one click from being fixed; the pencil is there to say so.
      onTap: onEdit,
      title: Text(word, style: theme.textTheme.bodyMedium),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Rename word',
            icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Remove word',
            icon: Icon(
              PhosphorIconsRegular.trash,
              size: 18,
              color: theme.colorScheme.error,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// A word from the bundled list: an answer to "is this already known?".
///
/// Still not renameable or removable — the bundled list isn't editable — but
/// it can be *flagged*, which overrides it without touching the asset
/// (`FLAGGED_WORDS.md` §7).
class _BundledWordRow extends StatelessWidget {
  const _BundledWordRow({required this.word, required this.onFlag});

  final String word;
  final VoidCallback onFlag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurfaceVariant;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4),
      title: Text(
        word,
        style: theme.textTheme.bodyMedium?.copyWith(color: faint),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'In the built-in dictionary',
            child: Icon(PhosphorIconsRegular.bookOpen, size: 16, color: faint),
          ),
          IconButton(
            tooltip: 'Flag as misspelling',
            icon: const Icon(PhosphorIconsRegular.flag, size: 16),
            onPressed: onFlag,
          ),
        ],
      ),
    );
  }
}

/// One of the user's flags: the word, the replacement if it has one, and the
/// two things that can happen to it — change the replacement, or stop
/// flagging (`FLAGGED_WORDS.md` §7).
class _FlaggedWordRow extends StatelessWidget {
  const _FlaggedWordRow({
    required this.word,
    required this.replacement,
    required this.onEdit,
    required this.onUnflag,
  });

  final String word;
  final String? replacement;
  final VoidCallback onEdit;
  final VoidCallback onUnflag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurfaceVariant;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4),
      // Same affordance as a custom row: the whole row opens the editor.
      onTap: onEdit,
      title: Row(
        children: [
          Flexible(
            child: Text(
              // The arrow is the rule, so it is only drawn when there is one.
              replacement == null ? word : '$word → $replacement',
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Flagged',
            style: theme.textTheme.labelSmall?.copyWith(color: faint),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit replacement',
            icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Stop flagging',
            icon: Icon(
              PhosphorIconsRegular.flag,
              size: 18,
              color: theme.colorScheme.error,
            ),
            onPressed: onUnflag,
          ),
        ],
      ),
    );
  }
}

/// One row's inline single-field editor: a custom word being renamed, or a
/// flag's replacement being written (`FLAGGED_WORDS.md` §7 — flagging from
/// search needs no second dialog).
///
/// Owns its controller and focus so the list around it can rebuild — a sync
/// landing, another word being removed — without disturbing the text being
/// typed. Enter commits, as everywhere else a short field is edited; backing
/// out is the ✕ rather than Escape, which belongs to Vim once a session is
/// live in the field.
class _WordEditor extends StatefulWidget {
  const _WordEditor({
    super.key,
    required this.word,
    required this.error,
    required this.onSave,
    required this.onCancel,
    this.label,
    this.hintText,
    this.saveTooltip = 'Save word',
  });

  /// What the field starts with. Empty is legal for a replacement editor,
  /// which is opened on a flag that has none.
  final String word;
  final String? error;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  /// Shown above the field when the row needs saying which word is being
  /// edited — a replacement editor sits on a row whose own text it isn't.
  final String? label;
  final String? hintText;

  final String saveTooltip;

  @override
  State<_WordEditor> createState() => _WordEditorState();
}

class _WordEditorState extends State<_WordEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.word,
  )..selection = TextSelection(
    baseOffset: 0,
    extentOffset: widget.word.length,
  );
  final _focusNode = FocusNode();

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      // Six, not four: the field inside is 28px tall and the [ListTile] this
      // row replaces is 40, so 4px of padding left the list jumping 4px
      // shorter the moment a word was opened for renaming.
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.label != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Text(
                widget.label!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LabeledTextField(
                    label: '',
                    showLabel: false,
                    hintText: widget.hintText,
                    controller: _controller,
                    focusNode: _focusNode,
                    dense: true,
                    snippetsAllowed: false,
                    autocorrectAllowed: false,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 8,
                    ),
                    onSubmitted: widget.onSave,
                  ),
                ),
                const SizedBox(width: 8),
                GlassButton(
                  dense: true,
                  onPressed: widget.onCancel,
                  icon: const Icon(PhosphorIconsRegular.x),
                  tooltip: 'Cancel',
                ),
                const SizedBox(width: 4),
                GlassButton(
                  dense: true,
                  onPressed: () => widget.onSave(_controller.text),
                  icon: const Icon(PhosphorIconsRegular.check),
                  tooltip: widget.saveTooltip,
                ),
              ],
            ),
          ),
          if (widget.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
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
    return CtrlEnterToSubmitScope(
      onSubmit: () => widget.onSave(_controller.text),
      child: row,
    );
  }
}
