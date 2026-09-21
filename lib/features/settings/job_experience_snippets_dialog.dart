import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/rounded_drag_proxy.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/jobs/experience_snippet_text.dart';

/// Manages the Jobs header's experience snippets
/// (`JOBS_EXPERIENCE_SNIPPETS_HLD.md` §8): add, edit, delete, reorder. The
/// order is what the header shows — its first three are the chips.
///
/// Every change persists as it happens, the reorder included, so "Done" only
/// closes the dialog.
Future<void> showJobExperienceSnippetsDialog(BuildContext context) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => const _ExperienceSnippetsDialog(),
  );
}

/// The Settings tile's subtitle.
String jobExperienceSnippetsSummary(AppSettings settings) {
  final count = settings.jobExperienceSnippets.length;
  return count == 0 ? 'Not set — no copy chips on the Jobs page' : '$count set';
}

class _ExperienceSnippetsDialog extends ConsumerWidget {
  const _ExperienceSnippetsDialog();

  /// Applies [change] to the *current* list rather than the one this build
  /// saw, and stores only what it changed, so an edit made while another
  /// dialog was open — or on another device — is never undone.
  Future<void> _write(
    WidgetRef ref,
    List<JobExperienceSnippet> Function(List<JobExperienceSnippet> current)
    change,
  ) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;
    final before = settings.jobExperienceSnippets;
    await ref
        .read(settingsProvider.notifier)
        .saveJobExperienceSnippets(before, change(before));
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final draft = await showJobExperienceEditor(context);
    if (draft == null) return;
    await _write(
      ref,
      (current) => [
        ...current,
        JobExperienceSnippet(
          id: newId(),
          name: draft.name,
          description: draft.description,
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    JobExperienceSnippet original,
  ) async {
    final draft = await showJobExperienceEditor(context, original: original);
    if (draft == null) return;
    await _write(
      ref,
      (current) => [
        for (final snippet in current)
          snippet.id == original.id
              ? snippet.copyWith(
                  name: draft.name,
                  description: draft.description,
                )
              : snippet,
      ],
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    JobExperienceSnippet snippet,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete experience',
      message: 'Delete “${snippet.name}”?',
    );
    if (!confirmed) return;
    await _write(
      ref,
      (current) => [
        for (final s in current)
          if (s.id != snippet.id) s,
      ],
    );
  }

  /// [newIndex] is already the slot after [oldIndex] is taken out —
  /// `onReorderItem` makes that adjustment itself.
  void _reorder(WidgetRef ref, int oldIndex, int newIndex) {
    _write(ref, (current) {
      if (oldIndex >= current.length) return current;
      final next = [...current];
      final moved = next.removeAt(oldIndex);
      next.insert(newIndex.clamp(0, next.length), moved);
      return next;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) {
      return const AlertDialog(
        content: SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final snippets = settings.jobExperienceSnippets;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: const Text('Experience snippets'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Role descriptions the Jobs page copies in one click. The '
              'first three show as chips beside your profile links and the '
              'rest in a menu — drag to choose which.',
              style: muted,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: snippets.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        "You haven't added any experiences yet.",
                        textAlign: TextAlign.center,
                        style: muted,
                      ),
                    )
                  : ReorderableListView(
                      shrinkWrap: true,
                      // Handle-only: a tap anywhere else on the row edits it.
                      buildDefaultDragHandles: false,
                      proxyDecorator: roundedDragProxy,
                      onReorderItem: (oldIndex, newIndex) =>
                          _reorder(ref, oldIndex, newIndex),
                      children: [
                        for (var i = 0; i < snippets.length; i++)
                          _ExperienceRow(
                            key: ValueKey(snippets[i].id),
                            index: i,
                            snippet: snippets[i],
                            onEdit: () => _edit(context, ref, snippets[i]),
                            onDelete: () => _delete(context, ref, snippets[i]),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: GlassButton(
                dense: true,
                onPressed: () => _add(context, ref),
                icon: const Icon(PhosphorIconsRegular.plus),
                label: 'Add experience',
              ),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Done',
        ),
      ],
    );
  }
}

class _ExperienceRow extends StatelessWidget {
  const _ExperienceRow({
    super.key,
    required this.index,
    required this.snippet,
    required this.onEdit,
    required this.onDelete,
  });

  final int index;
  final JobExperienceSnippet snippet;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onEdit,
      leading: ReorderableDragStartListener(
        index: index,
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              PhosphorIconsRegular.dotsSixVertical,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      title: Text(snippet.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        snippet.description.isEmpty
            ? 'No description'
            // A multi-line body has to fit on one row here.
            : snippet.description.trim().replaceAll('\n', ' ⏎ '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: snippet.description.isEmpty
            ? muted?.copyWith(fontStyle: FontStyle.italic)
            : muted,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit experience',
            icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Delete experience',
            icon: Icon(
              PhosphorIconsRegular.trash,
              size: 18,
              color: theme.colorScheme.error,
            ),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// What the editor hands back on Save: a trimmed, non-empty name and the
/// description exactly as it stands in the field.
typedef JobExperienceDraft = ({String name, String description});

/// Opens the add/edit form (§8.3). Null when the user cancels.
///
/// The barrier does not dismiss it: a stray click outside would otherwise
/// throw away a pasted description with no way back.
Future<JobExperienceDraft?> showJobExperienceEditor(
  BuildContext context, {
  JobExperienceSnippet? original,
}) {
  return showVoyagerDialog<JobExperienceDraft>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExperienceEditorDialog(original: original),
  );
}

class _ExperienceEditorDialog extends StatefulWidget {
  const _ExperienceEditorDialog({required this.original});

  final JobExperienceSnippet? original;

  @override
  State<_ExperienceEditorDialog> createState() =>
      _ExperienceEditorDialogState();
}

class _ExperienceEditorDialogState extends State<_ExperienceEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.original?.name ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.original?.description ?? '',
  );
  final FocusNode _descriptionFocus = FocusNode();
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _descriptionFocus.dispose();
    super.dispose();
  }

  void _cleanPaste() {
    final cleaned = cleanExperienceText(_description.text);
    if (cleaned == _description.text) return;
    _description.value = TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: cleaned.length),
    );
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Give the experience a name.');
      return;
    }
    Navigator.of(
      context,
    ).pop<JobExperienceDraft>((name: name, description: _description.text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dialog = AlertDialog(
      title: Text(
        widget.original == null ? 'Add experience' : 'Edit experience',
      ),
      content: SizedBox(
        width: 800,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledTextField(
              label: 'Name',
              hintText: 'e.g. Acme - SWE Intern',
              controller: _name,
              autofocus: true,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              onSubmitted: (_) => _descriptionFocus.requestFocus(),
            ),
            if (_nameError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            // Flexible, so a short window squeezes the box — which then
            // scrolls — instead of overflowing the dialog.
            Flexible(
              child: LabeledTextField(
                label: 'Description',
                hintText: 'Exactly what should be pasted into the form',
                controller: _description,
                focusNode: _descriptionFocus,
                minLines: 14,
                maxLines: 24,
                // What is saved here is pasted verbatim into applications, so
                // nothing rewrites it behind the user's back — Clean paste is
                // the one sanctioned rewrite, and only on request (§9.1).
                autocorrectAllowed: false,
                showLineBreaks: true,
              ),
            ),
            const SizedBox(height: 6),
            // Only the status under the field follows each keystroke; the
            // fields themselves are not rebuilt by it.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _description,
              builder: (context, value, _) =>
                  _DescriptionStatus(text: value.text),
            ),
          ],
        ),
      ),
      actions: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _description,
          builder: (context, value, _) => GlassButton(
            dense: true,
            // Disabled when there is nothing it would change, which doubles
            // as the answer to "is this already clean?".
            onPressed: cleanExperienceText(value.text) == value.text
                ? null
                : _cleanPaste,
            icon: const Icon(PhosphorIconsRegular.broom),
            label: 'Clean paste',
            tooltip:
                'Swap curly quotes, dashes, bullets and odd spaces for plain '
                'ASCII and tidy spacing on each line',
          ),
        ),
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
        ),
        GlassButton(dense: true, onPressed: _save, label: 'Save'),
      ],
    );
    return CtrlEnterToSubmitScope(onSubmit: _save, child: dialog);
  }
}

/// Character count plus the advisory warning strip (§8.3, §9.2). Never blocks
/// Save and never touches the text.
class _DescriptionStatus extends StatefulWidget {
  const _DescriptionStatus({required this.text});

  final String text;

  @override
  State<_DescriptionStatus> createState() => _DescriptionStatusState();
}

class _DescriptionStatusState extends State<_DescriptionStatus> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final issues = experienceTextIssues(widget.text);
    final amber = theme.brightness == Brightness.dark
        ? Colors.amber.shade300
        : Colors.amber.shade800;
    // Code units, which is what a form's maxlength counts too.
    final length = widget.text.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '$length ${length == 1 ? 'character' : 'characters'}',
            style: muted,
          ),
        ),
        if (issues.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: amber.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(PhosphorIconsRegular.warning, size: 14, color: amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Non-standard characters or spacing detected',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    GlassButton(
                      dense: true,
                      onPressed: () =>
                          setState(() => _showDetails = !_showDetails),
                      label: _showDetails ? 'Hide' : 'Details',
                    ),
                  ],
                ),
                if (_showDetails)
                  Padding(
                    padding: const EdgeInsets.only(left: 20, top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final issue in ExperienceTextIssue.values)
                          if (issues.contains(issue))
                            Text('• ${issue.label}', style: muted),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
