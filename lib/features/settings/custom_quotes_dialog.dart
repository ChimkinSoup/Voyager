import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// Adds to and removes from the pool of quotes a new journal entry draws from.
///
/// The bundled quotes are read-only and aren't listed here — only the user's
/// own — but they *are* checked against when adding, so a quote already in the
/// pool cannot be added a second time under either origin.
Future<void> showCustomQuotesDialog(BuildContext context) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => const _CustomQuotesDialog(),
  );
}

class _CustomQuotesDialog extends ConsumerStatefulWidget {
  const _CustomQuotesDialog();

  @override
  ConsumerState<_CustomQuotesDialog> createState() =>
      _CustomQuotesDialogState();
}

class _CustomQuotesDialogState extends ConsumerState<_CustomQuotesDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _error;
  var _saving = false;

  /// Id of the quote currently open for editing, and the error its last save
  /// attempt produced. Only one row edits at a time.
  String? _editingId;
  String? _editError;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_saving) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Write a quote first.');
      return;
    }
    // Against the whole pool, not just the user's own: a bundled quote typed
    // out by hand would otherwise be drawn twice as often as its neighbours.
    final pool = await ref.read(quotePoolProvider.future);
    if (!mounted) return;
    if (pool.any((q) => sameQuoteText(q.text, text))) {
      setState(() => _error = 'That quote is already in the pool.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final now = utcNow();
    final quote = CustomQuote(
      id: newId(),
      text: text,
      createdAt: now,
      updatedAt: now,
    );
    await ref.read(settingsRepositoryProvider).upsertCustomQuote(quote);
    ref.read(remoteSyncServiceProvider).pushCustomQuote(quote);
    ref.invalidate(customQuotesProvider);
    if (!mounted) return;
    _controller.clear();
    setState(() => _saving = false);
    _focusNode.requestFocus();
  }

  /// Saves an in-place edit of [quote].
  ///
  /// Runs the same duplicate check adding does — an edit that lands on text
  /// already in the pool is the same problem as typing it in twice — but lets
  /// the quote match itself, so re-saving with only the punctuation changed
  /// isn't rejected as a clash with the version being replaced.
  Future<void> _saveEdit(CustomQuote quote, String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      setState(() => _editError = 'Write a quote first.');
      return;
    }
    if (text == quote.text) {
      setState(() {
        _editingId = null;
        _editError = null;
      });
      return;
    }
    final pool = await ref.read(quotePoolProvider.future);
    if (!mounted) return;
    if (pool.any((q) => q.id != quote.id && sameQuoteText(q.text, text))) {
      setState(() => _editError = 'That quote is already in the pool.');
      return;
    }

    final updated = quote.copyWith(
      text: text,
      updatedAt: utcNow(),
      version: quote.version + 1,
    );
    await ref.read(settingsRepositoryProvider).upsertCustomQuote(updated);
    ref.read(remoteSyncServiceProvider).pushCustomQuote(updated);
    ref.invalidate(customQuotesProvider);
    if (!mounted) return;
    setState(() {
      _editingId = null;
      _editError = null;
    });
  }

  Future<void> _remove(CustomQuote quote) async {
    await ref.read(settingsRepositoryProvider).softDeleteCustomQuote(quote.id);
    ref
        .read(remoteSyncServiceProvider)
        .pushCustomQuote(
          quote.copyWith(deletedAt: utcNow(), updatedAt: utcNow()),
        );
    ref.invalidate(customQuotesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quotesAsync = ref.watch(customQuotesProvider);

    return AlertDialog(
      title: const Text('Custom quotes'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Quotes you add here join the pool a new journal entry picks '
              'from at random.',
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
                      hintText: 'Add a quote',
                      controller: _controller,
                      focusNode: _focusNode,
                      dense: true,
                      borderRadius: 12,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 8,
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    dense: true,
                    onPressed: _saving ? null : _add,
                    icon: const Icon(PhosphorIconsRegular.plus),
                    tooltip: 'Add quote',
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: quotesAsync.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (error, _) => Text('Could not load quotes: $error'),
                data: (quotes) {
                  if (quotes.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        "You haven't added any quotes yet.",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: quotes.length,
                    itemBuilder: (context, index) {
                      final quote = quotes[index];
                      if (quote.id == _editingId) {
                        return _QuoteEditor(
                          // Keyed on the quote so opening a different row
                          // builds a fresh controller seeded with its text,
                          // rather than reusing the previous row's.
                          key: ValueKey('edit-${quote.id}'),
                          quote: quote,
                          error: _editError,
                          onSave: (text) => _saveEdit(quote, text),
                          onCancel: () => setState(() {
                            _editingId = null;
                            _editError = null;
                          }),
                        );
                      }
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.only(left: 4),
                        // The whole row opens the editor, so a quote with a
                        // typo in it is one click from being fixed; the pencil
                        // is there to say so.
                        onTap: () => setState(() {
                          _editingId = quote.id;
                          _editError = null;
                        }),
                        title: Text(
                          quote.text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit quote',
                              icon: const Icon(
                                PhosphorIconsRegular.pencilSimple,
                                size: 16,
                              ),
                              onPressed: () => setState(() {
                                _editingId = quote.id;
                                _editError = null;
                              }),
                            ),
                            IconButton(
                              tooltip: 'Remove quote',
                              icon: Icon(
                                PhosphorIconsRegular.trash,
                                size: 18,
                                color: theme.colorScheme.error,
                              ),
                              onPressed: () => _remove(quote),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
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
}

/// One quote's row while it is being rewritten.
///
/// Owns its own controller and focus so the list around it can rebuild — a
/// sync landing, another quote being deleted — without disturbing the text
/// being typed. Enter commits, the way it does everywhere else a short field
/// is edited; backing out is the ✕ rather than Escape, which belongs to Vim
/// once a session is live in the field.
class _QuoteEditor extends StatefulWidget {
  const _QuoteEditor({
    super.key,
    required this.quote,
    required this.error,
    required this.onSave,
    required this.onCancel,
  });

  final CustomQuote quote;
  final String? error;
  final ValueChanged<String> onSave;
  final VoidCallback onCancel;

  @override
  State<_QuoteEditor> createState() => _QuoteEditorState();
}

class _QuoteEditorState extends State<_QuoteEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.quote.text,
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
      // Six, not four: the field inside is 28px tall and the [ListTile] this
      // row replaces is 40, so 4px of padding left the list jumping 4px
      // shorter the moment a quote was opened for editing.
      padding: const EdgeInsets.symmetric(vertical: 6),
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
                  tooltip: 'Save quote',
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
