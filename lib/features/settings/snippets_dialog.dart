import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/snippet_editor.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// Edits the user's text-expansion snippets, plus the two settings that govern
/// them all.
///
/// Every field in here opts out of snippets (`snippetsAllowed: false`). That is
/// not a nicety: a trigger being typed into the trigger box would expand as
/// soon as it was complete, so the one place snippets must never run is the
/// place they are written.
Future<void> showSnippetsDialog(BuildContext context) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => const _SnippetsDialog(),
  );
}

class _SnippetsDialog extends ConsumerStatefulWidget {
  const _SnippetsDialog();

  @override
  ConsumerState<_SnippetsDialog> createState() => _SnippetsDialogState();
}

class _SnippetsDialogState extends ConsumerState<_SnippetsDialog> {
  /// Id of the snippet open in the row editor, `_newRowId` while an unsaved
  /// one is being written, or null when the list is just being read.
  String? _editingId;
  String? _editError;

  /// Sentinel for the "add a snippet" row, which has no record behind it yet.
  static const String _newRowId = '';

  Future<void> _write(AppSettings settings, List<Snippet> snippets) {
    return ref
        .read(settingsProvider.notifier)
        .saveSettings(
          settings.copyWith(snippets: snippets, updatedAt: utcNow()),
        );
  }

  Future<void> _saveRow(
    AppSettings settings,
    Snippet? original,
    SnippetDraft draft,
  ) async {
    final trigger = draft.trigger.trim();
    final error = validateSnippetTrigger(
      settings.snippets,
      original?.id,
      trigger,
    );
    if (error != null) {
      setState(() => _editError = error);
      return;
    }
    final snippets = [...settings.snippets];
    if (original == null) {
      snippets.add(
        Snippet(
          id: newId(),
          trigger: trigger,
          replacement: draft.replacement,
          autoExpand: draft.autoExpand,
          wordBoundary: draft.wordBoundary,
        ),
      );
    } else {
      final index = snippets.indexWhere((s) => s.id == original.id);
      if (index < 0) return;
      snippets[index] = original.copyWith(
        trigger: trigger,
        replacement: draft.replacement,
        autoExpand: draft.autoExpand,
        wordBoundary: draft.wordBoundary,
      );
    }
    await _write(settings, snippets);
    if (!mounted) return;
    setState(() {
      _editingId = null;
      _editError = null;
    });
  }

  Future<void> _remove(AppSettings settings, Snippet snippet) async {
    await _write(settings, [
      for (final s in settings.snippets)
        if (s.id != snippet.id) s,
    ]);
    if (!mounted) return;
    if (_editingId == snippet.id) {
      setState(() {
        _editingId = null;
        _editError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) {
      return const AlertDialog(
        content: SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: const Text('Text snippets'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Type a trigger in any text box and it expands. Use \$0, \$1 … '
              'in the replacement to mark where the caret should stop — Tab '
              'moves between them. Write \\\$0 for a literal "\$0".',
              style: muted,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Enable snippets'),
              value: settings.snippetsEnabled,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .saveSettings(
                    settings.copyWith(snippetsEnabled: v, updatedAt: utcNow()),
                  ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Expand key'),
              subtitle: Text(
                'Expands snippets that are not set to expand automatically',
                style: muted,
              ),
              trailing: SegmentedButton<SnippetExpandKey>(
                segments: const [
                  ButtonSegment(
                    value: SnippetExpandKey.tab,
                    label: Text('Tab'),
                  ),
                  ButtonSegment(
                    value: SnippetExpandKey.space,
                    label: Text('Space'),
                  ),
                ],
                selected: {settings.snippetExpandKey},
                showSelectedIcon: false,
                onSelectionChanged: (sel) => ref
                    .read(settingsProvider.notifier)
                    .saveSettings(
                      settings.copyWith(
                        snippetExpandKey: sel.first,
                        updatedAt: utcNow(),
                      ),
                    ),
              ),
            ),
            const Divider(height: 24),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: settings.snippets.isEmpty && _editingId != _newRowId
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        "You haven't written any snippets yet.",
                        textAlign: TextAlign.center,
                        style: muted,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount:
                          settings.snippets.length +
                          (_editingId == _newRowId ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == settings.snippets.length) {
                          return SnippetEditor(
                            key: const ValueKey('snippet-new'),
                            original: null,
                            error: _editError,
                            onSave: (draft) => _saveRow(settings, null, draft),
                            onCancel: () => setState(() {
                              _editingId = null;
                              _editError = null;
                            }),
                          );
                        }
                        final snippet = settings.snippets[index];
                        if (snippet.id == _editingId) {
                          return SnippetEditor(
                            // Keyed on the record so opening a different row
                            // seeds fresh controllers from its text rather
                            // than reusing the previous row's.
                            key: ValueKey('snippet-${snippet.id}'),
                            original: snippet,
                            error: _editError,
                            onSave: (draft) =>
                                _saveRow(settings, snippet, draft),
                            onCancel: () => setState(() {
                              _editingId = null;
                              _editError = null;
                            }),
                          );
                        }
                        return _SnippetRow(
                          snippet: snippet,
                          onEdit: () => setState(() {
                            _editingId = snippet.id;
                            _editError = null;
                          }),
                          onRemove: () => _remove(settings, snippet),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: GlassButton(
                dense: true,
                onPressed: _editingId == _newRowId
                    ? null
                    : () => setState(() {
                        _editingId = _newRowId;
                        _editError = null;
                      }),
                icon: const Icon(PhosphorIconsRegular.plus),
                label: 'Add snippet',
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

/// One snippet as it reads in the list: `trigger → replacement`, with the two
/// flags as short badges rather than words, so a dozen rows stay scannable.
class _SnippetRow extends StatelessWidget {
  const _SnippetRow({
    required this.snippet,
    required this.onEdit,
    required this.onRemove,
  });

  final Snippet snippet;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4),
      onTap: onEdit,
      title: Row(
        children: [
          Text(
            snippet.trigger,
            style: mono?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Icon(
            PhosphorIconsRegular.arrowRight,
            size: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // A replacement spanning lines has to fit on one row here.
              snippet.replacement.replaceAll('\n', '⏎'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (snippet.autoExpand)
            _Badge(label: 'A', tooltip: 'Expands automatically'),
          if (snippet.wordBoundary)
            _Badge(label: 'w', tooltip: 'Only at word boundaries'),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit snippet',
            icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Remove snippet',
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

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.tooltip});

  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 10,
            height: 1.2,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
