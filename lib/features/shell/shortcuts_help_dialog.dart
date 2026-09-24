import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/settings_models.dart';

typedef ShortcutHelpEntry = ({String keys, String action});
typedef ShortcutHelpSection = ({String title, List<ShortcutHelpEntry> entries});

/// Every shortcut the app handles, grouped by where it works. The
/// user-configurable ones are read from [settings] so the list shows the
/// bindings actually in effect.
List<ShortcutHelpSection> shortcutHelpSections(AppSettings settings) {
  final globalHotkeys = <ShortcutHelpEntry>[
    if (settings.journalHotkey.isNotEmpty)
      (keys: settings.journalHotkey, action: 'Quick journal entry'),
    if (settings.todoHotkey.isNotEmpty)
      (keys: settings.todoHotkey, action: 'Quick to-do'),
    if (settings.financeHotkey.isNotEmpty)
      (keys: settings.financeHotkey, action: 'Quick transaction'),
    if (settings.reminderHotkey.isNotEmpty)
      (keys: settings.reminderHotkey, action: 'Quick reminder'),
  ];
  final expandKey = switch (settings.snippetExpandKey) {
    SnippetExpandKey.tab => 'Tab',
    SnippetExpandKey.space => 'Space',
  };

  return [
    (
      title: 'General',
      entries: [
        (keys: 'Ctrl+/', action: 'Show this list'),
        (keys: 'Ctrl+Tab', action: 'Next section'),
        (keys: 'Ctrl+Shift+Tab', action: 'Previous section'),
        (keys: 'Ctrl+Enter', action: 'Save the open form'),
      ],
    ),
    if (globalHotkeys.isNotEmpty)
      (title: 'Anywhere in Windows', entries: globalHotkeys),
    (
      title: 'Text editing',
      entries: [
        (keys: 'Tab / Shift+Tab', action: 'Indent / outdent a list item'),
        (keys: expandKey, action: 'Expand a snippet'),
        (keys: 'Ctrl+V', action: 'Paste an image'),
      ],
    ),
    (
      title: 'Calendar',
      entries: [
        (
          keys:
              '← / →, ${settings.calendarNavigateLeftKey} / '
              '${settings.calendarNavigateRightKey}',
          action: 'Previous / next period',
        ),
      ],
    ),
    (
      title: 'To-Do',
      entries: [
        (keys: 'Ctrl+F', action: 'Search the list'),
        (keys: 'Enter / Shift+Enter', action: 'Next / previous match'),
        (keys: 'Esc', action: 'Close search'),
      ],
    ),
    (
      title: 'Study & LeetCode sessions',
      entries: [
        (keys: 'Space', action: 'Flip the card'),
        (keys: settings.srsFailKey, action: 'Grade: fail'),
        (keys: settings.srsHardKey, action: 'Grade: hard'),
        (keys: settings.srsGoodKey, action: 'Grade: good'),
        (keys: settings.srsEasyKey, action: 'Grade: easy'),
        (keys: 'U / R', action: 'Back / forward through the session'),
        (keys: 'C', action: 'Focus the scratch pad'),
        (keys: '← / →', action: 'Cram: fail / pass'),
        (keys: 'Ctrl+Shift+C', action: 'LeetCode cheat sheet'),
      ],
    ),
    (
      title: 'Image viewer',
      entries: [
        (keys: '← / →', action: 'Previous / next image'),
        (keys: 'Esc', action: 'Close'),
      ],
    ),
  ];
}

Future<void> showShortcutsHelpDialog(
  BuildContext context,
  AppSettings settings,
) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) => CallbackShortcuts(
      // The same chord closes it, so it works as a toggle.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.slash, control: true): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          title: const Text('Keyboard shortcuts'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final section in shortcutHelpSections(settings))
                    _ShortcutSection(section: section),
                ],
              ),
            ),
          ),
          actions: [
            GlassButton(
              onPressed: () => Navigator.pop(context),
              label: 'Close',
              dense: true,
            ),
          ],
        ),
      ),
    ),
  );
}

class _ShortcutSection extends StatelessWidget {
  const _ShortcutSection({required this.section});

  final ShortcutHelpSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            section.title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          for (final entry in section.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.action,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    entry.keys,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
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
