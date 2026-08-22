import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_card_bulk_import.dart';

class _ImportOutcome {
  const _ImportOutcome({required this.importedCount, required this.skipped});

  final int importedCount;
  final List<StudyBulkImportSkippedLine> skipped;
}

/// Opens a paste-to-import sheet for [deckId]. One card per line, `front|back`.
Future<void> showStudyImportTextModal(
  BuildContext context,
  WidgetRef ref,
  String deckId,
) async {
  final outcome = await showVoyagerSheet<_ImportOutcome>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _StudyImportTextModal(deckId: deckId),
    ),
  );
  if (outcome == null || !context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Imported ${outcome.importedCount} card'
        '${outcome.importedCount == 1 ? '' : 's'}.',
      ),
    ),
  );

  if (outcome.skipped.isNotEmpty && context.mounted) {
    await _showSkippedLinesDialog(context, outcome.skipped);
  }
}

class _StudyImportTextModal extends ConsumerStatefulWidget {
  const _StudyImportTextModal({required this.deckId});

  final String deckId;

  @override
  ConsumerState<_StudyImportTextModal> createState() =>
      _StudyImportTextModalState();
}

class _StudyImportTextModalState extends ConsumerState<_StudyImportTextModal> {
  final TextEditingController _controller = TextEditingController();
  StudyBulkImportParseResult _parsed = const StudyBulkImportParseResult(
    cards: [],
    skipped: [],
  );
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_reparse);
  }

  @override
  void dispose() {
    _controller.removeListener(_reparse);
    _controller.dispose();
    super.dispose();
  }

  void _reparse() {
    setState(() {
      _parsed = parseStudyBulkImportText(_controller.text);
    });
  }

  bool get _canImport => _parsed.cards.isNotEmpty && !_importing;

  Future<void> _import() async {
    if (!_canImport) return;
    setState(() => _importing = true);

    final cards = List<StudyBulkImportCard>.of(_parsed.cards);
    final skipped = List<StudyBulkImportSkippedLine>.of(_parsed.skipped);
    final now = utcNow();
    final repo = ref.read(studyRepositoryProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);

    for (final entry in cards) {
      final card = StudyCard(
        id: newId(),
        createdAt: now,
        updatedAt: now,
        deckId: widget.deckId,
        frontText: entry.front,
        backText: entry.back,
        dueAt: now,
      );
      await repo.upsertCard(card);
      remoteSync.pushStudyCard(card);
    }

    ref.invalidate(studyCardsProvider);
    ref.invalidate(studyDeckStatsProvider);
    ref.invalidate(studyStatsProvider);

    if (!mounted) return;
    Navigator.of(context).pop(
      _ImportOutcome(importedCount: cards.length, skipped: skipped),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final previewCards = _parsed.cards.take(6).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.3,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Text('Import cards', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: kMinTouchTarget,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                r'One card per line: front|back. Use \| for a literal pipe.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 12),
              VoyagerTextField(
                controller: _controller,
                autofocus: true,
                maxLines: 10,
                minLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'front|back\nanother front|another back',
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _previewSummary(),
                style: theme.textTheme.labelLarge,
              ),
              if (previewCards.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...previewCards.map((card) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${card.front} → ${card.back}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  );
                }),
                if (_parsed.cards.length > previewCards.length)
                  Text(
                    '+ ${_parsed.cards.length - previewCards.length} more',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
              ],
              if (_parsed.skipped.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${_parsed.skipped.length} line'
                  '${_parsed.skipped.length == 1 ? '' : 's'} will be skipped',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error.withValues(alpha: 0.85),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              GlassButton(
                onPressed: _canImport ? _import : null,
                label: _importing
                    ? 'Importing…'
                    : 'Import ${_parsed.cards.length} card'
                        '${_parsed.cards.length == 1 ? '' : 's'}',
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _previewSummary() {
    final n = _parsed.cards.length;
    if (_controller.text.trim().isEmpty) {
      return 'Paste cards to preview';
    }
    if (n == 0) {
      return 'No valid cards yet';
    }
    return '$n card${n == 1 ? '' : 's'} ready';
  }
}

Future<void> _showSkippedLinesDialog(
  BuildContext context,
  List<StudyBulkImportSkippedLine> skipped,
) {
  final theme = Theme.of(context);
  return showVoyagerDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        'Skipped ${skipped.length} line${skipped.length == 1 ? '' : 's'}',
      ),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: VoyagerScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in skipped) ...[
                  Text(
                    'Line ${line.lineNumber}: ${line.reason}',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    line.rawLine,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(ctx),
          label: 'OK',
          dense: true,
        ),
      ],
    ),
  );
}
