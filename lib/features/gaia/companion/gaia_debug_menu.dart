import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_appear.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_file_card.dart';
import 'package:voyager/features/gaia/companion/gaia_image_thumb.dart';
import 'package:voyager/features/gaia/companion/gaia_offline_icon.dart';
import 'package:voyager/features/gaia/companion/gaia_orb.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_studio.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/companion/gaia_toast_icon_studio.dart';
import 'package:voyager/features/gaia/companion/gaia_vanish.dart';

/// Gaia's debug menu (Ctrl+Shift+D, or the sidebar's bug): scripted
/// replies, toast and loading-animation previews and display toggles, kept
/// on this desktop only.
Future<void> showGaiaDebugMenu(
  BuildContext context,
  GaiaController controller,
) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: ListenableBuilder(
        listenable: Listenable.merge([controller, controller.debug]),
        builder: (context, _) => _DebugMenu(controller: controller),
      ),
    ),
  ),
);

class _DebugMenu extends StatelessWidget {
  const _DebugMenu({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final debug = controller.debug;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final speedIndex = kGaiaDebugStreamSpeeds.indexOf(debug.streamSpeed);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
      child: Text(text, style: theme.textTheme.titleSmall),
    );
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Gaia debug', style: theme.textTheme.titleMedium),
            ),
            GaiaButton(
              icon: Icons.close,
              size: 32,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        Text('Kept on this desktop, never synced.', style: muted),
        heading('Orb studio'),
        const GaiaOrbStudio(),
        heading('Thinking and replying studies'),
        const GaiaOrbMotionStudies(),
        heading('Astral message animations'),
        Text(
          'The live chat orb. Its white orbits become the model arcs while '
          'gold beads spiral into the centre. A new message opens them again.',
          style: muted,
        ),
        const GaiaOrbMessagePreview(),
        heading('Replies'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Scripted replies'),
          subtitle: const Text(
            'A message that is one of the commands below gets a canned reply '
            'instead of a Claude Code run: no tokens. The chat is saved like '
            'any other.',
          ),
          value: debug.scriptedReplies,
          onChanged: debug.setScriptedReplies,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Dummy mode'),
          subtitle: const Text(
            'Every other message gets the same canned reply. Nothing reaches '
            'a provider: no agent run, no routing, no titles.',
          ),
          value: debug.dummyMode,
          onChanged: debug.setDummyMode,
        ),
        _SliderRow(
          label: 'Wait before replying',
          value: debug.replyDelay.inMilliseconds / 1000,
          max: 10,
          divisions: 20,
          display:
              '${(debug.replyDelay.inMilliseconds / 1000).toStringAsFixed(1)} s',
          onChanged: (seconds, {required save}) => debug.setReplyDelay(
            Duration(milliseconds: (seconds * 1000).round()),
            save: save,
          ),
        ),
        _SliderRow(
          label: 'Streaming speed',
          value: speedIndex.toDouble(),
          max: kGaiaDebugStreamSpeeds.length - 1.0,
          divisions: kGaiaDebugStreamSpeeds.length - 1,
          display: '${debug.streamSpeed} chars/s',
          onChanged: (index, {required save}) => debug.setStreamSpeed(
            kGaiaDebugStreamSpeeds[index.round()],
            save: save,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          debug.scriptedReplies
              ? 'Click one to send it to the open chat.'
              : 'Turn scripted replies on to use these.',
          style: muted,
        ),
        for (final MapEntry(:key, :value) in gaiaDebugScripts.entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            enabled: debug.scriptedReplies && !controller.currentRunning,
            title: Text(key, style: const TextStyle(fontFamily: 'monospace')),
            subtitle: Text(value.description),
            onTap: () {
              Navigator.of(context).pop();
              controller.send(key);
            },
          ),
        heading('Sending images and files'),
        Text(
          "A message shows as soon as it's sent. Its images stay dimmed under "
          "a spinner until they're attached, then Gaia's reply starts. Files "
          'and folders go by path, so they show at once.',
          style: muted,
        ),
        const _UploadPreview(),
        _SliderRow(
          label: 'Wait to attach',
          value: debug.attachDelay.inMilliseconds / 1000,
          max: 10,
          divisions: 20,
          display:
              '${(debug.attachDelay.inMilliseconds / 1000).toStringAsFixed(1)} s',
          onChanged: (seconds, {required save}) => debug.setAttachDelay(
            Duration(milliseconds: (seconds * 1000).round()),
            save: save,
          ),
        ),
        Text(
          'Holds each image of a real send this long before attaching it, to '
          'watch it upload in the chat.',
          style: muted,
        ),
        heading('Attachments vanishing'),
        Text(
          "Sent, a draft's images, files and folders dissolve from right to "
          'left like its text, and their row closes behind them. Pick a count '
          'to draft that many images again.',
          style: muted,
        ),
        const _ImageVanishPreview(),
        heading('Messages appearing'),
        Text(
          'Sent, a message gathers into the chat out of particles, swept from '
          'left to right: its text and attachments, but not its bubble. Pick '
          'a message to send it again.',
          style: muted,
        ),
        const _AppearPreview(),
        heading('Toast icon studies'),
        const GaiaToastIconStudio(),
        heading('Toasts'),
        Text(
          "Gaia's own toast, shown now. Hover holds it; a click dismisses it.",
          style: muted,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            GaiaButton(
              label: 'Done',
              onPressed: () => showGaiaToast(
                context,
                mark: GaiaToastMark.done,
                title: 'Gaia is done',
                body:
                    'Debug chat: Fixed. dispose now cancels the timer, and all '
                    '48 tests pass.',
              ),
            ),
            GaiaButton(
              label: 'Question',
              onPressed: () => showGaiaToast(
                context,
                mark: GaiaToastMark.question,
                title: 'Gaia has a question',
                body: 'Debug chat: Which would you rather I do?',
              ),
            ),
            GaiaButton(
              label: 'Error',
              onPressed: () => showGaiaToast(
                context,
                mark: GaiaToastMark.error,
                title: 'Gaia ran into an error',
                body: 'Debug chat: Claude Code exited (code 1)',
              ),
            ),
            GaiaButton(
              label: 'Long',
              onPressed: () => showGaiaToast(
                context,
                mark: GaiaToastMark.info,
                title: 'A toast with a long body',
                body:
                    'It runs well past two lines, so the end of it should '
                    'be cut off with an ellipsis rather than growing the '
                    'toast any taller than two lines of body text allow.',
              ),
            ),
          ],
        ),
        heading('Offline icon'),
        Text(
          "In the header once the next tier's CLI has failed to reach its "
          'servers twice in a row. Hover for its tooltip; a click checks '
          'again, here for a second.',
          style: muted,
        ),
        const _OfflinePreview(),
        heading('Display'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show FPS counter'),
          subtitle: const Text(
            "Gaia's rendered frame rate and a five-minute graph, as on "
            "Voyager's Dev page.",
          ),
          value: debug.showFps,
          onChanged: debug.setShowFps,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Slow animations'),
          subtitle: const Text('Every animation at a tenth of its speed.'),
          value: debug.slowAnimations,
          onChanged: debug.setSlowAnimations,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow screenshots'),
          subtitle: const Text(
            "Gaia shows in screenshots, screen recordings and screen shares, "
            "which it's hidden from otherwise.",
          ),
          value: debug.allowScreenshots,
          onChanged: debug.setAllowScreenshots,
        ),
      ],
    );
  }
}

/// Attached to the previews' messages: never read, so they needn't exist.
const _files = [
  GaiaFilePart(path: r'C:\Users\Gaia\Documents\Quarterly report.pdf'),
  GaiaFilePart(path: r'C:\Users\Gaia\Documents\notes.md'),
  GaiaFilePart(path: r'C:\Users\Gaia\Pictures\Screenshots', folder: true),
];

/// A sent message with two images, uploading and then attached, and
/// [_files].
class _UploadPreview extends StatefulWidget {
  const _UploadPreview();

  @override
  State<_UploadPreview> createState() => _UploadPreviewState();
}

class _UploadPreviewState extends State<_UploadPreview> {
  late final Future<String?> _image = _paintImage();
  var _uploading = true;
  Timer? _done;

  @override
  void initState() {
    super.initState();
    _finishLater();
  }

  @override
  void dispose() {
    _done?.cancel();
    unawaited(
      _image.then((path) => File(path!).delete()).then((_) {}, onError: (_) {}),
    );
    super.dispose();
  }

  void _send() {
    setState(() => _uploading = true);
    _finishLater();
  }

  void _finishLater() {
    _done?.cancel();
    _done = Timer(const Duration(milliseconds: 2500) * timeDilation, () {
      if (mounted) setState(() => _uploading = false);
    });
  }

  /// A dusk sky with a sun, in a file of this preview's own (deleted with
  /// it) that the thumbnails can read.
  static Future<String?> _paintImage() async {
    const size = Size(160, 110);
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2B3A78), Color(0xFFE39A5B)],
          ).createShader(Offset.zero & size),
      )
      ..drawCircle(
        const Offset(112, 74),
        18,
        Paint()..color = const Color(0xFFFFE2A8),
      );
    final image = await recorder.endRecording().toImage(160, 110);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'gaia-debug-image-$pid-${DateTime.now().microsecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(png!.buffer.asUint8List());
    return file.path;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final label in [1, 2])
                    GaiaImageThumb(
                      file: _image,
                      label: label,
                      height: 96,
                      uploading: _uploading,
                    ),
                  for (final file in _files)
                    GaiaFileCard(file: file, height: 56),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.92,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text("What's different between these two?"),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: GaiaButton(
            icon: Icons.send,
            label: 'Send again',
            onPressed: _send,
          ),
        ),
      ],
    );
  }
}

/// The header with its offline icon, whose check never reaches anything.
class _OfflinePreview extends StatefulWidget {
  const _OfflinePreview();

  @override
  State<_OfflinePreview> createState() => _OfflinePreviewState();
}

class _OfflinePreviewState extends State<_OfflinePreview> {
  var _retrying = false;
  Timer? _done;

  @override
  void dispose() {
    _done?.cancel();
    super.dispose();
  }

  void _retry() {
    setState(() => _retrying = true);
    _done = Timer(const Duration(seconds: 1) * timeDilation, () {
      if (mounted) setState(() => _retrying = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(child: Text('New chat', style: theme.textTheme.titleSmall)),
          GaiaOfflineIcon(
            cli: 'Claude Code',
            retrying: _retrying,
            onRetry: _retry,
          ),
        ],
      ),
    );
  }
}

/// The composer's draft images, as many as picked, and [_files], vanishing
/// as they're sent.
class _ImageVanishPreview extends StatefulWidget {
  const _ImageVanishPreview();

  @override
  State<_ImageVanishPreview> createState() => _ImageVanishPreviewState();
}

class _ImageVanishPreviewState extends State<_ImageVanishPreview> {
  static const _counts = [1, 2, 5, 10];

  static const _prompt = "What's different between these?";

  late final Future<String?> _image = _UploadPreviewState._paintImage();
  final _vanish = GlobalKey<GaiaVanishState>();
  final _textVanish = GlobalKey<GaiaVanishState>();
  final _text = TextEditingController(text: _prompt);
  final _focus = FocusNode();
  var _count = 1;
  var _drafted = true;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    unawaited(
      _image.then((path) => File(path!).delete()).then((_) {}, onError: (_) {}),
    );
    super.dispose();
  }

  /// Like the composer: the images and the text vanish under one sweep.
  void _send() {
    GaiaVanishState.vanishTogether([
      if (_drafted) _vanish.currentState!,
      if (_text.text.isNotEmpty) _textVanish.currentState!,
    ]);
    _text.clear();
    setState(() => _drafted = false);
  }

  void _draft(int count) {
    setState(() {
      _count = count;
      _drafted = true;
    });
    if (_text.text.isEmpty) _text.text = _prompt;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        // Tall enough for four rows, the composer's bottom at the bottom.
        Container(
          height: 344,
          padding: const EdgeInsets.all(16),
          alignment: Alignment.bottomCenter,
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GaiaVanish(
                key: _vanish,
                refilled: _drafted,
                builder: (context, _) => !_drafted
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var label = 1; label <= _count; label++)
                              GaiaImageThumb(
                                file: _image,
                                label: label,
                                height: 56,
                              ),
                            for (final file in _files)
                              GaiaFileCard(file: file, height: 56),
                          ],
                        ),
                      ),
              ),
              GaiaVanish(
                key: _textVanish,
                controller: _text,
                builder: (context, vanishing) => GaiaTextField(
                  controller: _text,
                  focusNode: _focus,
                  minLines: vanishing ? null : 1,
                  maxLines: vanishing ? null : 3,
                  expands: vanishing,
                  textAlignVertical: vanishing ? TextAlignVertical.top : null,
                  hintText: vanishing ? null : 'Message Gaia',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final count in _counts)
              ChoiceChip(
                label: Text(count == 1 ? '1 image' : '$count images'),
                selected: _drafted && count == _count,
                onSelected: (_) => _draft(count),
              ),
            GaiaButton(icon: Icons.send, label: 'Send', onPressed: _send),
          ],
        ),
      ],
    );
  }
}

/// What one of [_AppearPreview]'s messages carries.
typedef _AppearScenario = ({
  int images,
  bool uploading,
  bool files,
  String text,
});

const _longPrompt =
    'Can you go through the onboarding flow again and tell me where people '
    'are most likely to drop off? I think the second screen asks for too '
    "much at once, but I'm not sure splitting it wouldn't make the whole "
    'thing feel longer. Any numbers you can pull from last month would help '
    'too.';

const _appearScenarios = <String, _AppearScenario>{
  'Short text': (images: 0, uploading: false, files: false, text: 'Hi Gaia!'),
  'Long text': (images: 0, uploading: false, files: false, text: _longPrompt),
  'One image': (images: 1, uploading: false, files: false, text: ''),
  'Images only': (images: 3, uploading: false, files: false, text: ''),
  'Files only': (images: 0, uploading: false, files: true, text: ''),
  'Image and text': (
    images: 1,
    uploading: false,
    files: false,
    text: "What's wrong with this layout?",
  ),
  'Files and text': (
    images: 0,
    uploading: false,
    files: true,
    text: 'Summarise these for me.',
  ),
  'Still uploading': (
    images: 2,
    uploading: true,
    files: false,
    text: "What's different between these two?",
  ),
  'Many images': (
    images: 6,
    uploading: false,
    files: false,
    text: 'Which of these reads best?',
  ),
  'Everything': (images: 2, uploading: false, files: true, text: _longPrompt),
};

/// A sent message on the chat's background, laid out as in the chat,
/// gathering in each time one's picked.
class _AppearPreview extends StatefulWidget {
  const _AppearPreview();

  @override
  State<_AppearPreview> createState() => _AppearPreviewState();
}

class _AppearPreviewState extends State<_AppearPreview> {
  late final Future<String?> _image = _UploadPreviewState._paintImage();
  var _scenario = _appearScenarios.keys.first;

  /// Bumped to send again: a new [GaiaAppear] gathers in afresh.
  var _sends = 0;

  @override
  void dispose() {
    unawaited(
      _image.then((path) => File(path!).delete()).then((_) {}, onError: (_) {}),
    );
    super.dispose();
  }

  void _send(String scenario) => setState(() {
    _scenario = scenario;
    _sends++;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (:images, :uploading, :files, :text) = _appearScenarios[_scenario]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        // Tall enough for most scenarios, growing for the rest, sent to the
        // bottom.
        Container(
          constraints: const BoxConstraints(minHeight: 380),
          padding: const EdgeInsets.all(16),
          alignment: Alignment.bottomRight,
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: GaiaAppear(
            key: ValueKey(_sends),
            play: _sends > 0,
            ready: images == 0
                ? null
                : () => GaiaImageThumb.precache(context, _image, 96),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (images > 0 || files)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, bottom: 8),
                    child: GaiaAppearPart(
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var label = 1; label <= images; label++)
                            GaiaImageThumb(
                              file: _image,
                              label: label,
                              height: 96,
                              uploading: uploading,
                            ),
                          if (files)
                            for (final file in _files)
                              GaiaFileCard(file: file, height: 56),
                        ],
                      ),
                    ),
                  ),
                if (text.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(left: 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: GaiaAppearPart(child: SelectableText(text)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final scenario in _appearScenarios.keys)
              ChoiceChip(
                label: Text(scenario),
                selected: scenario == _scenario,
                onSelected: (_) => _send(scenario),
              ),
            GaiaButton(
              icon: Icons.replay,
              label: 'Send again',
              onPressed: () => _send(_scenario),
            ),
          ],
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    this.min = 0,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;

  /// Saved only once the drag ends: [save] is false along the way.
  final void Function(double value, {required bool save}) onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 150, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (value) => onChanged(value, save: false),
            onChangeEnd: (value) => onChanged(value, save: true),
          ),
        ),
        SizedBox(width: 90, child: Text(display, textAlign: TextAlign.end)),
      ],
    );
  }
}

/// A live [GaiaOrb] on the chat's own background, then a reply ending in
/// each tier's glyph.
class GaiaOrbMessagePreview extends StatefulWidget {
  const GaiaOrbMessagePreview({super.key});

  @override
  State<GaiaOrbMessagePreview> createState() => _GaiaOrbMessagePreviewState();
}

/// Sizes worth a look: the smallest gap a chat leaves, the chat's orb and
/// the reference's.
const _orbPresets = {
  'Smallest gap': 28.0,
  'Chat': kGaiaOrbSize,
  'Large': 168.0,
};

class _GaiaOrbMessagePreviewState extends State<GaiaOrbMessagePreview> {
  var _state = GaiaOrbState.thinking;
  var _tier = GaiaTier.standard;
  var _size = kGaiaOrbSize;

  /// The tier demos are showing a reply, until [_replay]'s timer ends it.
  var _replying = false;
  Timer? _end;

  /// The chat demo's orb, which reply it's on (0 the last, 1 the new one,
  /// null neither) and what it's showing.
  var _turnKey = GlobalKey();
  int? _turnAt;
  var _turnState = GaiaOrbState.glyph;
  final _turnTimers = <Timer>[];
  var _turnGeneration = 0;

  @override
  void dispose() {
    _end?.cancel();
    for (final timer in _turnTimers) {
      timer.cancel();
    }
    super.dispose();
  }

  /// A first message: a new orb on the new reply.
  void _appear() => _turn(() {
    _turnKey = GlobalKey();
    _turnAt = 1;
  });

  /// A next message: the last reply's glyph carried on to the new one.
  void _send() {
    _turn(() {
      _turnKey = GlobalKey();
      _turnAt = 0;
      _turnState = GaiaOrbState.glyph;
    }, start: false);
    final generation = _turnGeneration;
    // Once it's shown as the last reply's glyph.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _turnGeneration) _turn(() => _turnAt = 1);
    });
  }

  /// [change]s the chat demo, then, unless not to [start], plays a reply on
  /// its new reply.
  void _turn(VoidCallback change, {bool start = true}) {
    _turnGeneration++;
    for (final timer in _turnTimers) {
      timer.cancel();
    }
    _turnTimers.clear();
    setState(() {
      change();
      if (start) _turnState = GaiaOrbState.thinking;
    });
    if (!start) return;
    // Scaled by [timeDilation] so slow animations get the whole reply.
    void at(int ms, GaiaOrbState state) => _turnTimers.add(
      Timer(Duration(milliseconds: ms) * timeDilation, () {
        if (mounted) setState(() => _turnState = state);
      }),
    );
    at(1500, GaiaOrbState.speaking);
    at(3500, GaiaOrbState.glyph);
  }

  void _setTurnState(GaiaOrbState state) =>
      _turn(() => _turnState = state, start: false);

  void _replay() {
    _end?.cancel();
    setState(() => _replying = true);
    _end = Timer(const Duration(milliseconds: 2500) * timeDilation, () {
      if (mounted) setState(() => _replying = false);
    });
  }

  Widget _stage({required double height, required Widget child}) => Container(
    height: height,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );

  Wrap _chips<T>(Map<String, T> options, T selected, ValueChanged<T> onPick) =>
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final MapEntry(key: name, :value) in options.entries)
            ChoiceChip(
              label: Text(name),
              selected: value == selected,
              onSelected: (_) => setState(() => onPick(value)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _stage(
          height: 184,
          child: GaiaOrb(state: _state, tier: _tier.index, size: _size),
        ),
        const SizedBox(height: 8),
        _chips(
          {
            'Thinking': GaiaOrbState.thinking,
            'Replying': GaiaOrbState.speaking,
            'Model mark': GaiaOrbState.glyph,
          },
          _state,
          (state) => _state = state,
        ),
        const SizedBox(height: 6),
        _chips(
          {for (final tier in GaiaTier.values) tier.label: tier},
          _tier,
          (tier) => _tier = tier,
        ),
        const SizedBox(height: 6),
        _chips(
          {
            for (final MapEntry(key: name, value: size) in _orbPresets.entries)
              '$name (${size.round()} px)': size,
          },
          _size,
          (size) => _size = size,
        ),
        _SliderRow(
          label: 'Size',
          value: _size,
          min: 24,
          max: 168,
          divisions: 18,
          display: '${_size.round()} px',
          onChanged: (size, {required save}) => setState(() => _size = size),
        ),
        const SizedBox(height: 8),
        Text(
          'Finish a reply to fold the orb into its model mark.',
          style: muted,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: GaiaButton(
            icon: Icons.replay,
            label: 'Replay reply',
            onPressed: _replay,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final tier in GaiaTier.values) ...[
              if (tier.index > 0) const SizedBox(width: 8),
              Expanded(
                child: Column(
                  children: [
                    _stage(
                      height: 72,
                      child: GaiaOrb(
                        state: _replying
                            ? GaiaOrbState.speaking
                            : GaiaOrbState.glyph,
                        tier: tier.index,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tier.label,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'A first message opens from light. A new message carries the '
          'previous model mark to the next reply and opens its rings again.',
          style: muted,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            GaiaButton(
              icon: Icons.auto_awesome,
              label: 'First message',
              onPressed: _appear,
            ),
            GaiaButton(
              icon: Icons.send,
              label: 'New message',
              onPressed: _send,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            GaiaButton(
              icon: Icons.chat_bubble_outline,
              label: 'Start reply',
              onPressed: _turnAt == null
                  ? null
                  : () => _setTurnState(GaiaOrbState.speaking),
            ),
            GaiaButton(
              icon: Icons.check,
              label: 'Finish reply',
              onPressed: _turnAt == null
                  ? null
                  : () => _setTurnState(GaiaOrbState.glyph),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _stage(
          height: 168,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _turnRow(0),
                Align(
                  alignment: Alignment.centerRight,
                  child: _line(width: 120, height: 26),
                ),
                _turnRow(1),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A reply's slot in the chat demo, with the orb when it's [_turnAt].
  Widget _turnRow(int slot) => Row(
    children: [
      SizedBox.square(
        dimension: kGaiaOrbSize,
        child: _turnAt == slot
            ? GaiaOrb(key: _turnKey, state: _turnState, tier: _tier.index)
            : null,
      ),
      Flexible(child: _line(width: 180, height: 10)),
    ],
  );

  /// A message stood in for by a bar.
  Widget _line({required double width, required double height}) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );
}
