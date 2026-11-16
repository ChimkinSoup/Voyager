import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sound/app_sounds.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

/// The quick-note hotkey's floater: a new quick reminder in the Inbox, typed
/// as in the Inbox's own field. Enter adds it, Shift+Enter breaks a line,
/// and the text is kept across dismissals until it's added.
class NoteFloater extends ConsumerStatefulWidget {
  const NoteFloater({super.key});

  @override
  ConsumerState<NoteFloater> createState() => _NoteFloaterState();
}

class _NoteFloaterState extends ConsumerState<NoteFloater> {
  late final TextEditingController _text;
  final _focus = FocusNode();
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: ref.read(noteCaptureDraftProvider))
      ..addListener(_keepDraft);
    _focus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if ((event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
          !HardwareKeyboard.instance.isShiftPressed) {
        unawaited(_save());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _text
      ..removeListener(_keepDraft)
      ..dispose();
    _focus.dispose();
    super.dispose();
  }

  void _keepDraft() =>
      ref.read(noteCaptureDraftProvider.notifier).state = _text.text;

  /// Added as the Inbox's field adds one.
  Future<void> _save() async {
    if (_saving) return;
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _saving = true;
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final now = utcNow();
      await container
          .read(notificationRepositoryProvider)
          .upsertPinnedNote(
            PinnedNote(id: newId(), text: text, createdAt: now, updatedAt: now),
          );
      container.invalidate(pinnedNotesProvider);
      container.read(noteCaptureDraftProvider.notifier).state = '';
      container.read(appSoundsProvider).play(AppSound.saved);
      await container
          .read(floaterControllerProvider)
          .completeWith('Added to the Inbox');
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'NoteFloater',
          context: ErrorDescription('while adding a quick note'),
        ),
      );
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: FloaterAppIcon(PhosphorIconsRegular.tray, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: VoyagerTextField(
              controller: _text,
              focusNode: _focus,
              autofocus: true,
              style: theme.textTheme.titleMedium,
              // Multiline so Shift+Enter can break a line; plain Enter is
              // caught by [_focus.onKeyEvent] and adds the note.
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'Type a quick reminder…',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
