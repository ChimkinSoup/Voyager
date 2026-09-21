import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/media/widgets/media_attach.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Makes an area of an editor accept dropped images on a parent's behalf.
///
/// The drag-and-drop half of `MediaPasteScope`: wrap the part of the page an
/// image should be droppable onto — the journal's writing area — and pass the
/// same owner its gallery was given. The gallery strip carries a drop target
/// of its own, so a page that already shows one does not need this.
class MediaDropTarget extends ConsumerWidget {
  const MediaDropTarget({
    super.key,
    required this.collection,
    required this.documentId,
    this.facet = MediaFacet.gallery,
    required this.child,
  });

  final String collection;

  /// The row a dropped image lands on, or null while it does not exist yet.
  ///
  /// The target stays mounted either way and declines the drop instead — see
  /// [MediaPasteScope.documentId] for why it must not be swapped out for its
  /// own child.
  final String? documentId;

  final MediaFacet facet;
  final Widget child;

  static const _formats = [
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.heic,
  ];

  bool _hasImage(DropSession session) =>
      session.items.any((item) => _formats.any(item.canProvide));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_dropTargetsSupported) return child;
    final documentId = this.documentId;
    return DropRegion(
      formats: _formats,
      onDropOver: (event) => documentId != null && _hasImage(event.session)
          ? DropOperation.copy
          : DropOperation.none,
      onPerformDrop: (event) async {
        if (documentId == null) return;
        final messenger = ScaffoldMessenger.of(context);
        final overlay = Overlay.of(context, rootOverlay: true);
        final images = <Uint8List>[];
        for (final item in event.session.items) {
          final reader = item.dataReader;
          if (reader == null) continue;
          final bytes = await MediaClipboard.readImageFrom(reader);
          if (bytes != null) images.add(bytes);
        }
        await attachImagesForOwner(
          ref,
          messenger: messenger,
          overlay: overlay,
          images: images,
          collection: collection,
          documentId: documentId,
          facet: facet,
        );
      },
      child: child,
    );
  }
}

/// Whether a drop target can be mounted here.
///
/// [DropRegion] reaches straight for a native message channel that only
/// exists inside a running app, so mounting one under `flutter test` throws
/// before the widget around it can be exercised at all.
final bool _dropTargetsSupported = !Platform.environment.containsKey(
  'FLUTTER_TEST',
);
