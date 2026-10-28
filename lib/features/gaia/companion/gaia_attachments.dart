import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';

/// An image in the composer's draft (GAIA_HLD.md §9.3): pasted or captured,
/// waiting to go with the next message. [label] is its `[image N]` while in
/// the draft; sending numbers the draft's images on from the chat's.
class GaiaDraftImage {
  GaiaDraftImage({
    required this.label,
    required this.path,
    this.edits = GaiaImageEdits.none,
    this.preview,
    this.mediaId,
  });

  final int label;

  /// Its asset once the main instance has it, which the kept draft names
  /// it by (§9.3); null before, or when it was refused.
  final String? mediaId;

  /// The image as it came, in a file of the companion's own. Edits never
  /// change it, so they can be edited again (§9.4).
  final String path;
  final GaiaImageEdits edits;

  /// [path] with [edits] applied, for the thumbnail; null without edits.
  final String? preview;

  GaiaDraftImage copyWith({
    int? label,
    GaiaImageEdits? edits,
    String? preview,
    String? mediaId,
  }) => GaiaDraftImage(
    label: label ?? this.label,
    path: path,
    edits: edits ?? this.edits,
    preview: edits == null ? this.preview : preview,
    mediaId: mediaId ?? this.mediaId,
  );
}

/// A selection quoted for the draft (GAIA_HLD.md §15.2), after the window
/// it came from.
String gaiaQuoteSelection(String text, String? source) => [
  if (source != null) 'From $source:',
  // RichEdit controls, Notepad's among them, break lines with a bare \r.
  for (final line in text.trimRight().split(RegExp(r'\r\n?|\n'))) '> $line',
].join('\n');

/// [text] and [images] with the images numbered on from [first], in the
/// order they were added, and each `[image N]` in [text] rewritten to
/// match. An image whose token was deleted gets one at the end, so the
/// stored text names every image the message carries.
(String, List<GaiaDraftImage>) gaiaRelabelDraft(
  String text,
  List<GaiaDraftImage> images,
  int first,
) {
  final labels = {
    for (final (i, image) in images.indexed) image.label: first + i,
  };
  var relabeled = text.replaceAllMapped(gaiaImageTokenPattern, (match) {
    final label = labels[int.parse(match.group(1)!)];
    return label == null ? match.group(0)! : gaiaImageToken(label);
  });
  final named = {
    for (final match in gaiaImageTokenPattern.allMatches(relabeled))
      int.parse(match.group(1)!),
  };
  final missing = [
    for (final label in labels.values)
      if (!named.contains(label)) gaiaImageToken(label),
  ];
  if (missing.isNotEmpty) {
    relabeled = [
      if (relabeled.trim().isNotEmpty) relabeled.trimRight(),
      missing.join(' '),
    ].join('\n\n');
  }
  return (
    relabeled,
    [for (final image in images) image.copyWith(label: labels[image.label])],
  );
}
