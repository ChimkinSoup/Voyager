import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';

/// An attached file or folder (§9.3) as a card [height] tall, beside the
/// images: its name and type, its whole path on hover. [onRemove] adds a
/// close button, as on an image's thumbnail.
class GaiaFileCard extends StatelessWidget {
  const GaiaFileCard({
    super.key,
    required this.file,
    required this.height,
    this.onRemove,
  });

  final GaiaFilePart file;
  final double height;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final extension = p.extension(file.path).toLowerCase();
    final type = file.folder
        ? 'Folder'
        : extension.isEmpty
        ? 'File'
        : extension.substring(1).toUpperCase();
    final icon = file.folder
        ? Icons.folder_outlined
        : extension == '.pdf'
        ? Icons.picture_as_pdf_outlined
        : Icons.description_outlined;
    return Tooltip(
      message: file.path,
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: height - 16,
                    height: height - 16,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(icon, size: 20, color: accent),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.basename(file.path),
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          type,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
                      child: Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
