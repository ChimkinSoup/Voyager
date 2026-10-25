import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';

/// The light's pace around the ring, as [GaiaButton]'s: a turn every 16s.
const _spin = math.pi / 8;

const _radius = 8.0;

/// How long a toast stays up while the cursor isn't on it.
const _dwell = Duration(seconds: 4);

OverlayEntry? _current;

/// Shows a toast over Gaia's content, below the header: [GaiaButton]'s
/// ring and circling light around an [icon], a [title] and a [body]. One at
/// a time, so a new one replaces the last. It goes after a few seconds
/// unless the cursor is on it; a click dismisses it, after [onTap].
void showGaiaToast(
  BuildContext context, {
  required String title,
  required String body,
  required IconData icon,
  Color? iconColor,
  VoidCallback? onTap,
}) {
  _current?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _GaiaToast(
      title: title,
      body: body,
      icon: icon,
      iconColor: iconColor,
      onTap: onTap,
      onGone: () {
        if (_current != entry) return;
        _current = null;
        entry.remove();
      },
    ),
  );
  _current = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
}

class _GaiaToast extends StatefulWidget {
  const _GaiaToast({
    required this.title,
    required this.body,
    required this.icon,
    required this.iconColor,
    required this.onTap,
    required this.onGone,
  });

  final String title;
  final String body;
  final IconData icon;
  final Color? iconColor;
  final VoidCallback? onTap;
  final VoidCallback onGone;

  @override
  State<_GaiaToast> createState() => _GaiaToastState();
}

class _GaiaToastState extends State<_GaiaToast> with TickerProviderStateMixin {
  late final _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
  );
  late final _hover = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  /// As [GaiaButton]'s light: clockwise from the right, starting at the top.
  final _angle = ValueNotifier(-math.pi / 2);
  late final Ticker _ticker;
  var _lastTick = Duration.zero;

  /// The cursor over the toast, in its coordinates.
  Offset? _cursor;
  Timer? _dwellTimer;
  var _leaving = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    _shown.forward();
    _dwellTimer = Timer(_dwell, _dismiss);
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    _ticker.dispose();
    _shown.dispose();
    _hover.dispose();
    _angle.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _angle.value += _spin * dt;
  }

  Future<void> _dismiss() async {
    if (_leaving) return;
    _leaving = true;
    _dwellTimer?.cancel();
    await _shown.reverse();
    widget.onGone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final curve = CurvedAnimation(parent: _shown, curve: Curves.easeOutCubic);
    return Positioned(
      left: 16,
      right: 16,
      // Below the header.
      top: 64,
      child: Center(
        child: FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, -0.4),
              end: Offset.zero,
            ).animate(curve),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) {
                _dwellTimer?.cancel();
                _hover.forward();
              },
              onHover: (event) => _cursor = event.localPosition,
              onExit: (_) {
                _cursor = null;
                _hover.reverse();
                if (!_leaving) _dwellTimer = Timer(_dwell, _dismiss);
              },
              child: GestureDetector(
                onTap: () {
                  widget.onTap?.call();
                  unawaited(_dismiss());
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Material(
                    type: MaterialType.transparency,
                    child: _ring(colors),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [GaiaButton]'s ring, around the toast's content.
  Widget _ring(ColorScheme colors) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_radius),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                child: CustomPaint(
                  painter: GaiaGlowPainter(
                    angle: _angle,
                    hover: _hover,
                    cursor: () => _cursor,
                    idle: Color.lerp(colors.primary, Colors.white, 0.5)!,
                    lit: HSLColor.fromColor(
                      colors.primary,
                    ).withSaturation(1).toColor(),
                  ),
                ),
              ),
            ),
          ),
          // Covers all but the ring of the light.
          Padding(
            padding: const EdgeInsets.all(1),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
              decoration: BoxDecoration(
                color: Color.lerp(colors.surface, Colors.black, 0.5),
                borderRadius: BorderRadius.circular(_radius - 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    size: 20,
                    color: widget.iconColor ?? Colors.white,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (widget.body.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
