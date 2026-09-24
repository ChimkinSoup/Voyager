import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/services/color_palette_codec.dart';
import 'package:voyager/features/settings/services/color_replacement_service.dart';

/// How both hex fields here take input — the one that adds a color and the
/// one that replaces it. Filter before limiting, so a pasted "#f2d5cf" loses
/// its "#" rather than its last digit.
final _hexInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
  LengthLimitingTextInputFormatter(6),
];

/// Cuts the counter Flutter otherwise shows under a `maxLength` field.
Widget? _noCounter(
  BuildContext context, {
  required int currentLength,
  required bool isFocused,
  int? maxLength,
}) => null;

class SettingsColorPaletteSection extends ConsumerStatefulWidget {
  const SettingsColorPaletteSection({
    super.key,
    required this.settings,
    required this.onSave,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings settings) onSave;

  @override
  ConsumerState<SettingsColorPaletteSection> createState() =>
      _SettingsColorPaletteSectionState();
}

class _SettingsColorPaletteSectionState
    extends ConsumerState<SettingsColorPaletteSection> {
  final _hexController = TextEditingController();
  final _hexFocusNode = FocusNode();
  String? _hexError;

  @override
  void dispose() {
    _hexController.dispose();
    _hexFocusNode.dispose();
    super.dispose();
  }

  Future<void> _updatePalette(List<int> palette) async {
    await widget.onSave(widget.settings.copyWith(colorPalette: palette));
  }

  Future<void> _addColor() async {
    final parsed = parseHexColor(_hexController.text);
    if (parsed == null) {
      setState(() => _hexError = 'Enter 6 hex digits (e.g. 7C9EFF)');
      _hexFocusNode.requestFocus();
      return;
    }
    final palette = List<int>.from(widget.settings.colorPalette);
    if (palette.contains(parsed)) {
      setState(() => _hexError = 'Color already in palette');
      _hexFocusNode.requestFocus();
      return;
    }
    palette.add(parsed);
    _hexController.clear();
    setState(() => _hexError = null);
    await _updatePalette(palette);
    if (mounted) _hexFocusNode.requestFocus();
  }

  Future<void> _removeColor(int color) async {
    if (widget.settings.colorPalette.length <= 1) return;
    final palette = List<int>.from(widget.settings.colorPalette)
      ..remove(normalizeColorValue(color));
    await _updatePalette(palette);
  }

  /// Where the drag lifted its chip from, and where the gap it left has
  /// followed the cursor to — both indices into the palette. Null outside a
  /// drag.
  int? _dragFrom;
  int _dragTo = 0;

  /// Where in the chip the pointer took hold of it, so the feedback's offset
  /// converts back into the cursor's.
  Offset _grab = Offset.zero;

  final _wrapKey = GlobalKey();
  final _slotKeys = <int, GlobalKey>{};

  /// The palette as it would read if the drag dropped now: the dragged chip
  /// sits in the gap under the cursor, and its old slot has closed up.
  List<int> get _shownPalette {
    final palette = widget.settings.colorPalette;
    final from = _dragFrom;
    if (from == null || from == _dragTo) return palette;
    final shown = List<int>.from(palette);
    return shown..insert(_dragTo, shown.removeAt(from));
  }

  RenderWrap get _wrap =>
      _wrapKey.currentContext!.findRenderObject()! as RenderWrap;

  /// Moves the gap next to whichever chip the cursor is nearest — before it
  /// over its left half, after it over its right. Measured against the chips'
  /// laid-out slots rather than where they are mid-slide, so the gap doesn't
  /// chase a chip that is still on its way.
  void _moveGap(Offset feedback) {
    // The drag's first move reaches the target before `onDragStarted` has
    // said which chip it lifted.
    if (_dragFrom == null) return;
    final wrap = _wrap;
    final pointer = wrap.globalToLocal(feedback + _grab);
    var nearest = 0;
    var nearestRect = Rect.zero;
    var best = double.infinity;
    var i = 0;
    for (
      var child = wrap.firstChild;
      child != null;
      child = wrap.childAfter(child), i++
    ) {
      final rect = (child.parentData! as BoxParentData).offset & child.size;
      final closest = Offset(
        pointer.dx.clamp(rect.left, rect.right),
        pointer.dy.clamp(rect.top, rect.bottom),
      );
      final distance = (pointer - closest).distanceSquared;
      if (distance < best) {
        best = distance;
        nearest = i;
        nearestRect = rect;
      }
    }
    // Over the gap itself: it is already where the cursor is.
    if (nearest == _dragTo) return;
    final rest = nearest < _dragTo ? nearest : nearest - 1;
    final to = pointer.dx < nearestRect.center.dx ? rest : rest + 1;
    if (to != _dragTo) setState(() => _dragTo = to);
  }

  void _drop(int color, Offset feedback) {
    final moved = _dragFrom != _dragTo;
    final shown = _shownPalette;
    setState(() => _dragFrom = null);
    _settleFrom(color, feedback);
    if (moved) _updatePalette(shown);
  }

  void _cancelDrag(int color, Offset feedback) {
    setState(() => _dragFrom = null);
    _settleFrom(color, feedback);
  }

  /// Flies [color]'s chip from where the drag let go of it into its slot.
  void _settleFrom(int color, Offset feedback) {
    final slot =
        _slotKeys[color]!.currentContext!.findRenderObject()!
            as _RenderSlideToLayout;
    slot.slideFrom(_wrap.globalToLocal(feedback));
  }

  /// Moves every record and setting on [color] to a hex the user types, and
  /// the palette swatch with them.
  ///
  /// The palette is the only place a color can be *named*, so it is also the
  /// only place a rename can be offered from — everywhere else picks out of
  /// this list and has no idea what else shares its value.
  Future<void> _replaceColorEverywhere(int color) async {
    final replacement = await _showReplaceColorDialog(context, color);
    if (replacement == null || !mounted) return;
    if (replacement == normalizeColorValue(color)) return;

    final service = ref.read(colorReplacementServiceProvider);
    final usage = await service.countUsage(color);
    final settingsUses = settingsColorsUsing(widget.settings, color);
    if (!mounted) return;

    final confirmed = await showConfirmDialog(
      context,
      title: 'Replace color everywhere?',
      message: _replaceSummary(color, replacement, usage, settingsUses),
      confirmLabel: 'Replace',
    );
    if (!confirmed || !mounted) return;

    // Records first, then the settings. A sweep that fails partway leaves the
    // swatch still showing the old color, which is the state a retry starts
    // from; the other order would take the swatch away with its records still
    // on it and no way back to them.
    final replaced = await service.replace(from: color, to: replacement);
    await widget.onSave(
      replaceSettingsColor(widget.settings, from: color, to: replacement),
    );
    if (!mounted) return;

    // The sweep writes straight to the database, and the read providers it
    // goes behind are `keepAlive` futures rather than streams — so every list
    // already built keeps painting the old color until something invalidates
    // it. Same reason a restore ends this way: a sweep can rewrite any
    // collection, so nothing on screen can be assumed still current.
    invalidateAllDataProvidersFrom(ref);
    showVoyagerToast(
      context,
      message: replaced.total == 0
          ? 'Palette updated — nothing else used ${formatColorHex(color)}.'
          : 'Replaced ${formatColorHex(color)} in ${replaced.total} '
                '${replaced.total == 1 ? 'record' : 'records'}.',
      // The icon is what marks the toast finished rather than still working,
      // and without a dwell it would have no clock and no action to dismiss
      // it — the same pair the Copy toasts in the LeetCode pages carry.
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(milliseconds: 1400),
    );
  }

  String _replaceSummary(
    int from,
    int to,
    ColorUsage usage,
    List<String> settingsUses,
  ) {
    final parts = [
      if (usage.total > 0)
        '${usage.total} ${usage.total == 1 ? 'record' : 'records'}',
      ...settingsUses,
    ];
    if (parts.isEmpty) {
      return 'Nothing uses ${formatColorHex(from)} yet. Change the swatch to '
          '${formatColorHex(to)}?';
    }
    final listed = parts.length == 1
        ? parts.single
        : '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
    return '${formatColorHex(from)} is used by $listed. Change all of it — '
        'and the palette swatch — to ${formatColorHex(to)}?';
  }

  Widget _colorChip(int color, {required bool deletable}) {
    return InputChip(
      avatar: CircleAvatar(backgroundColor: Color(color)),
      label: Text(formatColorHex(color)),
      onDeleted: deletable ? () => _removeColor(color) : null,
      deleteIcon: deletable
          ? const Icon(PhosphorIconsRegular.x, size: 18)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = widget.settings.colorPalette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Color palette', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Preset colors used across the app. Add custom colors with hex here; '
          'everywhere else you pick from this list only. Drag a swatch to '
          'reorder the palette, or right-click one to replace every use of it.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        DragTarget<int>(
          onMove: (details) => _moveGap(details.offset),
          // Off the palette a drop cancels, so the gap goes back home.
          onLeave: (_) => setState(() => _dragTo = _dragFrom ?? _dragTo),
          onAcceptWithDetails: (details) => _drop(details.data, details.offset),
          builder: (context, _, _) => Wrap(
            key: _wrapKey,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (index, color) in _shownPalette.indexed)
                _SlideToLayout(
                  key: _slotKeys.putIfAbsent(color, GlobalKey.new),
                  child: Draggable<int>(
                    data: color,
                    dragAnchorStrategy: (draggable, context, position) =>
                        _grab = childDragAnchorStrategy(
                          draggable,
                          context,
                          position,
                        ),
                    onDragStarted: () => setState(() {
                      _dragFrom = index;
                      _dragTo = index;
                    }),
                    onDraggableCanceled: (_, offset) =>
                        _cancelDrag(color, offset),
                    feedback: Material(
                      type: MaterialType.transparency,
                      child: _colorChip(color, deletable: false),
                    ),
                    // Holds the chip's full width open as the gap.
                    childWhenDragging: Opacity(
                      opacity: 0,
                      child: _colorChip(color, deletable: palette.length > 1),
                    ),
                    child: ContextMenuRegion(
                      items: [
                        ContextMenuItem(
                          label: 'Replace everywhere…',
                          icon: PhosphorIconsRegular.swap,
                          onTap: () => _replaceColorEverywhere(color),
                        ),
                      ],
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: _colorChip(color, deletable: palette.length > 1),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: VoyagerTextField(
                controller: _hexController,
                focusNode: _hexFocusNode,
                maxLength: 6,
                buildCounter: _noCounter,
                inputFormatters: _hexInputFormatters,
                decoration: const InputDecoration(
                  hintText: 'Add custom color (e.g. 7C9EFF)',
                  // Without these the field takes Flutter's outlined default of
                  // 20px above and below a single line of text, which left the
                  // row looming over the swatches it belongs to.
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                onSubmitted: (_) => _addColor(),
              ),
            ),
            const SizedBox(width: 8),
            GlassButton(onPressed: _addColor, label: 'Add', dense: true),
          ],
        ),
        if (_hexError != null) ...[
          const SizedBox(height: 8),
          Text(
            _hexError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// Paints its child sliding from wherever it last showed to wherever the
/// parent lays it out now, so a chip the palette reflows glides to its new
/// slot instead of jumping.
///
/// Done at paint time, from the offset the parent has just assigned, so the
/// first frame after a reflow still paints the old spot — measuring after
/// layout from a widget would flash the new one for a frame first.
class _SlideToLayout extends SingleChildRenderObjectWidget {
  const _SlideToLayout({super.key, required super.child});

  @override
  _RenderSlideToLayout createRenderObject(BuildContext context) =>
      _RenderSlideToLayout();
}

class _RenderSlideToLayout extends RenderProxyBox {
  static const _duration = Duration(milliseconds: 200);

  /// All in the parent's coordinates: where the last frame painted the child,
  /// the slot it is heading for, and where the current slide set out from.
  Offset? _painted;
  Offset? _target;
  Offset _from = Offset.zero;
  Duration? _start;

  /// Starts the next slide from [position], in the parent's coordinates,
  /// rather than from where the child last painted.
  void slideFrom(Offset position) {
    _painted = position;
    _target = null;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final layout = (parentData! as BoxParentData).offset;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    if (layout != _target) {
      _target = layout;
      _from = _painted ?? layout;
      _start = _from == layout ? null : now;
    }
    var shown = layout;
    if (_start case final start?) {
      final t = (now - start).inMicroseconds / _duration.inMicroseconds;
      if (t >= 1) {
        _start = null;
      } else {
        shown = Offset.lerp(_from, layout, Curves.easeOutCubic.transform(t))!;
        SchedulerBinding.instance.scheduleFrameCallback((_) {
          if (attached) markNeedsPaint();
        });
      }
    }
    _painted = shown;
    super.paint(context, offset + shown - layout);
  }
}

Future<void> pickAccentColor(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings,
  Future<void> Function(AppSettings settings) onSave,
) async {
  var selected = normalizeColorValue(settings.accentColor);
  final palette = ref.read(colorPaletteProvider);
  if (!paletteContains(palette, selected)) {
    selected = normalizeColorValue(palette.first);
  }

  final picked = await pickColorFromPalette(
    context,
    palette: palette,
    current: selected,
    title: 'Accent color',
  );
  if (picked != null) {
    await onSave(settings.copyWith(accentColor: picked));
  }
}

/// Asks what to replace [from] with, under the same input rules as the field
/// that adds a color: hex digits only, six of them at most.
///
/// Returns the parsed color, never raw text — the button stays disabled until
/// the field holds a full six digits, so there is no invalid answer to report
/// back to the caller.
Future<int?> _showReplaceColorDialog(BuildContext context, int from) {
  return showVoyagerDialog<int>(
    context: context,
    builder: (context) => _ReplaceColorDialog(from: from),
  );
}

class _ReplaceColorDialog extends StatefulWidget {
  const _ReplaceColorDialog({required this.from});

  final int from;

  @override
  State<_ReplaceColorDialog> createState() => _ReplaceColorDialogState();
}

class _ReplaceColorDialogState extends State<_ReplaceColorDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _parsed => parseHexColor(_controller.text);

  void _submit() {
    final parsed = _parsed;
    if (parsed != null) Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    return EnterToSubmitScope(
      onSubmit: _submit,
      child: AlertDialog(
        title: Text('Replace ${formatColorHex(widget.from)}'),
        content: SizedBox(
          width: 280,
          child: VoyagerTextField(
            controller: _controller,
            autofocus: true,
            maxLength: 6,
            buildCounter: _noCounter,
            inputFormatters: _hexInputFormatters,
            decoration: InputDecoration(
              hintText: 'New color (e.g. 7C9EFF)',
              // The parsed swatch stands in for the "is that the color I
              // meant" check that typing six digits blind cannot give.
              prefixIcon: parsed == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8),
                      child: CircleAvatar(
                        radius: 9,
                        backgroundColor: Color(parsed),
                      ),
                    ),
              prefixIconConstraints: const BoxConstraints(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          GlassButton(
            dense: true,
            onPressed: () => Navigator.pop(context),
            label: 'Cancel',
          ),
          GlassButton(
            dense: true,
            onPressed: parsed == null ? null : _submit,
            label: 'OK',
          ),
        ],
      ),
    );
  }
}
