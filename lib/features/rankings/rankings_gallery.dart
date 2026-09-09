import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_media_grid.dart';

/// Every picture on one entry, its own and its units', in one run (§10).
///
/// The order is the order the entry reads in: the parent's gallery first, then
/// each unit in the order the list keeps them in — the saved [sortOrder], not
/// whatever the child list happens to be sorted by right now, so the run is
/// the same however the panel is being looked at.
///
/// Every slide carries the name of what it hangs off, because that is the one
/// thing the pictures themselves cannot say once they are pooled: two frames
/// of episode one look like two frames of episode two.
///
/// View-only. Removing and reordering happen in the gallery strip of whatever
/// owns the picture, where there is no doubt about which entry is being
/// changed.
Future<void> showRankingsEntryGallery(
  BuildContext context,
  WidgetRef ref, {
  required RankingParent parent,
  required List<RankingChild> children,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final service = ref.read(mediaServiceProvider);
  final assets = <MediaAsset>[];
  final captions = <String>[];

  Future<void> collect(String documentId, String caption) async {
    final references = await service.referencesFor(
      FirestoreCollections.rankings,
      documentId,
    );
    // Captions are appended per *asset* rather than per reference: a reference
    // whose asset has gone is skipped, and the two lists have to stay in step.
    for (final asset in await service.assetsFor(references)) {
      assets.add(asset);
      captions.add(caption);
    }
  }

  await collect(
    parent.id,
    parent.title.trim().isEmpty ? 'Untitled' : parent.title,
  );
  final ordered = [...children]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  for (final child in ordered) {
    await collect(child.id, child.name);
  }

  if (!context.mounted) return;
  if (assets.isEmpty) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('No images on this entry yet.')),
    );
    return;
  }

  await showMediaLightbox(
    context,
    assets: assets,
    captions: captions,
    viewportFraction: rankingsLightboxViewportFraction,
  );
}
