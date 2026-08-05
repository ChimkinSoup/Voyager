import 'package:flutter/material.dart';
import 'package:voyager/core/effects/confetti.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// A custom checkbox (not Material [Checkbox]) with a fill/pop animation and
/// a faint preview check on hover. Matches the visual the Todo list's task
/// rows use, so "mark complete" reads identically wherever it appears.
///
/// [value]/[onChanged] follow the standard controlled-widget contract — the
/// checkbox animates toward whatever [value] it's given rather than owning
/// its own truth, so a parent can veto or delay the change.
class VoyagerCheckbox extends StatefulWidget {
  const VoyagerCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.accentColor,
    this.celebrateOnComplete = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? accentColor;

  /// Fires a confetti burst from the checkbox when tapping completes it
  /// (false → true).
  final bool celebrateOnComplete;

  @override
  State<VoyagerCheckbox> createState() => _VoyagerCheckboxState();
}

class _VoyagerCheckboxState extends State<VoyagerCheckbox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  bool _hovered = false;
  final GlobalKey _boxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final reduced = VoyagerMotion.reduced(context);
    _controller = AnimationController(
      vsync: this,
      duration: reduced ? VoyagerMotion.crossfade : const Duration(milliseconds: 200),
      value: widget.value ? 1.0 : 0.0,
    );
    // Reduced motion drops the pop-overshoot entirely — the box still fills
    // in (via _controller.value driving color/opacity in _visual), it just
    // doesn't scale.
    _scale = reduced
        ? const AlwaysStoppedAnimation<double>(1.0)
        : TweenSequence<double>([
            TweenSequenceItem(
              tween: Tween(
                begin: 1.0,
                end: 1.25,
              ).chain(CurveTween(curve: Curves.easeOut)),
              weight: 45,
            ),
            TweenSequenceItem(
              tween: Tween(
                begin: 1.25,
                end: 1.0,
              ).chain(CurveTween(curve: Curves.easeOutBack)),
              weight: 55,
            ),
          ]).animate(
            CurvedAnimation(
              parent: _controller,
              curve: const Interval(0, 0.55, curve: Curves.linear),
            ),
          );
  }

  @override
  void didUpdateWidget(covariant VoyagerCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    final target = !widget.value;
    if (target && widget.celebrateOnComplete) _celebrate();
    widget.onChanged(target);
  }

  void _celebrate() {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    ConfettiOverlay.burst(
      context,
      globalPosition: box.localToGlobal(box.size.center(Offset.zero)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    return MouseRegion(
      // opaque:false so a row-wide hover highlight underneath keeps showing.
      opaque: false,
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: Padding(
          key: _boxKey,
          padding: const EdgeInsets.all(10),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Transform.scale(
              scale: _scale.value,
              child: _visual(
                theme: theme,
                accent: accent,
                progress: _controller.value,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _visual({
    required ThemeData theme,
    required Color accent,
    required double progress,
  }) {
    final p = progress.clamp(0.0, 1.0);
    final borderRest = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    // Show a faint preview check on hover; once completing, the check tracks
    // the fill so there's no flicker. The box itself is only colored by [p].
    final checkOpacity = _hovered ? (p < 0.5 ? 0.5 : p) : p;
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: p),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: Color.lerp(borderRest, accent, p)!,
          width: 1.5,
        ),
      ),
      child: Opacity(
        opacity: checkOpacity,
        child: CustomPaint(
          size: const Size(14, 14),
          painter: CheckMarkPainter(
            color: Color.lerp(accent, VoyagerColors.of(context).onAccent, p)!,
          ),
        ),
      ),
    );
  }
}

class CheckMarkPainter extends CustomPainter {
  CheckMarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final start = Offset(w * 0.15, w * 0.45);
    final mid = Offset(w * 0.4, w * 0.7);
    final end = Offset(w * 0.85, w * 0.25);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(mid.dx, mid.dy)
      ..lineTo(end.dx, end.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CheckMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
