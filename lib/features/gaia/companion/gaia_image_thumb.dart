import 'dart:io';

import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';

/// An attached image as a thumbnail [height] tall, its `[image N]` over its
/// corner (GAIA_HLD.md §9.3): the file at [path], or the one [file]
/// resolves to, which is null while the image isn't on this device and
/// shows a placeholder. [onRemove] adds a close button; [onTap] makes it
/// clickable. While [uploading], it's dimmed under a spinner.
class GaiaImageThumb extends StatelessWidget {
  const GaiaImageThumb({
    super.key,
    this.file,
    this.path,
    required this.label,
    required this.height,
    this.onTap,
    this.onRemove,
    this.uploading = false,
  });

  final Future<String?>? file;
  final String? path;
  final int label;
  final double height;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool uploading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final caption = theme.textTheme.labelSmall?.copyWith(color: Colors.white);
    return FutureBuilder(
      future: file,
      initialData: path,
      builder: (context, snapshot) {
        final path = snapshot.data;
        final Widget image = path == null
            ? Container(
                width: height,
                color: theme.colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Icon(
                  Icons.image_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : Image.file(
                File(path),
                height: height,
                fit: BoxFit.contain,
                cacheHeight: (height * ratio).round(),
                // The draft's file swapped for the stored one once uploaded,
                // without a blank frame between.
                gaplessPlayback: true,
                errorBuilder: (context, _, _) => SizedBox.square(
                  dimension: height,
                  child: const Icon(Icons.broken_image_outlined),
                ),
              );
        return MouseRegion(
          cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: SizedBox(
              height: height,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AnimatedOpacity(
                      opacity: uploading ? 0.45 : 1,
                      duration: const Duration(milliseconds: 200),
                      child: image,
                    ),
                  ),
                  if (uploading)
                    const Positioned.fill(
                      child: Center(
                        child: GaiaSpinner(
                          size: 32,
                          color: Colors.white,
                          label: 'Uploading',
                        ),
                      ),
                    ),
                  Positioned(
                    left: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(gaiaImageToken(label), style: caption),
                    ),
                  ),
                  if (onRemove case final remove?)
                    Positioned(
                      right: 2,
                      top: 2,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: remove,
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
