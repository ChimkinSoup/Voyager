import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_aurora_edge.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_picker.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

/// Calmer stand-ins for [GaiaGlowRing], the circling light still round the
/// notch (the composer's account and tier capsule, its +), the right-click
/// menu, the / palette, the search panel, the date picker and the toast.
/// Each is drawn onto the real notch and menu through [GaiaRingLook], and
/// none runs a ticker, as the rounded buttons don't.
enum _Look {
  hairline(
    'Hairline',
    "The menu's dark fill in a one pixel white edge, as the floating "
        'panels (topic picker, memory review) already are. Hover brightens '
        'the edge.',
  ),
  quiet(
    'Quiet fill',
    'No edge: the dark fill lifted by the same faint white a labelled '
        "button rests on, a little more on hover. The rounded buttons' kin.",
  ),
  tint(
    'Accent tint',
    'Quiet fill, washing to a faint accent tint on hover, as a rounded '
        'button does. The accent arrives as colour, not light.',
  ),
  accentEdge(
    'Accent edge',
    "A hairline at rest that eases to the accent on hover: the light's "
        'colour, without the motion.',
  ),
  topLight(
    'Top light',
    'A hairline brighter along the top than the bottom, as if lit from '
        'above; hover brightens it. Glassy, still static.',
  ),
  halo(
    'Halo',
    'A hairline, with a soft even glow in the accent all round it on '
        'hover: where the light would have been, but still.',
  ),
  frosted(
    'Frosted',
    'A hairline over a translucent fill that blurs what is behind it. '
        'Lighter weight; open the menu over this dialog to see it.',
  ),
  liftedTint(
    'Lifted tint',
    'Split by role. The capsule and + wear Accent tint, as part of the '
        'composer. What floats (menu, toast) sits a step lighter than the '
        'chat in a white edge, so brightness and the edge set it apart, '
        'with the same accent wash on hover. No blur.',
  ),
  frostedMenus(
    'Frosted (menus only)',
    'Split by role. The capsule and + wear Accent tint, so nothing always '
        'on screen blurs. What floats (menu, toast) is frosted: a lighter '
        'blur and a more see-through fill than Frosted, so the frost shows '
        'over the chat. Both are edged in a grey line that turns the accent '
        'on hover, as Accent edge does.',
  ),
  frostedMenusV2(
    'Frosted (menus only) v2',
    'Frosted (menus only), but hover brings the text field\'s aurora up '
        'along the grey line instead of a solid accent: soft lights in hues '
        'round the accent drifting slowly, with a faint glow and shimmer.',
  );

  const _Look(this.label, this.description);
  final String label, description;

  /// What the notches wear: the split studies keep Accent tint on them and
  /// use their own look only for what floats.
  _Look get capsule => switch (this) {
    liftedTint || frostedMenus || frostedMenusV2 => tint,
    _ => this,
  };

  /// For [GaiaRingLook.builder].
  Widget build({
    required double radius,
    required bool hovered,
    required double backdrop,
    required Color accent,
    required Widget child,
  }) => _animated(radius, hovered, backdrop, accent, child, capsule: false);

  /// [build], for a notch.
  Widget buildCapsule({
    required double radius,
    required bool hovered,
    required double backdrop,
    required Color accent,
    required Widget child,
  }) => _animated(radius, hovered, backdrop, accent, child, capsule: true);

  Widget _animated(
    double radius,
    bool hovered,
    double backdrop,
    Color accent,
    Widget child, {
    required bool capsule,
  }) => TweenAnimationBuilder<double>(
    tween: Tween(end: hovered ? 1 : 0),
    duration: GaiaMotion.quick,
    curve: GaiaMotion.curve,
    child: child,
    builder: (context, t, child) =>
        _shell(context, t, radius, backdrop, accent, child!, capsule: capsule),
  );

  Widget _shell(
    BuildContext context,
    double t,
    double radius,
    double backdrop,
    Color accent,
    Widget child, {
    required bool capsule,
  }) {
    final look = capsule ? this.capsule : this;
    final white = Colors.white;
    final base = Color.lerp(
      Theme.of(context).colorScheme.surface,
      Colors.black,
      0.5,
    )!;
    // Faded with the notch's backdrop, as the ring is.
    Color shown(Color color) => color.withValues(alpha: color.a * backdrop);
    final edge = switch (look) {
      quiet || tint => Colors.transparent,
      hairline => Color.lerp(
        GaiaInk.hairline,
        white.withValues(alpha: 0.2),
        t,
      )!,
      accentEdge => Color.lerp(
        GaiaInk.hairline,
        accent.withValues(alpha: 0.55),
        t,
      )!,
      liftedTint => Color.lerp(
        white.withValues(alpha: 0.12),
        white.withValues(alpha: 0.2),
        t,
      )!,
      _ => GaiaInk.hairline,
    };
    // Frosted (menus only): a grey line, round its capsule too, that turns
    // the accent on hover.
    final line = this == frostedMenusV2
        ? white.withValues(alpha: 0.14)
        : this == frostedMenus
        ? Color.lerp(
            white.withValues(alpha: 0.14),
            accent.withValues(alpha: 0.9),
            t,
          )!
        : edge;
    final fill = switch (look) {
      quiet => Color.alphaBlend(white.withValues(alpha: 0.05 + 0.03 * t), base),
      tint => Color.alphaBlend(
        Color.lerp(
          white.withValues(alpha: 0.05),
          accent.withValues(alpha: 0.12),
          t,
        )!,
        base,
      ),
      frosted => base.withValues(alpha: 0.7),
      // Over the surface itself rather than darkened, then lighter still.
      liftedTint => Color.alphaBlend(
        Color.lerp(
          white.withValues(alpha: 0.07),
          Color.alphaBlend(
            accent.withValues(alpha: 0.1),
            white.withValues(alpha: 0.07),
          ),
          t,
        )!,
        Theme.of(context).colorScheme.surface,
      ),
      frostedMenus || frostedMenusV2 => base.withValues(alpha: 0.55),
      _ => base,
    };
    final isFrosted =
        look == frosted || look == frostedMenus || look == frostedMenusV2;
    final shell = DecoratedBox(
      decoration: BoxDecoration(
        // A border, not a fill under the shell: a see-through fill would
        // show it all over rather than round the edge.
        // A frosted shell's is drawn over its clip instead, below.
        border: look == topLight || isFrosted
            ? null
            : Border.all(color: shown(line)),
        gradient: look == topLight
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  shown(white.withValues(alpha: 0.2 + 0.1 * t)),
                  shown(white.withValues(alpha: 0.06)),
                  shown(white.withValues(alpha: 0.04)),
                ],
                stops: const [0, 0.5, 1],
              )
            : null,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          if (look == halo)
            BoxShadow(
              color: shown(accent.withValues(alpha: 0.3 * t)),
              blurRadius: 18,
              spreadRadius: -2,
            ),
        ],
      ),
      // The ring's 1 px, so each sits exactly where the ring does.
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: shown(fill),
            borderRadius: BorderRadius.circular(radius - 1),
          ),
          child: child,
        ),
      ),
    );
    final blur = (look == frosted ? 16 : 10) * backdrop;
    final frost = switch (look) {
      // Always there, so a bare notch opening keeps its contents' state.
      // Its line over the clip, not inside it, where the clip's
      // antialiasing would soften its outer half into a haze.
      frosted || frostedMenus || frostedMenusV2 => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: shown(line)),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            // Bounded: it blurs only what's under the shell, so nothing just
            // past its edge bleeds in as a haze.
            filterConfig: ImageFilterConfig.blur(
              sigmaX: blur,
              sigmaY: blur,
              bounded: true,
            ),
            child: shell,
          ),
        ),
      ),
      _ => shell,
    };
    if (this != frostedMenusV2) return frost;
    // Outside the clip, so its glow spreads past the edge.
    return _AuroraLine(
      t: t * backdrop,
      radius: radius,
      accent: accent,
      // The capsule is small: a full field's glow would swamp it.
      scale: capsule ? 0.6 : 1,
      child: frost,
    );
  }
}

/// The text field's aurora on a shell's edge, [t] of the way lit: its loop
/// runs only while it shows.
class _AuroraLine extends StatefulWidget {
  const _AuroraLine({
    required this.t,
    required this.radius,
    required this.accent,
    required this.scale,
    required this.child,
  });

  final double t, radius, scale;
  final Color accent;
  final Widget child;

  @override
  State<_AuroraLine> createState() => _AuroraLineState();
}

class _AuroraLineState extends State<_AuroraLine>
    with SingleTickerProviderStateMixin {
  /// The aurora's loop, as long as the field's.
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(minutes: 2),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_AuroraLine old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.t > 0;
    if (run == _spin.isAnimating) return;
    if (run) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _spin,
    builder: (context, child) => CustomPaint(
      foregroundPainter: gaiaAuroraPainter(
        t: widget.t,
        time: _spin.value,
        // The shell draws the grey line itself.
        rest: Colors.transparent,
        accent: widget.accent,
        radius: widget.radius,
        scale: widget.scale,
      ),
      child: child,
    ),
    child: widget.child,
  );
}

class GaiaShellStudies extends StatefulWidget {
  const GaiaShellStudies({super.key, required this.controller});

  final GaiaController controller;

  @override
  State<GaiaShellStudies> createState() => _GaiaShellStudiesState();
}

class _GaiaShellStudiesState extends State<GaiaShellStudies> {
  /// The capsule as the composer's + is: no shell until it opens.
  var _bare = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          "Each panel has the composer's + and its account and tier capsule, "
          'the real notches, and a toast. Open them, hover them, and '
          'right-click anywhere in a panel for its menu.',
          style: muted,
        ),
        GaiaPanelSwitch(
          title: 'Capsule bare until opened',
          subtitle:
              'The account and tier capsule as the + already is: a faint '
              'trigger with no shell, which fades in as it opens. Pairs '
              'with any look below.',
          value: _bare,
          onChanged: (bare) => setState(() => _bare = bare),
        ),
        const SizedBox(height: 8),
        _StudyPanel(
          look: null,
          title: 'Current',
          description: 'The circling light, for comparison.',
          bare: _bare,
          controller: widget.controller,
        ),
        for (final look in _Look.values)
          _StudyPanel(
            look: look,
            title: look.label,
            description: look.description,
            bare: _bare,
            controller: widget.controller,
          ),
      ],
    );
  }
}

class _StudyPanel extends StatefulWidget {
  const _StudyPanel({
    required this.look,
    required this.title,
    required this.description,
    required this.bare,
    required this.controller,
  });

  /// Null for the glow ring itself.
  final _Look? look;
  final String title, description;
  final bool bare;
  final GaiaController controller;

  @override
  State<_StudyPanel> createState() => _StudyPanelState();
}

class _StudyPanelState extends State<_StudyPanel> {
  GaiaTier? _tier;
  var _account = 'a';
  var _toastHovered = false;

  /// [child] in the study's look, or its [_Look.capsule] look for a notch.
  Widget _wear(Widget child, {bool capsule = false}) => switch (widget.look) {
    final look? => GaiaRingLook(
      builder: capsule ? look.buildCapsule : look.build,
      child: child,
    ),
    null => child,
  };

  void _menu(Offset at) {
    final menu = ContextMenuController();
    menu.show(
      context: context,
      contextMenuBuilder: (_) => _wear(
        GaiaMenu(
          anchor: at,
          autofocus: true,
          onClose: menu.remove,
          items: [
            GaiaMenuItem(
              label: 'Copy',
              icon: Icons.content_copy,
              shortcut: 'Ctrl+C',
              onPressed: () {},
            ),
            GaiaMenuItem(
              label: 'Pin to ',
              accented: 'Voyager',
              icon: Icons.push_pin_outlined,
              onPressed: () {},
            ),
            GaiaMenuItem(
              label: 'Rename',
              icon: Icons.edit_outlined,
              detail: 'this chat',
              onPressed: () {},
            ),
            GaiaMenuItem(
              label: 'Delete',
              icon: Icons.delete_outline,
              destructive: true,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final controller = widget.controller;
    final accounts = [
      for (final (id, label) in [('a', 'Account A'), ('b', 'Account B')])
        GaiaAccount(id: id, label: label, adapter: '', dir: ''),
    ];
    final notches = Row(
      children: [
        GaiaNotch(
          opensRight: true,
          bare: true,
          items: [
            GaiaNotchItem<bool?>(
              trigger: (color) => Icon(Icons.add, size: 16, color: color),
              options: [
                GaiaNotchOption(
                  value: false,
                  label: 'Add files',
                  icon: (color, {required lit}) =>
                      Icon(Icons.description_outlined, size: 16, color: color),
                ),
                GaiaNotchOption(
                  value: true,
                  label: 'Add folder',
                  icon: (color, {required lit}) =>
                      Icon(Icons.folder_outlined, size: 16, color: color),
                ),
              ],
              value: null,
              onChanged: (_) {},
            ),
          ],
        ),
        const Spacer(),
        GaiaNotch(
          bare: widget.bare,
          items: [
            GaiaNotchItem<GaiaAccount>(
              options: [
                for (final account in accounts)
                  GaiaNotchOption(value: account, label: account.label),
              ],
              value: accounts.firstWhere((account) => account.id == _account),
              onChanged: (account) => setState(() => _account = account.id),
            ),
            gaiaTierItem(
              autoOffered: true,
              tier: _tier,
              routing: false,
              agent: (tier) => controller.agentFor(tier)?.label,
              onChanged: (tier) => setState(() => _tier = tier),
            ),
          ],
        ),
      ],
    );
    final toast = MouseRegion(
      onEnter: (_) => setState(() => _toastHovered = true),
      onExit: (_) => setState(() => _toastHovered = false),
      child: GaiaGlowRing(
        radius: GaiaRadius.row,
        hovered: _toastHovered,
        child: const Padding(
          padding: EdgeInsets.fromLTRB(14, 12, 18, 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GaiaToastOrbIcon(mark: GaiaToastMark.done),
              SizedBox(width: 12),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reply ready',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Gaia answered in another chat.',
                      style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onSecondaryTapUp: (details) => _menu(details.globalPosition),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: gaiaSurface(theme.colorScheme.primary),
            borderRadius: BorderRadius.circular(GaiaRadius.panel),
            border: Border.all(color: GaiaInk.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: GaiaInk.bright,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(widget.description, style: muted),
              const SizedBox(height: 12),
              _wear(notches, capsule: true),
              const SizedBox(height: 12),
              Center(child: _wear(toast)),
            ],
          ),
        ),
      ),
    );
  }
}
