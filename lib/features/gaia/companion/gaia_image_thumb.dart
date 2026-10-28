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
    this.busyLabel = 'Uploading',
  });

  final Future<String?>? file;
  final String? path;
  final int label;
  final double height;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool uploading;

  /// What the spinner says while [uploading].
  final String busyLabel;

  /// Loads [file] as a thumbnail [height] tall shows it, so one built after
  /// shows it on its first frame.
  static Future<void> precache(
    BuildContext context,
    Future<String?> file,
    double height,
  ) async {
    final path = await file;
    if (path == null || !context.mounted) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    await precacheImage(
      ResizeImage(FileImage(File(path)), height: (height * ratio).round()),
      context,
    );
  }

  /// One function, so the switcher doesn't rebuild its transitions on every
  /// build; and driven, so it adds no listeners to dispose.
  static Widget _spinnerTransition(Widget child, Animation<double> animation) =>
      FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: animation.drive(
            Tween(
              begin: 0.6,
              end: 1.0,
            ).chain(CurveTween(curve: Curves.easeOut)),
          ),
          child: child,
        ),
      );

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
                  Positioned.fill(
                    child: Center(
                      // Fades and shrinks away once attached, in step with
                      // the image brightening.
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: _spinnerTransition,
                        child: uploading
                            ? GaiaSpinner(
                                size: 32,
                                color: Colors.white,
                                label: busyLabel,
                              )
                            : const SizedBox.shrink(),
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
