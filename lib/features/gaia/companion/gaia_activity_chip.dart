import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';

/// The tools a reply used between its text blocks, in the orb's gold so it
/// doesn't read as part of what Gaia said. Where [part] knows what its calls
/// were called with or why they failed, clicking it shows each call's
/// command, query or path beneath, with a failed one's reason in red, and
/// clicking again hides them. Failed calls are counted beside the label.
/// Open, the calls sit in a framed panel in neutral colours with their
/// inputs as code, so they don't read as Gaia's reply or as the chip.
class GaiaActivityChip extends StatefulWidget {
  const GaiaActivityChip({super.key, required this.label, required this.part});

  final String label;
  final GaiaActivityPart part;

  @override
  State<GaiaActivityChip> createState() => _GaiaActivityChipState();
}

class _GaiaActivityChipState extends State<GaiaActivityChip> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gold = gaiaAstralGoldFor(theme.brightness);
    final style = theme.textTheme.labelSmall?.copyWith(color: gold);
    final part = widget.part;
    final failed = part.failures.where((failure) => failure != null).length;
    final expandable =
        failed > 0 || part.details.any((detail) => detail != null);
    final error = theme.colorScheme.error;
    final failedStyle = theme.textTheme.labelSmall?.copyWith(color: error);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.build_outlined, size: 12, color: gold),
        const SizedBox(width: 6),
        Flexible(child: Text(widget.label, style: style)),
        if (failed > 0) ...[
          const SizedBox(width: 6),
          Icon(Icons.close, size: 12, color: error),
          const SizedBox(width: 2),
          Text('$failed failed', style: failedStyle),
        ],
        if (expandable)
          Icon(
            _open ? Icons.expand_less : Icons.expand_more,
            size: 14,
            color: gold,
          ),
      ],
    );
    if (!expandable) return row;
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final nameStyle = theme.textTheme.labelSmall?.copyWith(
      color: muted,
      fontWeight: FontWeight.w600,
    );
    final codeStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurface.withValues(alpha: 0.85),
      fontFamily: AppFonts.monoFamily,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Semantics(button: true, expanded: _open, child: row),
          ),
        ),
        // A framed panel in neutral colours, not the reply's prose: the
        // calls as a log, each with its kind's icon and its input as code.
        if (_open)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: 0.12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, tool) in part.tools.indexed) ...[
                  if (i > 0)
                    Divider(
                      height: 13,
                      thickness: 1,
                      color: scheme.onSurface.withValues(alpha: 0.08),
                    ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_iconOf(tool), size: 13, color: muted),
                      const SizedBox(width: 6),
                      Text(tool, style: nameStyle),
                      if (part.failureAt(i) case final failure?) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.close, size: 12, color: error),
                        const SizedBox(width: 2),
                        Flexible(child: Text(failure, style: failedStyle)),
                      ],
                    ],
                  ),
                  if (part.detailAt(i) case final detail?)
                    Padding(
                      padding: const EdgeInsets.only(left: 19, top: 3),
                      child: SelectableText(detail, style: codeStyle),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// The icon for a call of [tool], by its kind.
IconData _iconOf(String tool) => switch (tool) {
  'Bash' || 'Shell' || 'PowerShell' => Icons.terminal,
  'WebSearch' => Icons.travel_explore,
  'Grep' || 'Glob' => Icons.search,
  'WebFetch' => Icons.link,
  'Read' || 'ViewImage' => Icons.description_outlined,
  'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' => Icons.edit_outlined,
  'Task' || 'Agent' => Icons.account_tree_outlined,
  _ => Icons.extension_outlined,
};
