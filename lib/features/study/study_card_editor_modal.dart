import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// Create/edit a single card. Front/back are plain text inputs — `$...$`
/// LaTeX source is typed as-is (no live reformatting per STUDY.md) with a
/// small rendered preview shown underneath so the author can check it
/// without leaving the editor.
Future<void> showStudyCardEditorModal(
  BuildContext context,
  WidgetRef ref, {
  required String deckId,
  StudyCard? existing,
}) {
  return showVoyagerSheet<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _StudyCardEditorModal(deckId: deckId, existing: existing),
    ),
  );
}

class _StudyCardEditorModal extends ConsumerStatefulWidget {
  const _StudyCardEditorModal({required this.deckId, this.existing});

  final String deckId;
  final StudyCard? existing;

  @override
  ConsumerState<_StudyCardEditorModal> createState() => _StudyCardEditorModalState();
}

class _StudyCardEditorModalState extends ConsumerState<_StudyCardEditorModal> {
  late final TextEditingController _front = TextEditingController(
    text: widget.existing?.frontText ?? '',
  );
  late final TextEditingController _back = TextEditingController(
    text: widget.existing?.backText ?? '',
  );
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _front.addListener(() => setState(() {}));
    _back.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _front.dispose();
    _back.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _front.text.trim().isNotEmpty && _back.text.trim().isNotEmpty && !_saving;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final now = utcNow();
    final existing = widget.existing;
    final card = StudyCard(
      id: existing?.id ?? newId(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      version: existing == null ? 0 : existing.version + 1,
      deckId: widget.deckId,
      frontText: _front.text.trim(),
      backText: _back.text.trim(),
      interval: existing?.interval ?? 0,
      ease: existing?.ease ?? kStudyBaseEase,
      dueAt: existing?.dueAt ?? now,
      reviewCount: existing?.reviewCount ?? 0,
    );
    await ref.read(studyRepositoryProvider).upsertCard(card);
    ref.read(remoteSyncServiceProvider).pushStudyCard(card);
    ref.invalidate(studyCardsProvider);
    ref.invalidate(studyDeckStatsProvider);
    ref.invalidate(studyStatsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final repo = ref.read(studyRepositoryProvider);
    await repo.softDeleteCard(existing.id);
    final tombstone = await repo.getCard(existing.id);
    if (tombstone != null) {
      ref.read(remoteSyncServiceProvider).pushStudyCard(tombstone);
    }
    ref.invalidate(studyCardsProvider);
    ref.invalidate(studyDeckStatsProvider);
    ref.invalidate(studyStatsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
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
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Text(
                    widget.existing == null ? 'New card' : 'Edit card',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (widget.existing != null)
                    IconButton(
                      onPressed: _saving ? null : _delete,
                      icon: Icon(
                        PhosphorIconsRegular.trash,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      tooltip: 'Delete',
                      padding: EdgeInsets.zero,
                      constraints: kMinTouchTarget,
                    ),
                  IconButton(
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: kMinTouchTarget,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              VoyagerTextField(
                controller: _front,
                autofocus: widget.existing == null,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Front',
                  hintText: r'Supports LaTeX between $...$',
                ),
              ),
              if (_front.text.contains('\$')) ...[
                const SizedBox(height: 6),
                StudyRichText(_front.text, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _back,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(labelText: 'Back'),
              ),
              if (_back.text.contains('\$')) ...[
                const SizedBox(height: 6),
                StudyRichText(_back.text, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 18),
              GlassButton(
                onPressed: _canSave ? _save : null,
                label: 'Save',
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
