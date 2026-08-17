import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/dictionary_search.dart';
import 'package:voyager/core/spellcheck/word_token.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';

/// The app-wide spell-check dictionary: look a word up, add one the checker
/// should accept, fix a typo in one already added, or take one back out.
///
/// The bundled English list is searchable but read-only — removing a word here
/// removes it from the user's own additions, so a spelling the bundled list
/// already knows stays accepted either way.
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

  /// Memo of the last search, so an unrelated rebuild (a hover, a theme
  /// change, the list scrolling) doesn't re-run it. Rebuilt when the query
  /// changes or when either word set is replaced.
  DictionarySearchResult _result = DictionarySearchResult.empty;
  String? _resultQuery;
  Set<String>? _bundledSeen;
  Set<String>? _customSeen;

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
  void _ensureResult(Set<String> bundled, Set<String> custom) {
    final query = normalizeCustomWord(_query);
    if (_resultQuery == query &&
        identical(_bundledSeen, bundled) &&
        identical(_customSeen, custom)) {
      return;
    }
    // The candidates came out of the old bundled set; a new one invalidates
    // them. A changed *custom* set doesn't — they only ever hold bundled words.
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
  }

  static const _shapeError =
      'A dictionary word is one word: letters, and apostrophes inside it.';

  Future<void> _add(Set<String> bundled, Set<String> custom) async {
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
    // A second row for a word the bundled list already has would change
    // nothing about spellcheck, and would make removing it later look like it
    // did something it didn't.
    if (bundled.contains(word)) {
      setState(() => _error = '"$word" is already in the dictionary.');
      return;
    }
    if (custom.contains(word)) {
      setState(() => _error = 'You have already added "$word".');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    await ref.read(settingsRepositoryProvider).addCustomWord(word);
    ref.invalidate(customWordsProvider);
    await ref.read(customWordsProvider.future);
    if (!mounted) return;
    // The query stays put: the word the user just typed is now on the list
    // below as their own, which is the confirmation.
    setState(() => _saving = false);
    _focusNode.requestFocus();
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
    final bundled = bundledAsync.valueOrNull ?? const <String>{};
    final custom = customAsync.valueOrNull ?? const <String>{};
    // Both sets are awaited by the shell's warmup, so this is a first-launch
    // sliver rather than a state the user normally sees. Adding is held back
    // through it: without the bundled list there is no way to tell a word that
    // needs adding from one that is already known.
    final ready = bundledAsync.hasValue && customAsync.hasValue;
    _ensureResult(bundled, custom);

    final word = normalizeCustomWord(_query);
    final known = bundled.contains(word) || custom.contains(word);
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
              'in the app. Search to see whether a word is already known.',
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
                      borderRadius: 12,
                      // Typing a word that isn't in the dictionary yet is the
                      // whole point of this field, so it must not be a fight
                      // with squiggles or an expanding snippet. (Single-line
                      // fields are already exempt from spellcheck.)
                      snippetsAllowed: false,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 8,
                      ),
                      onSubmitted: (_) => _add(bundled, custom),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    dense: true,
                    onPressed: canAdd ? () => _add(bundled, custom) : null,
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
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: !ready
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _buildResults(theme, bundled, custom),
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
  ) {
    final result = _result;
    final customCount = result.custom.length;
    final bundledCount = result.bundled.length;
    if (customCount == 0 && bundledCount == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          _query.trim().isEmpty
              ? "You haven't added any extra words yet. Search the dictionary "
                    'or type a word to add it.'
              : 'No matches.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // One flat builder over both halves: the bundled half can be a hundred
    // rows, and only the handful on screen should ever be built.
    final hintRows = result.truncated ? 1 : 0;
    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      itemCount: customCount + bundledCount + hintRows,
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
        if (index < customCount + bundledCount) {
          return _BundledWordRow(word: result.bundled[index - customCount]);
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

/// A word from the bundled list: an answer to "is this already known?", and
/// nothing to act on. It can't be removed — the bundled list isn't editable,
/// and there is no blocklist.
class _BundledWordRow extends StatelessWidget {
  const _BundledWordRow({required this.word});

  final String word;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.colorScheme.onSurfaceVariant;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4, right: 12),
      title: Text(word, style: theme.textTheme.bodyMedium?.copyWith(color: faint)),
      trailing: Tooltip(
        message: 'In the built-in dictionary',
        child: Icon(PhosphorIconsRegular.bookOpen, size: 16, color: faint),
      ),
    );
  }
}

/// One custom word while its spelling is being rewritten.
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
  });

  final String word;
  final String? error;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  @override
  State<_WordEditor> createState() => _WordEditorState();
}

class _WordEditorState extends State<_WordEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.word,
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LabeledTextField(
                    label: '',
                    showLabel: false,
                    controller: _controller,
                    focusNode: _focusNode,
                    dense: true,
                    borderRadius: 12,
                    snippetsAllowed: false,
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
                  tooltip: 'Save word',
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
  }
}
