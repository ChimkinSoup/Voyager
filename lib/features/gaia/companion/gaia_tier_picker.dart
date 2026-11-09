import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';

/// The tier picker's item (§7.2): the three tiers, each with its [agent],
/// and, while [autoOffered], Auto first, which leaves the tier to the router.
/// [tier] is the selected one, null for Auto; [routing] while the router is
/// picking. Auto's glyph runs through the tiers until the router answers.
/// [lastReply], the tier the chat's last reply ran on, is marked while
/// another is selected.
GaiaNotchItem<GaiaTier?> gaiaTierItem({
  required bool autoOffered,
  required GaiaTier? tier,
  required bool routing,
  required String? Function(GaiaTier tier) agent,
  required FutureOr<void> Function(GaiaTier? tier) onChanged,
  GaiaTier? lastReply,
}) => GaiaNotchItem<GaiaTier?>(
  options: [
    if (autoOffered)
      GaiaNotchOption(
        value: null,
        label: 'Auto',
        icon: (color, {required lit}) =>
            _PickerGlyph(level: null, fast: routing, color: color),
      ),
    for (final option in GaiaTier.values)
      GaiaNotchOption(
        value: option,
        label: option.label,
        detail: agent(option) ?? 'No agent',
        note: option == lastReply && option != tier ? 'last reply' : null,
        icon: (color, {required lit}) =>
            _PickerGlyph(level: option.index, color: color, lit: lit),
      ),
  ],
  value: tier,
  onChanged: onChanged,
);

/// [child], the tier picker's notch, its ring flashing as the router
/// answers: once [routing] ends for the same [chatId], unless the user
/// [picked] a tier meanwhile.
class GaiaRouteFlash extends StatefulWidget {
  const GaiaRouteFlash({
    super.key,
    required this.routing,
    required this.chatId,
    required this.picked,
    required this.child,
  });

  /// Whether the router is picking [chatId]'s tier.
  final bool routing;
  final String? chatId;
  final bool picked;
  final Widget child;

  @override
  State<GaiaRouteFlash> createState() => _GaiaRouteFlashState();
}

class _GaiaRouteFlashState extends State<GaiaRouteFlash>
    with SingleTickerProviderStateMixin {
  late final _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  /// The chat that was waiting on the router at the last build.
  String? _routing;

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatId = widget.chatId;
    if (_routing != null &&
        _routing == chatId &&
        !widget.routing &&
        // The router's pick, not the user's own meanwhile.
        !widget.picked &&
        !MediaQuery.disableAnimationsOf(context)) {
      _flash.forward(from: 0);
    }
    _routing = widget.routing ? chatId : null;
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _flash,
      child: widget.child,
      builder: (context, notch) {
        // Up quickly, then fading out.
        final t = _flash.value;
        final glow = _flash.isAnimating
            ? (t < 0.15
                  ? t / 0.15
                  : 1 - Curves.easeOut.transform((t - 0.15) / 0.85))
            : 0.0;
        // Always wrapped, so the notch keeps its state as the glow comes
        // and goes.
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              if (glow > 0)
                BoxShadow(
                  color: accent.withValues(alpha: 0.6 * glow),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
            ],
          ),
          child: notch,
        );
      },
    );
  }
}

/// A tier's glyph in the picker, or, with no [level], Auto's: one running
/// through the tiers, [fast] while the router is picking. Auto's and a
/// tier's are the same widget, so the trigger's glyph eases from wherever
/// Auto's was into the tier the router picked.
class _PickerGlyph extends StatefulWidget {
  const _PickerGlyph({
    required this.level,
    required this.color,
    this.fast = false,
    this.lit = false,
  });

  final int? level;
  final Color color;
  final bool fast;
  final bool lit;

  @override
  State<_PickerGlyph> createState() => _PickerGlyphState();
}

class _PickerGlyphState extends State<_PickerGlyph> {
  Timer? _timer;

  /// Auto's place in its run: 0, 1, 2, 1, then round again.
  var _step = 0;

  static const _run = [0, 1, 2, 1];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PickerGlyph old) {
    super.didUpdateWidget(old);
    if (widget.level != old.level || widget.fast != old.fast) _sync();
  }

  /// Auto's run goes only with ambient motion, and at its pace.
  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (widget.level != null ||
        !GaiaAmbient.of(context) ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    _timer = Timer.periodic(
      Duration(milliseconds: widget.fast ? 450 : 1400),
      (_) => setState(() => _step = (_step + 1) % _run.length),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GaiaTierGlyph(
      level: widget.level ?? _run[_step],
      color: widget.color,
      lit: widget.lit,
      morphs: true,
    );
  }
}
