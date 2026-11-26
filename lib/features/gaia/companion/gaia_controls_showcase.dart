import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controls.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// The debug menu's look at Gaia's own controls, each live: the card
/// dropdown, the slider, the checkbox, the progress bar and the dialogs.
class GaiaControlsShowcase extends StatefulWidget {
  const GaiaControlsShowcase({super.key});

  @override
  State<GaiaControlsShowcase> createState() => _GaiaControlsShowcaseState();
}

class _GaiaControlsShowcaseState extends State<GaiaControlsShowcase> {
  String? _list = 'groceries';
  var _mood = 6.0;
  var _volume = 0.4;
  var _checked = true;
  var _usage = [0.18, 0.62, 0.94];
  final _random = math.Random();

  static const _lists = [
    (value: 'inbox', label: 'Inbox'),
    (value: 'groceries', label: 'Groceries'),
    (value: 'work', label: 'Work'),
    (value: 'reading', label: 'Reading list'),
  ];

  static const _windows = ['5 hour', 'Weekly', 'Opus'];

  Future<void> _dialog(Widget Function(BuildContext context) build) =>
      showDialog<void>(context: context, builder: build);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget section(String title, String note, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: GaiaInk.bright,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(note, style: muted),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
    Widget checkRow(String label, bool value, ValueChanged<bool>? onChanged) =>
        Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            borderRadius: BorderRadius.circular(GaiaRadius.chip),
            onTap: onChanged == null ? null : () => onChanged(!value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IgnorePointer(
                    child: GaiaCheckbox(
                      value: value,
                      onChanged: onChanged == null ? null : (_) {},
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(label, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: gaiaSurface(theme.colorScheme.primary),
        borderRadius: BorderRadius.circular(GaiaRadius.panel),
        border: Border.all(color: GaiaInk.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section(
            'Card dropdown',
            "A proposal's List, Calendar or Journal. Opens a Gaia menu under "
                'it; the edge lights with the aurora while hovered, focused '
                'or open.',
            Row(
              children: [
                Expanded(
                  child: GaiaDropdownField<String>(
                    label: 'List',
                    value: _list,
                    icon: Icons.checklist,
                    options: _lists,
                    onChanged: (list) => setState(() => _list = list),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: GaiaDropdownField<String>(
                    label: 'Disabled',
                    value: 'inbox',
                    options: _lists,
                    onChanged: null,
                  ),
                ),
              ],
            ),
          ),
          section(
            'Slider',
            "A journal entry's mood, snapping to its ten steps, and a "
                'continuous one. Hover, drag, or Tab to it and use the '
                'arrows.',
            Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 60, child: Text('Mood')),
                    Expanded(
                      child: GaiaSlider(
                        value: _mood,
                        max: 10,
                        divisions: 10,
                        onChanged: (mood) => setState(() => _mood = mood),
                      ),
                    ),
                    SizedBox(width: 36, child: Text('${_mood.round()}/10')),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 60, child: Text('Free')),
                    Expanded(
                      child: GaiaSlider(
                        value: _volume,
                        onChanged: (v) => setState(() => _volume = v),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text('${(_volume * 100).round()}%'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          section(
            'Checkbox',
            'In a row that hovers as a rounded box, as the delete-project '
                'dialog and the usage-limit card have it.',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                checkRow(
                  'Also delete its 3 chats',
                  _checked,
                  (checked) => setState(() => _checked = checked),
                ),
                checkRow('Disabled', true, null),
              ],
            ),
          ),
          section(
            'Progress bar',
            "The Setup tab's usage windows. It eases to a new value.",
            Column(
              children: [
                for (final (i, used) in _usage.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        SizedBox(width: 60, child: Text(_windows[i])),
                        Expanded(child: GaiaProgressBar(value: used)),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '${(used * 100).round()}%',
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GaiaButton(
                    label: 'Shuffle',
                    onPressed: () => setState(
                      () => _usage = [
                        for (final _ in _usage) _random.nextDouble(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          section(
            'Dialogs',
            'Frosted, as the menus and the date picker are: the confirm '
                'dialogs, and bare ones such as usage and stats.',
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                GaiaButton(
                  label: 'Confirm',
                  onPressed: () => _dialog(
                    (context) => GaiaDialog(
                      title: const Text('Replace the draft?'),
                      content: const Text(
                        "What's in the composer now, and what's attached to "
                        'it, is lost.\n\nPress Ctrl+Enter to replace.',
                      ),
                      actions: [
                        GaiaButton(
                          label: 'Cancel',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        GaiaButton(
                          label: 'Replace',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ),
                GaiaButton(
                  label: 'Destructive',
                  onPressed: () => _dialog(
                    (context) => StatefulBuilder(
                      builder: (context, setDialogState) => GaiaDialog(
                        title: const Text('Delete "Voyager"?'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _checked
                                  ? 'Its 3 chats will go to the trash with it.'
                                  : 'Its 3 chats will stay, as chats with no '
                                        'project.',
                            ),
                            const SizedBox(height: 8),
                            checkRow('Also delete its 3 chats', _checked, (
                              checked,
                            ) {
                              setState(() => _checked = checked);
                              setDialogState(() {});
                            }),
                          ],
                        ),
                        actions: [
                          GaiaButton(
                            label: 'Cancel',
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          GaiaButton(
                            label: 'Delete',
                            color: Theme.of(context).colorScheme.error,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                GaiaButton(
                  label: 'Bare',
                  onPressed: () => _dialog(
                    (context) => GaiaDialog(
                      maxWidth: 480,
                      content: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Usage',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 16),
                            for (final (i, used) in _usage.indexed) ...[
                              Text(_windows[i]),
                              const SizedBox(height: 6),
                              GaiaProgressBar(value: used),
                              const SizedBox(height: 14),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
