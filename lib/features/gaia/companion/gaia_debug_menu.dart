import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_orb.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_studio.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

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
                icon: Icons.check_circle_outline,
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
                icon: Icons.help_outline,
                title: 'Gaia has a question',
                body: 'Debug chat: Which would you rather I do?',
              ),
            ),
            GaiaButton(
              label: 'Error',
              onPressed: () => showGaiaToast(
                context,
                icon: Icons.error_outline,
                iconColor: Theme.of(context).colorScheme.error,
                title: 'Gaia ran into an error',
                body: 'Debug chat: Claude Code exited (code 1)',
              ),
            ),
            GaiaButton(
              label: 'Long',
              onPressed: () => showGaiaToast(
                context,
                icon: Icons.info_outline,
                title: 'A toast with a long body',
                body:
                    'It runs well past two lines, so the end of it should '
                    'be cut off with an ellipsis rather than growing the '
                    'toast any taller than two lines of body text allow.',
              ),
            ),
          ],
        ),
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
