import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/media_models.dart';

/// How much of the neighbouring image the lightbox shows at each edge.
///
/// A gallery is browsed rather than glanced at, so the viewer says out loud
/// that there is more either side instead of leaving the user to discover it
/// by swiping.
const rankingsLightboxViewportFraction = 0.86;

/// The step between a row's fan and the lightbox: every image on one entry,
/// laid out so a specific one can be picked (§7.5).
///
/// Worth its own surface because a ranked entry's gallery is the one place in
/// the app that routinely holds more pictures than a fan can show — five cards
/// and a count is a summary, not a way in.
Future<void> showRankingsMediaGrid(
  BuildContext context,
  WidgetRef ref, {
  required String documentId,
  required String title,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) =>
        _RankingsMediaGrid(documentId: documentId, title: title),
  );
}

class _RankingsMediaGrid extends ConsumerStatefulWidget {
  const _RankingsMediaGrid({required this.documentId, required this.title});

  final String documentId;
  final String title;

  @override
  ConsumerState<_RankingsMediaGrid> createState() => _RankingsMediaGridState();
}

class _RankingsMediaGridState extends ConsumerState<_RankingsMediaGrid> {
  var _assets = const <MediaAsset>[];
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final service = ref.read(mediaServiceProvider);
    final references = await service.referencesFor(
      FirestoreCollections.rankings,
      widget.documentId,
    );
    final assets = await service.assetsFor(references);
    if (!mounted) return;
    setState(() {
      _assets = assets;
      _loaded = true;
    });
  }

  void _open(int index) {
    showMediaLightbox(
      context,
      assets: _assets,
      initialIndex: index,
      viewportFraction: rankingsLightboxViewportFraction,
    );
  }

  @override
  Widget build(BuildContext context) {
    // A removal inside the lightbox has to leave the grid too, and a finished
    // download turns a placeholder into a picture.
    ref.listen(mediaServiceProvider, (_, _) => _reload());
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 560,
        height: 420,
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : _assets.isEmpty
            ? Center(
                child: Text(
                  'No images yet.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: _assets.length,
                itemBuilder: (context, index) =>
                    _GridTile(asset: _assets[index], onTap: () => _open(index)),
              ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Close',
        ),
      ],
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({required this.asset, required this.onTap});

  final MediaAsset asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: MediaImage(
          asset: asset,
          fit: BoxFit.cover,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
