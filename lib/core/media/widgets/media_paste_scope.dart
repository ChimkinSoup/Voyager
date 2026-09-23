import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/media/widgets/media_attach.dart';
import 'package:voyager/core/text/prose_paste.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Where one Ctrl+V ends up.
enum MediaPasteRoute {
  /// Into the editor's image gallery.
  attach,

  /// On to the focused text field, as an ordinary paste.
  text,

  /// Both: the text at the caret, the image onto the gallery.
  both,

  /// Nowhere — text with nothing to type it into.
  ignore,
}

/// Decides where a paste goes from what the clipboard holds and what has
/// focus. Pure so the table below can be tested without a clipboard.
///
/// The two rules that are not obvious:
///
/// * An image with no text pasted *into a text field* still goes to the
///   gallery. The field has nothing it could paste, so the alternative is a
///   keystroke that visibly does nothing.
/// * An image alongside text, with no field focused, still goes to the
///   gallery. There is no caret for the text half to land in, so the image is
///   the only part of that clipboard that can go anywhere at all.
///
/// [fieldTakesBoth] is the design's *image-capable field* row: a field whose
/// own page owns the gallery — the journal body — takes both halves of a
/// text-and-image clipboard rather than dropping the picture. Off for a field
/// that merely happens to sit next to a gallery, like a todo's notes.
///
/// [requireFocusedField] is for a surface with more than one gallery, where
/// the focused field is the only thing that says which one a picture belongs
/// to: a study card's front and back. Without a caret there is no answer, so
/// the paste is left alone rather than guessed at.
MediaPasteRoute routeMediaPaste({
  required bool hasImage,
  required bool hasText,
  required bool intoTextField,
  bool fieldTakesBoth = false,
  bool requireFocusedField = false,
}) {
  if (!hasImage) {
    return intoTextField ? MediaPasteRoute.text : MediaPasteRoute.ignore;
  }
  if (!intoTextField) {
    return requireFocusedField
        ? MediaPasteRoute.ignore
        : MediaPasteRoute.attach;
  }
  if (!hasText) return MediaPasteRoute.attach;
  return fieldTakesBoth ? MediaPasteRoute.both : MediaPasteRoute.text;
}

/// Makes an editor's whole body a paste target for its image gallery.
///
/// Wrap the editor — not the strip — and a pasted screenshot lands in the
/// gallery whether the caret is in a text field, on a button, or nowhere at
/// all. Without it the only way to paste an image is to first focus the strip
/// itself, which no surface offers a way to do.
///
/// Adding this to a page is the whole integration: pass the same owner the
/// page's `MediaGalleryStrip` was given. The strip repaints itself off the
/// media service's notification, so nothing has to be wired between the two.
class MediaPasteScope extends ConsumerStatefulWidget {
  const MediaPasteScope({
    super.key,
    required this.collection,
    required this.documentId,
    this.facet = MediaFacet.gallery,
    this.fieldTakesBoth = false,
    this.requireFocusedField = false,
    this.clipboard = const MediaClipboard(),
    required this.child,
  });

  final String collection;

  /// The row the images land on, or null while it does not exist yet.
  ///
  /// A scope with no owner stays mounted rather than being swapped out for
  /// its own child: the journal body's editor is built before the entry it
  /// belongs to is selected, and a wrapper that appears a frame later
  /// re-inflates the whole field beneath it (see `_withImages` in
  /// journal_page.dart). With nothing to attach to, the clipboard's image
  /// half is simply invisible to the routing table below and Ctrl+V behaves
  /// like the plain text paste it would have been.
  final String? documentId;

  final MediaFacet facet;

  /// True where the text fields inside this scope are themselves
  /// image-capable, so a text-and-image clipboard lands in both — see
  /// [routeMediaPaste].
  final bool fieldTakesBoth;

  /// True where this scope is one of several on the page and only a focused
  /// field says which gallery a pasted image belongs to — see
  /// [routeMediaPaste].
  final bool requireFocusedField;

  /// Injectable only so a test can drive the routing without a platform
  /// clipboard behind it.
  final MediaClipboard clipboard;

  final Widget child;

  @override
  ConsumerState<MediaPasteScope> createState() => _MediaPasteScopeState();
}

class _MediaPasteScopeState extends ConsumerState<MediaPasteScope> {
  /// Guards a second paste arriving while the first is still decoding, which
  /// is a keystroke away when Ctrl+V repeats.
  var _busy = false;

  /// The focused text field, if the keystroke landed in one.
  ///
  /// The same test `EnterToSubmitScope` uses: the focus node of a text field
  /// sits inside its [EditableText], so an ancestor lookup from the focused
  /// context is what distinguishes a caret from a button or a bare scope.
  BuildContext? _focusedField() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return null;
    return focused.findAncestorWidgetOfExactType<EditableText>() == null
        ? null
        : focused;
  }

  Future<void> _handlePaste() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    // Captured before the clipboard is read, so the paste is routed by what
    // had focus when the key went down rather than by whatever has it a few
    // frames later.
    final field = _focusedField();

    final offer = await widget.clipboard.peek();
    if (!mounted) return;
    switch (routeMediaPaste(
      hasImage: offer.hasImage && widget.documentId != null,
      hasText: offer.hasText,
      intoTextField: field != null,
      fieldTakesBoth: widget.fieldTakesBoth,
      requireFocusedField: widget.requireFocusedField,
    )) {
      case MediaPasteRoute.ignore:
        return;
      case MediaPasteRoute.text:
        // This scope sits between the field and Flutter's own text-editing
        // shortcuts, so the keystroke was already swallowed here and has to
        // be handed on by hand.
        if (field!.mounted) _pasteText(field);
      case MediaPasteRoute.both:
        // The text half first, so it lands where the caret still is: the
        // attach below is asynchronous and the gallery repainting under the
        // field can take the focus off it.
        if (field!.mounted) _pasteText(field);
        await _attachFromClipboard(messenger, overlay);
      case MediaPasteRoute.attach:
        await _attachFromClipboard(messenger, overlay);
    }
  }

  /// Hands the text half of the paste to [field].
  ///
  /// A prose field takes it through [pasteProse], which turns rich HTML into
  /// Voyager's markers (EMPHASIS_FORMATTING.md §7); anything else gets the
  /// [PasteTextIntent] the field installed for itself. Invoked from the
  /// field's own context either way, since this scope is above the action.
  void _pasteText(BuildContext field) {
    final editable = field.findAncestorStateOfType<EditableTextState>();
    if (editable != null && ProsePasteScope.enabledAt(field)) {
      unawaited(pasteProse(editable));
      return;
    }
    Actions.maybeInvoke(
      field,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
  }

  /// The image half of a paste a field has kept Ctrl+V for — a Vim field in
  /// Normal mode, which pastes the text half itself. Attaches the clipboard's
  /// image wherever [_handlePaste] would have from the same field.
  Future<void> _pasteImage() async {
    if (_busy || widget.documentId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    final offer = await widget.clipboard.peek();
    if (!mounted) return;
    switch (routeMediaPaste(
      hasImage: offer.hasImage,
      hasText: offer.hasText,
      intoTextField: true,
      fieldTakesBoth: widget.fieldTakesBoth,
      requireFocusedField: widget.requireFocusedField,
    )) {
      case MediaPasteRoute.attach || MediaPasteRoute.both:
        await _attachFromClipboard(messenger, overlay);
      case MediaPasteRoute.text || MediaPasteRoute.ignore:
        return;
    }
  }

  /// Reads the clipboard's image and attaches it to this scope's owner.
  Future<void> _attachFromClipboard(
    ScaffoldMessengerState messenger,
    OverlayState overlay,
  ) async {
    final documentId = widget.documentId;
    // Unreachable: an ownerless scope routes every paste away from the
    // gallery above, so this is only ever called with a row to attach to.
    if (documentId == null) return;
    _busy = true;
    try {
      final bytes = (await widget.clipboard.read()).imageBytes;
      if (bytes == null || !mounted) return;
      await attachImagesForOwner(
        ref,
        messenger: messenger,
        overlay: overlay,
        images: [bytes],
        collection: widget.collection,
        documentId: documentId,
        facet: widget.facet,
      );
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MediaPasteOwnerScope(
      pasteImage: _pasteImage,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyV, control: true):
              _PasteMediaIntent(),
          SingleActivator(LogicalKeyboardKey.keyV, meta: true):
              _PasteMediaIntent(),
        },
        child: Actions(
          actions: {
            _PasteMediaIntent: CallbackAction<_PasteMediaIntent>(
              onInvoke: (_) {
                unawaited(_handlePaste());
                return null;
              },
            ),
          },
          // A shortcut is only offered the key when the focus is *inside* it,
          // and opening an editor focuses nothing, so without this the feature
          // would need a click first — the very thing it exists to avoid.
          // `autofocus` and not a `requestFocus` because it must not take focus
          // away from a field the user is already typing in elsewhere: it
          // claims focus only when nothing in the enclosing scope holds it.
          child: FocusScope(autofocus: true, child: widget.child),
        ),
      ),
    );
  }
}

/// Marks the subtree in which [MediaPasteScope] already owns Ctrl+V.
///
/// A prose field claims that key for smart paste (EMPHASIS_FORMATTING.md §7),
/// and its own [Focus] sits *below* this scope's [Shortcuts], so it would win
/// the key and a pasted screenshot would never reach the gallery. Inside this
/// marker the field leaves the key alone and the scope routes the text half
/// through [pasteProse] instead — same behaviour, one owner.
///
/// The exception is a Vim field outside Insert mode, which keeps Ctrl+V for
/// its own text paste and hands the image half back through [pasteImage].
class MediaPasteOwnerScope extends InheritedWidget {
  const MediaPasteOwnerScope({
    super.key,
    required this.pasteImage,
    required super.child,
  });

  /// Attaches the clipboard's image, if any, to the enclosing scope's gallery
  /// — by the same rules as a paste the scope handles itself.
  final Future<void> Function() pasteImage;

  static MediaPasteOwnerScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaPasteOwnerScope>();

  @override
  bool updateShouldNotify(MediaPasteOwnerScope oldWidget) => false;
}

/// Intent for the editor-wide paste, so Ctrl+V is bound through the shortcut
/// system rather than a raw key listener that would fight the text fields
/// inside it.
class _PasteMediaIntent extends Intent {
  const _PasteMediaIntent();
}
