import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

/// Gaia's debug menu (Ctrl+Shift+D, or the sidebar's bug): scripted
/// replies, toast previews and display toggles, kept on this desktop only.
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
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
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
            value: value.clamp(0, max),
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
