import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_markdown.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_steady_list.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// The tools a reply used between its text blocks, in the orb's gold so it
/// doesn't read as part of what Gaia said. Where [part] knows what its calls
/// were called with or why they failed, clicking it shows each call's
/// command, query or path beneath, with a failed one's reason in red, and
/// clicking again hides them. Failed calls are counted beside the label.
/// Open, the calls sit in a framed panel in neutral colours with their
/// inputs as code, so they don't read as Gaia's reply or as the chip.
///
/// A call whose result this device kept ([hasResult]) shows what the tool
/// answered beneath it, as [result] reads it.
class GaiaActivityChip extends StatefulWidget {
  const GaiaActivityChip({
    super.key,
    required this.label,
    required this.part,
    this.hasResult,
    this.result,
  });

  final String label;
  final GaiaActivityPart part;
  final bool Function(String callId)? hasResult;
  final Future<GaiaToolResult?> Function(String callId)? result;

  @override
  State<GaiaActivityChip> createState() => _GaiaActivityChipState();
}

class _GaiaActivityChipState extends State<GaiaActivityChip> {
  var _open = false;

  /// Each kept result read so far, by its call's id.
  final _results = <String, Future<GaiaToolResult?>>{};

  /// Call [index]'s id when its result is kept here.
  String? _kept(int index) {
    final id = widget.part.idAt(index);
    return id != null && (widget.hasResult?.call(id) ?? false) ? id : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gold = gaiaAstralGoldFor(theme.brightness);
    final style = theme.textTheme.labelSmall?.copyWith(color: gold);
    final part = widget.part;
    final failed = part.failures.where((failure) => failure != null).length;
    final expandable =
        failed > 0 ||
        part.details.any((detail) => detail != null) ||
        List.generate(part.tools.length, _kept).any((id) => id != null);
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
            onTap: () {
              GaiaHoldInPlace(context).dispatch(context);
              setState(() => _open = !_open);
            },
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
            // One selection across the calls, not one per input or result.
            child: GaiaSelectableLines(
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
                        child: Text(detail, style: codeStyle),
                      ),
                    if (_kept(i) case final id?)
                      Padding(
                        padding: const EdgeInsets.only(left: 19, top: 3),
                        child: _KeptResult(
                          result: _results[id] ??= widget.result!(id),
                          style: codeStyle,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// "Used Bash ×3, Edit".
String gaiaActivityLabel(List<String> tools) {
  final counts = <String, int>{};
  for (final tool in tools) {
    counts[tool] = (counts[tool] ?? 0) + 1;
  }
  return 'Used ${[for (final MapEntry(:key, :value) in counts.entries) value > 1 ? '$key ×$value' : key].join(', ')}';
}

/// [part] without its `os_*` actions, for a reply whose activity card already
/// lists them (GAIA_AUTONOMY_HLD.md §7): the reads stay, with what they kept.
/// A read is told by its kept id, as an `os_clipboard` read is named like a
/// write. Null when nothing is left.
GaiaActivityPart? gaiaWithoutControls(GaiaActivityPart part) {
  final kept = [
    for (var i = 0; i < part.tools.length; i++)
      if (!isGaiaOsControl(part.tools[i]) || part.idAt(i) != null) i,
  ];
  if (kept.isEmpty) return null;
  if (kept.length == part.tools.length) return part;
  return GaiaActivityPart(
    [for (final i in kept) part.tools[i]],
    details: [for (final i in kept) part.detailAt(i)],
    failures: [for (final i in kept) part.failureAt(i)],
    ids: [for (final i in kept) part.idAt(i)],
  );
}

/// A kept result as its tool answered it: the image first, as the agent was
/// shown it, then the text, which can run to a whole window's controls, in a
/// box of its own that scrolls.
class _KeptResult extends StatefulWidget {
  const _KeptResult({required this.result, required this.style});

  final Future<GaiaToolResult?> result;
  final TextStyle? style;

  @override
  State<_KeptResult> createState() => _KeptResultState();
}

class _KeptResultState extends State<_KeptResult> {
  /// How much of the text shows until Show all: a whole window's controls can
  /// run to tens of thousands of characters, slow to lay out and to read.
  static const _preview = 4000;

  var _all = false;

  /// Read and decoded once, not at each build.
  late final Future<({String text, Uint8List? image})?> _read = widget.result
      .then(
        (result) => result == null
            ? null
            : (
                text: result.text,
                image: result.image == null
                    ? null
                    : base64Decode(result.image!),
              ),
      );

  /// Whether the image has shown, so it's held in place as it grows once.
  var _imageShown = false;

  @override
  void initState() {
    super.initState();
    // The result fills in a frame after it opened: keep it held as it grows.
    _read.then((_) {
      if (mounted) GaiaHoldInPlace(context).dispatch(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder(
      future: _read,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(height: 16);
        }
        final read = snapshot.data;
        if (read == null) {
          return Text("This device doesn't have it.", style: widget.style);
        }
        final long = read.text.length > _preview;
        final text = long && !_all
            ? '${read.text.substring(0, _preview)}…'
            : read.text;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (read.image case final image?)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: Image.memory(
                    image,
                    fit: BoxFit.contain,
                    // Decoded a frame or more later: held as it takes its size.
                    frameBuilder: (context, child, frame, synchronous) {
                      if (frame != null && !synchronous && !_imageShown) {
                        _imageShown = true;
                        GaiaHoldInPlace(context).dispatch(context);
                      }
                      return child;
                    },
                  ),
                ),
              ),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: Text(text, style: widget.style),
              ),
            ),
            if (long)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                // Its label isn't part of what's selected and copied.
                child: SelectionContainer.disabled(
                  child: GaiaButton(
                    size: 28,
                    padding: 12,
                    label: _all
                        ? 'Show less'
                        : 'Show all (${_count(read.text.length)} characters)',
                    onPressed: () {
                      GaiaHoldInPlace(context).dispatch(context);
                      setState(() => _all = !_all);
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A count with thousands separated: 60,412.
final _count = NumberFormat.decimalPattern().format;

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
