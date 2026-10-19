import 'package:flutter/material.dart';
import 'package:voyager/domain/models/photo_series_models.dart';

/// The frame an angle's photos are drawn in, before anything has fixed one.
const kDefaultPhotoFrameAspect = 3 / 4;

/// One photo drawn onto its angle's reference frame (PHOTO_SERIES_HLD.md
/// §10): [child] fills the frame — fitted inside it — and is then moved,
/// turned and zoomed about the frame's centre by [image]'s transform, and
/// clipped to the frame. Takes the largest frame [aspect] allows.
class AlignedPhotoFrame extends StatelessWidget {
  const AlignedPhotoFrame({
    super.key,
    required this.aspect,
    required this.image,
    required this.child,
  });

  final double aspect;
  final PhotoCheckInImage image;
  final Widget child;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: aspect,
    child: ClipRect(
      child: LayoutBuilder(
        builder: (context, box) => Transform(
          alignment: Alignment.center,
          transform:
              Matrix4.translationValues(
                  image.alignDx * box.maxWidth,
                  image.alignDy * box.maxHeight,
                  0,
                )
                ..rotateZ(image.alignRotation)
                ..scaleByDouble(image.alignScale, image.alignScale, 1, 1),
          child: SizedBox.expand(child: child),
        ),
      ),
    ),
  );
}
