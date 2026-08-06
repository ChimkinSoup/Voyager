import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/features/study/study_breadcrumb.dart';

/// Cascading folder browser for picking a destination folder to move a
/// folder or deck into. Tapping a folder row drills into it; "Move here"
/// commits the move to whatever level is currently showing (root or the
/// folder last drilled into). [excludeFolderIds] hides the folder being
/// moved AND all of its own descendants from the list — otherwise a user
/// could drill into one of its subfolders and "move here" into its own
/// descendant, which the repo would silently reject with no feedback.
Future<void> showStudyMoveDestinationModal(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  Set<String> excludeFolderIds = const {},
  required Future<void> Function(String? destinationFolderId) onSelect,
}) {
  return showVoyagerSheet<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _StudyMoveDestinationModal(
        title: title,
        excludeFolderIds: excludeFolderIds,
        onSelect: onSelect,
      ),
    ),
  );
}

class _StudyMoveDestinationModal extends ConsumerStatefulWidget {
  const _StudyMoveDestinationModal({
    required this.title,
    required this.excludeFolderIds,
    required this.onSelect,
  });

  final String title;
  final Set<String> excludeFolderIds;
  final Future<void> Function(String? destinationFolderId) onSelect;

  @override
  ConsumerState<_StudyMoveDestinationModal> createState() =>
      _StudyMoveDestinationModalState();
}

class _StudyMoveDestinationModalState
    extends ConsumerState<_StudyMoveDestinationModal> {
  List<String> _stack = [];
  bool _moving = false;

  Future<void> _moveHere() async {
    if (_moving) return;
    setState(() => _moving = true);
    await widget.onSelect(_stack.isEmpty ? null : _stack.last);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parentId = _stack.isEmpty ? null : _stack.last;
    final foldersAsync = ref.watch(studyFoldersProvider(parentId));
    final folders = [...foldersAsync.valueOrNull ?? const []]
      ..removeWhere((f) => widget.excludeFolderIds.contains(f.id))
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Text(widget.title, style: theme.textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      onPressed: Navigator.of(context).pop,
                      icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                StudyBreadcrumbRow(
                  folderStack: _stack,
                  onTapRoot: () => setState(() => _stack = []),
                  onTapFolder: (i) => setState(() => _stack = _stack.sublist(0, i + 1)),
                ),
                const SizedBox(height: 12),
                GlassButton(
                  onPressed: _moving ? null : _moveHere,
                  icon: const Icon(PhosphorIconsRegular.check),
                  label: 'Move here',
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                for (final folder in folders)
                  ListTile(
                    enabled: !_moving,
                    leading: Icon(PhosphorIconsRegular.folder, color: theme.colorScheme.primary),
                    title: Text(folder.name),
                    trailing: const Icon(PhosphorIconsRegular.caretRight, size: 16),
                    onTap: () => setState(() => _stack = [..._stack, folder.id]),
                  ),
                if (folders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No subfolders here.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
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
