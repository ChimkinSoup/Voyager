import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_attach.dart';
import 'package:voyager/core/media/widgets/media_drop_target.dart';
import 'package:voyager/core/media/widgets/media_gallery_strip.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_card_face.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// Create/edit a single card. Front/back are plain text inputs — `$...$`
/// LaTeX source is typed as-is (no live reformatting per STUDY.md) — with a
/// rendered preview underneath so the author can check the face they are
/// building without leaving the editor. Images are attached to each side's
/// own gallery rather than typed into the text (STUDY_IMAGES.md). Editing an
/// existing card also reports its SRS standing, which is otherwise only
/// legible as a border color in the grid.
Future<void> showStudyCardEditorModal(
  BuildContext context,
  WidgetRef ref, {
  required String deckId,
  StudyCard? existing,
}) {
  return showVoyagerModal<void>(
    context: context,
    kind: VoyagerSheetKind.editor,
    // The opener's own container, not a child one: a scope that owned its
    // container would dispose it as the sheet closes — which the trash button
    // does straight after deleting — and the toast's Undo reads through it.
    builder: (ctx) => UncontrolledProviderScope(
      container: ProviderScope.containerOf(context),
      child: _StudyCardEditorModal(deckId: deckId, existing: existing),
    ),
  );
}

class _StudyCardEditorModal extends ConsumerStatefulWidget {
  const _StudyCardEditorModal({required this.deckId, this.existing});

  final String deckId;
  final StudyCard? existing;

  @override
  ConsumerState<_StudyCardEditorModal> createState() =>
      _StudyCardEditorModalState();
}

class _StudyCardEditorModalState extends ConsumerState<_StudyCardEditorModal> {
  late final TextEditingController _front = TextEditingController(
    text: widget.existing?.frontText ?? '',
  );
  late final TextEditingController _back = TextEditingController(
    text: widget.existing?.backText ?? '',
  );

  /// The card's id, allocated here rather than at save time so the gallery
  /// strips have an owner to attach to from the moment the editor opens. A
  /// new card is a real document id with no row behind it yet.
  late final String _cardId = widget.existing?.id ?? newId();

  /// Resolved in [initState] rather than lazily: [dispose] needs the service
  /// after this widget's `ref` has stopped being readable, so a `late` field
  /// that first ran there would throw instead of detaching.
  late final MediaService _media;

  bool _saving = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _media = ref.read(mediaServiceProvider);
  }

  @override
  void dispose() {
    // Images attach the instant they are picked, but a new card's row only
    // appears on save. Closing without saving would otherwise leave
    // references hanging off a document that never existed — and a live
    // reference keeps its asset off the retention clock forever.
    if (widget.existing == null && !_saved) {
      unawaited(
        _media.removeReferencesForOwner(
          FirestoreCollections.studyCards,
          _cardId,
        ),
      );
    }
    _front.dispose();
    _back.dispose();
    super.dispose();
  }

  /// A side is complete when it has something to show — text or images. Either
  /// alone is a valid face (STUDY_IMAGES.md).
  static bool _sideFilled(String text, List<MediaAsset> images) =>
      text.trim().isNotEmpty || images.isNotEmpty;

  /// Writes the two faces this sheet owns and nothing else.
  ///
  /// The row is re-read at save time rather than rebuilt from `widget.existing`.
  /// This is a long-lived modal: a sync pull landing a grade from another
  /// device can revise the card while it is open, and reconstructing it from
  /// the snapshot taken when the sheet opened would roll `interval` / `ease` /
  /// `dueAt` / `reviewCount` back to that moment — then write a `version` that
  /// may be no higher than what is already on disk, which makes the next pull's
  /// verdict a coin flip rather than a defined last-write-wins. The SRS columns
  /// are not the editor's to write at all.
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(studyRepositoryProvider);
      final now = utcNow();
      final current = widget.existing == null
          ? null
          : await repo.getCard(_cardId);
      final card = current == null
          ? StudyCard(
              id: _cardId,
              createdAt: now,
              updatedAt: now,
              deckId: widget.deckId,
              frontText: _front.text.trim(),
              backText: _back.text.trim(),
              dueAt: now,
            )
          // copyWith bumps version off the row as it stands now, and leaves
          // interval/ease/dueAt/reviewCount alone.
          : current.copyWith(
              frontText: _front.text.trim(),
              backText: _back.text.trim(),
            );
      await repo.upsertCard(card);
      // Only true once the row the image references hang off actually exists —
      // set before the write, a throw would skip dispose's cleanup and strand
      // those references on a document id with no row, off the retention clock
      // forever.
      _saved = true;
      ref.read(remoteSyncServiceProvider).pushStudyCard(card);
      // All four: the per-deck roster, the flattened list a session works from,
      // and both stat providers.
      invalidateStudyCards(ref);
      if (mounted) Navigator.of(context).pop();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'study card editor',
          context: ErrorDescription('while saving card $_cardId'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the card.')),
        );
      }
    } finally {
      // Cleared however the write ended, or Save is disabled for good and the
      // only way out of the sheet discards the user's typing.
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    // Captured before the modal closes: the toast that offers the undo outlives
    // this route, and a `WidgetRef` would not.
    final container = ProviderScope.containerOf(context, listen: false);
    final overlay = Overlay.of(context, rootOverlay: true);
    final navigator = Navigator.of(context);

    // No confirm dialog here on purpose. The editor's trash button has never
    // asked, and the undo is what makes that safe rather than a new dialog.
    // A local rather than a field on this State: the restore closure outlives
    // the modal, and a field would keep the disposed State reachable from the
    // toast's standing offer for as long as the offer stands. Assigned inside
    // `delete` and read only from `restore`, which `softDeleteWithUndo`
    // reaches only once `delete` has returned normally.
    late final StudyCardDeletion deletion;
    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(
        existing.frontText,
        fallback: 'card',
        prose: true,
      ),
      delete: () async =>
          deletion = await softDeleteStudyCard(container, existing),
      restore: () => restoreStudyCard(container, deletion),
    );
    navigator.pop();
  }

  /// e.g. "New card · due today" or "Interval 21d · ease 2.5 · 7 reviews ·
  /// due in 3 days".
  String _srsSummary(StudyCard card) {
    final days = studyDaysUntilDue(card);
    final due = switch (days) {
      0 => 'due today',
      1 => 'due tomorrow',
      _ => 'due in $days days',
    };
    if (card.isNew) return 'Never studied · $due';
    return 'Interval ${formatStudyInterval(card.interval)} · '
        'ease ${card.ease.toStringAsFixed(2)} · '
        '${card.reviewCount} review${card.reviewCount == 1 ? '' : 's'} · $due';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final images =
        ref.watch(studyCardImagesProvider).valueOrNull?[_cardId] ??
        (front: const <MediaAsset>[], back: const <MediaAsset>[]);
    // Read live rather than captured at build time: the Save button below is
    // the only thing the typed text drives, and it watches the controllers
    // itself. A `setState` listener on each rebuilt the whole sheet per
    // keystroke, which also made its heavy GlassSurface re-blur a
    // window-sized backdrop for every character.
    bool canSave() =>
        !_saving &&
        _sideFilled(_front.text, images.front) &&
        _sideFilled(_back.text, images.back);

    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (voyagerSheetDrags(VoyagerSheetKind.editor))
                const VoyagerSheetHandle(),
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
              if (widget.existing != null) ...[
                const SizedBox(height: 8),
                Text(
                  _srsSummary(widget.existing!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _CardSide(
                cardId: _cardId,
                facet: MediaFacet.front,
                controller: _front,
                images: images.front,
                label: 'Front',
                hintText: r'Supports LaTeX between $...$',
                autofocus: widget.existing == null,
              ),
              const SizedBox(height: 16),
              _CardSide(
                cardId: _cardId,
                facet: MediaFacet.back,
                controller: _back,
                images: images.back,
                label: 'Back',
              ),
              const SizedBox(height: 18),
              ListenableBuilder(
                listenable: Listenable.merge([_front, _back]),
                builder: (context, _) => GlassButton(
                  onPressed: canSave() ? _save : null,
                  label: 'Save',
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Gated like the button: _save itself doesn't check that both faces are
    // filled. Checked on press rather than handed a build-time verdict, which
    // no longer refreshes on every keystroke.
    return CtrlEnterToSubmitScope(
      onSubmit: () {
        if (canSave()) _save();
      },
      child: sheet,
    );
  }
}

/// One face's editor: its text field, the preview of what that face will look
/// like, and its gallery.
///
/// The whole side is a paste and drop target for its own facet, which is what
/// scopes an image to the field the caret is in.
class _CardSide extends ConsumerWidget {
  const _CardSide({
    required this.cardId,
    required this.facet,
    required this.controller,
    required this.images,
    required this.label,
    this.hintText,
    this.autofocus = false,
  });

  final String cardId;
  final MediaFacet facet;
  final TextEditingController controller;
  final List<MediaAsset> images;
  final String label;
  final String? hintText;
  final bool autofocus;

  /// Height of the rendered preview when this side has images. Tall enough
  /// for the split layout to read as a split, short enough that both sides
  /// still fit in the sheet.
  static const double _previewHeight = 200;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasLatex = controller.text.contains(r'$');

    return MediaDropTarget(
      collection: FirestoreCollections.studyCards,
      documentId: cardId,
      facet: facet,
      child: MediaPasteScope(
        collection: FirestoreCollections.studyCards,
        documentId: cardId,
        facet: facet,
        // A card's text field is image-capable in the sense that matters
        // here: pasting text and an image together types the text and hangs
        // the picture off this same side.
        fieldTakesBoth: true,
        // …but only while the caret is actually in one of them. With a
        // gallery per side there is no answer to "which side" without a
        // focused field, so that paste is left alone.
        requireFocusedField: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VoyagerTextField(
              controller: controller,
              autofocus: autofocus,
              maxLines: 4,
              minLines: 2,
              decoration: InputDecoration(labelText: label, hintText: hintText),
            ),
            if (images.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: _previewHeight,
                child: StudyCardFace(
                  text: controller.text,
                  images: images,
                  compact: true,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ] else if (hasLatex ||
                stripStudyMediaTokens(controller.text) != controller.text) ...[
              const SizedBox(height: 6),
              StudyRichText(controller.text, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            if (images.isEmpty)
              _AddImageButton(cardId: cardId, facet: facet)
            else
              MediaGalleryStrip(
                collection: FirestoreCollections.studyCards,
                documentId: cardId,
                facet: facet,
                thumbnailSize: 56,
              ),
          ],
        ),
      ),
    );
  }
}

/// The attach affordance a side shows before it has any images, in place of
/// the gallery strip — which only appears once there is an order to show.
class _AddImageButton extends ConsumerStatefulWidget {
  const _AddImageButton({required this.cardId, required this.facet});

  final String cardId;
  final MediaFacet facet;

  @override
  ConsumerState<_AddImageButton> createState() => _AddImageButtonState();
}

class _AddImageButtonState extends ConsumerState<_AddImageButton> {
  bool _busy = false;

  Future<void> _pick() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    final images = await pickImageFiles();
    if (images.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await attachImagesForOwner(
        ref,
        messenger: messenger,
        overlay: overlay,
        images: images,
        collection: FirestoreCollections.studyCards,
        documentId: widget.cardId,
        facet: widget.facet,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GlassButton(
        onPressed: _busy ? null : _pick,
        // Dense: it sits under a text field as a secondary action, next to
        // the sheet's full-width Save.
        dense: true,
        icon: const Icon(PhosphorIconsRegular.imageSquare),
        label: _busy ? 'Adding…' : 'Add image',
      ),
    );
  }
}
