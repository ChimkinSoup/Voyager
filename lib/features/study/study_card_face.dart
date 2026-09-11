import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// One side of a card, as every surface that shows a whole card draws it —
/// the SRS session, cram, and the editor's preview.
///
/// The layout is the whole point of sharing it (STUDY_IMAGES.md): images on
/// top, text underneath, and a face with only one of the two gets the entire
/// card. When it has both, the text keeps only the room it actually needs and
/// the carousel takes the rest, so a one-line answer under a photo gets a
/// nearly full-card picture. The text stops growing at half the card and
/// scrolls from there — the image never falls below the even split, and a
/// wall of text still lands in the same place from card to card, which is
/// what makes a deck readable at speed.
class StudyCardFace extends StatelessWidget {
  const StudyCardFace({
    super.key,
    required this.text,
    required this.images,
    this.style,
    this.textAlign = TextAlign.center,
    this.keywords = const [],
    this.compact = false,
  });

  final String text;

  /// This face's gallery, in carousel order. Empty for a text-only face.
  final List<MediaAsset> images;

  final TextStyle? style;
  final TextAlign textAlign;

  /// Search terms to emphasise in the text region.
  final List<String> keywords;

  /// Scales the carousel's chrome down for the editor's preview, which shows
  /// the same layout at a fraction of a session card's size.
  final bool compact;

  /// Space between the image and text regions of a face that has both.
  static const double _regionGap = 12;

  /// Whether [text] has anything left to show once legacy embed tokens are
  /// stripped out of it — the test that decides whether a face is
  /// image-only.
  static bool hasVisibleText(String text) =>
      stripStudyMediaTokens(text).trim().isNotEmpty;

  /// The text region.
  ///
  /// [VoyagerScrollView] shrink-wraps its child in both axes, bounded by the
  /// incoming constraints, so this is exactly as tall as the text until
  /// whatever caps it says otherwise — and scrolls once the text is taller
  /// than the cap. That is what lets the carousel above it claim the
  /// leftovers.
  Widget _text() {
    return VoyagerScrollView(
      child: StudyRichText(
        text,
        textAlign: textAlign,
        keywords: keywords,
        style: style,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A text-only face is centred in the card it fills; with a picture above
    // it the text is anchored under that picture instead.
    if (images.isEmpty) return Center(child: _text());
    final carousel = StudyCardImageCarousel(images: images, compact: compact);
    if (!hasVisibleText(text)) return carousel;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Half of what is left once the gap is taken out — the floor the
        // image is held to, and so the ceiling the text is capped at. The
        // carousel is the flexible one, so it absorbs everything the text
        // leaves behind.
        final half = ((constraints.maxHeight - _regionGap) / 2).clamp(
          0.0,
          double.infinity,
        );
        return Column(
          // Both regions span the card, so [textAlign] is measured against
          // the card's own edges rather than the text block's.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: carousel),
            const SizedBox(height: _regionGap),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: half),
              child: _text(),
            ),
          ],
        );
      },
    );
  }
}

/// The home deck's name on a card a session reached through a deck link
/// (STUDY_DECK_LINKS_HLD.md §7) — plain muted text in the face's top-left
/// corner, drawn on both faces so it survives the flip. Not a chip.
class StudyCardSourceLabel extends StatelessWidget {
  const StudyCardSourceLabel(this.deckName, {super.key});

  final String deckName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      deckName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
      ),
    );
  }
}

/// The name [StudyCardSourceLabel] should show for [card] in a session framed
/// as [frameDeckId], or null when the card is at home there — or the session
/// has no frame at all, like the Hub's study-everything-due run.
String? studyCardSourceName(
  StudyCard card, {
  required String? frameDeckId,
  required Map<String, StudyDeck> decksById,
}) {
  if (frameDeckId == null || card.deckId == frameDeckId) return null;
  return decksById[card.deckId]?.name;
}

/// The image half of a [StudyCardFace].
///
/// Browsing is buttons only — no horizontal drag. Cram grades a card by
/// swiping it sideways, and a carousel that also took that gesture would
/// make every image on a cram card a coin toss between the two.
class StudyCardImageCarousel extends StatefulWidget {
  const StudyCardImageCarousel({
    super.key,
    required this.images,
    this.compact = false,
  });

  final List<MediaAsset> images;
  final bool compact;

  /// Above this many images the dots stop being countable at a glance and a
  /// plain "3 / 12" says the same thing in less room.
  static const int maxDots = 6;

  @override
  State<StudyCardImageCarousel> createState() => _StudyCardImageCarouselState();
}

class _StudyCardImageCarouselState extends State<StudyCardImageCarousel> {
  int _index = 0;

  @override
  void didUpdateWidget(StudyCardImageCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Removing an image out from under the carousel — from the editor's
    // strip, or a sync pull — must not leave the index past the end.
    if (_index >= widget.images.length) {
      _index = widget.images.isEmpty ? 0 : widget.images.length - 1;
    }
  }

  void _step(int delta) {
    setState(() => _index = (_index + delta).clamp(0, widget.images.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    if (images.isEmpty) return const SizedBox.shrink();
    final asset = images[_index];
    final theme = Theme.of(context);
    final chrome = widget.compact ? 14.0 : 20.0;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            // Tapping the picture inspects it. In a session that means the
            // image no longer flips the card — the text half and the space
            // bar still do, which is what STUDY_IMAGES.md asks for.
            onTap: () => showMediaLightbox(
              context,
              assets: images,
              initialIndex: _index,
            ),
            child: MediaImage(asset: asset, fit: BoxFit.contain),
          ),
        ),
        if (MediaTransferBadge.isPending(asset))
          Positioned(left: 4, top: 4, child: MediaTransferBadge(asset: asset)),
        if (images.length > 1) ...[
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: _CarouselArrow(
                icon: PhosphorIconsRegular.caretLeft,
                size: chrome,
                tooltip: 'Previous image',
                onPressed: _index == 0 ? null : () => _step(-1),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: _CarouselArrow(
                icon: PhosphorIconsRegular.caretRight,
                size: chrome,
                tooltip: 'Next image',
                onPressed: _index == images.length - 1 ? null : () => _step(1),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: widget.compact ? 2 : 6,
            child: Center(
              child: images.length <= StudyCardImageCarousel.maxDots
                  ? _CarouselDots(
                      count: images.length,
                      index: _index,
                      compact: widget.compact,
                    )
                  : _CarouselCounter(
                      label: '${_index + 1} / ${images.length}',
                      style: theme.textTheme.labelSmall,
                    ),
            ),
          ),
        ],
      ],
    );
  }
}

class _CarouselArrow extends StatelessWidget {
  const _CarouselArrow({
    required this.icon,
    required this.size,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final double size;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        // Opaque, and always carrying a tap handler even at the ends of the
        // queue: with `onTap` null the arrow registered no recognizer at all
        // and the press fell through to the card behind it, so clicking past
        // the last image flipped the card. A dead arrow now swallows its own
        // click and does nothing.
        behavior: HitTestBehavior.opaque,
        onTap: onPressed ?? () {},
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: EdgeInsets.all(size * 0.3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.surface.withValues(alpha: 0.85),
          ),
          child: Icon(
            icon,
            size: size,
            color: theme.colorScheme.onSurface.withValues(
              alpha: enabled ? 0.8 : 0.25,
            ),
          ),
        ),
      ),
    );
  }
}

class _CarouselDots extends StatelessWidget {
  const _CarouselDots({
    required this.count,
    required this.index,
    required this.compact,
  });

  final int count;
  final int index;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dot = compact ? 5.0 : 7.0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dot, vertical: dot * 0.6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(dot * 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: dot,
              height: dot,
              margin: EdgeInsets.symmetric(horizontal: dot * 0.3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.onSurface.withValues(
                  alpha: i == index ? 0.85 : 0.25,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CarouselCounter extends StatelessWidget {
  const _CarouselCounter({required this.label, required this.style});

  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: style?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}
