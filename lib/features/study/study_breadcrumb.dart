import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// Horizontally scrollable "Root / Math / Calculus" pill row. Used by both
/// the Study Hub (folder drill-down) and the Deck Workbench header, which
/// STUDY.md's Nested Folders section says replaces the plain "< Library"
/// back button — tapping a pill chops the breadcrumb stack down to that
/// folder and (from the Workbench) zooms back out to the Hub at that level.
class StudyBreadcrumbRow extends ConsumerWidget {
  const StudyBreadcrumbRow({
    super.key,
    required this.folderStack,
    required this.onTapRoot,
    required this.onTapFolder,
    this.trailingLabel,
  });

  /// Folder ids from root to the current level.
  final List<String> folderStack;
  final VoidCallback onTapRoot;
  final ValueChanged<int> onTapFolder;

  /// Non-interactive final segment (e.g. the open deck's name).
  final String? trailingLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);

    Widget pill(String label, {VoidCallback? onTap, bool current = false}) {
      final child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: current
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withValues(alpha: 0.6),
            fontWeight: current ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      );
      if (onTap == null) return child;
      return InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap, child: child);
    }

    final segments = <Widget>[pill('Root', onTap: onTapRoot, current: folderStack.isEmpty && trailingLabel == null)];
    for (var i = 0; i < folderStack.length; i++) {
      segments.add(Icon(Icons.chevron_right, size: 16, color: vc.hairline));
      final folderAsync = ref.watch(studyFolderByIdProvider(folderStack[i]));
      final isLast = i == folderStack.length - 1;
      segments.add(
        pill(
          folderAsync.valueOrNull?.name ?? '…',
          onTap: () => onTapFolder(i),
          current: isLast && trailingLabel == null,
        ),
      );
    }
    if (trailingLabel != null) {
      segments.add(Icon(Icons.chevron_right, size: 16, color: vc.hairline));
      segments.add(pill(trailingLabel!, current: true));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: segments),
    );
  }
}
