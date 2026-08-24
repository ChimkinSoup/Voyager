import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/snippets/snippet_settings_launcher.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/snippet_editor.dart';
import 'package:voyager/domain/models/snippet.dart';

/// Wide enough for the Trigger/Replacement pair and the two option
/// checkboxes to sit on the rows they do in settings, without the popover
/// growing into a second dialog.
const double _panelWidth = 560.0;

/// How the quick-add popover was closed, which decides what happens to the
/// field behind it.
enum _QuickAddOutcome { saved, manage }

/// Opens the "Add snippet" popover over [anchor] (a global position — the
/// point that was right-clicked), prefilled with [trigger].
///
/// The one-field cousin of `showSnippetsDialog`: same form, same validation,
/// no list and no global settings. On a successful save it confirms with a
/// toast and hands focus back to [restoreFocus] — the field the trigger was
/// taken from — as it does when the popover is cancelled or dismissed.
///
/// [context] must belong to the field itself (not to the context menu that
/// opened this, which is torn down on the way in), since it is what the
/// popover route, the toast and the settings dialog are all opened against.
Future<void> showQuickAddSnippet({
  required BuildContext context,
  required Offset anchor,
  required String trigger,
  FocusNode? restoreFocus,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final openSettings = SnippetSettingsLauncher.maybeOf(context);

  final outcome = await showContextualPopoverAt<_QuickAddOutcome>(
    context: context,
    targetRect: Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
    width: _panelWidth,
    builder: (_) => _QuickAddSnippetPanel(
      initialTrigger: trigger,
      canManage: openSettings != null,
    ),
  );

  if (outcome == _QuickAddOutcome.manage) {
    // The draft is already gone — the popover popped without saving it — so
    // the full list opens with nothing half-written behind it. Focus stays
    // with the dialog rather than going back to the field.
    if (context.mounted) openSettings?.call(context);
    return;
  }
  if (outcome == _QuickAddOutcome.saved) {
    messenger.showSnackBar(const SnackBar(content: Text('Snippet saved')));
  }
  restoreFocus?.requestFocus();
}

class _QuickAddSnippetPanel extends ConsumerStatefulWidget {
  const _QuickAddSnippetPanel({
    required this.initialTrigger,
    required this.canManage,
  });

  final String initialTrigger;
  final bool canManage;

  @override
  ConsumerState<_QuickAddSnippetPanel> createState() =>
      _QuickAddSnippetPanelState();
}

class _QuickAddSnippetPanelState extends ConsumerState<_QuickAddSnippetPanel> {
  String? _error;

  Future<void> _save(SnippetDraft draft) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;
    final trigger = draft.trigger.trim();
    // Same two rules as the settings list — a new snippet has no id of its
    // own yet, so nothing is exempt from the duplicate check.
    final error = validateSnippetTrigger(settings.snippets, null, trigger);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .saveSettings(
          settings.copyWith(
            snippets: [
              ...settings.snippets,
              Snippet(
                id: newId(),
                trigger: trigger,
                replacement: draft.replacement,
                autoExpand: draft.autoExpand,
                wordBoundary: draft.wordBoundary,
              ),
            ],
            updatedAt: utcNow(),
          ),
        );
    if (!mounted) return;
    Navigator.of(context).pop(_QuickAddOutcome.saved);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Watched, not read: the provider may still be loading when the popover
    // opens, and the form has nothing to validate against until it lands.
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SnippetEditor(
          original: null,
          initialTrigger: widget.initialTrigger,
          // The trigger arrived with the right-click; the replacement is the
          // only thing left to write.
          focusReplacement: true,
          // No room for it here, and no `$`-placeholder guidance either —
          // both live in the full dialog.
          showPlaceholderWarning: false,
          card: false,
          error: _error,
          onSave: _save,
          onCancel: () => Navigator.of(context).pop(),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 12, bottom: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.canManage
                  ? () => Navigator.of(context).pop(_QuickAddOutcome.manage)
                  : null,
              icon: const Icon(PhosphorIconsRegular.list, size: 14),
              label: const Text('Manage all snippets…'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                textStyle: theme.textTheme.bodySmall,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
