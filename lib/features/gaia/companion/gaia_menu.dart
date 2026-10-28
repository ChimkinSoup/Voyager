part of 'gaia_notch.dart';

/// One row in a [GaiaMenu].
class GaiaMenuItem {
  const GaiaMenuItem({
    required this.label,
    required this.onPressed,
    this.icon,
    this.detail,
    this.shortcut,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  /// Muted text after the label, such as what a command does.
  final String? detail;

  /// Muted, at the row's right, such as Ctrl+C.
  final String? shortcut;

  /// In the error colour, such as Delete.
  final bool destructive;
}

/// Opens a [GaiaMenu] of [items] at [position], in global coordinates, as a
/// right-click does. Any other context menu open closes.
void showGaiaMenu(
  BuildContext context,
  Offset position,
  List<GaiaMenuItem> items,
) {
  final menu = ContextMenuController();
  menu.show(
    context: context,
    contextMenuBuilder: (context) => GaiaMenu(
      anchor: position,
      items: items,
      onClose: menu.remove,
      autofocus: true,
    ),
  );
}

/// An [EditableText.contextMenuBuilder] for Gaia: the field's own buttons
/// as a [GaiaMenu], then [extra]. With an [onPaste], Paste is always
/// offered and runs it, so it can take what plain text paste can't, such
/// as an image.
Widget gaiaTextMenu(
  BuildContext context,
  EditableTextState state, {
  List<GaiaMenuItem> extra = const [],
  VoidCallback? onPaste,
}) {
  final items = [
    for (final button in state.contextMenuButtonItems)
      if (onPaste == null || button.type != ContextMenuButtonType.paste)
        _fromButton(context, button),
  ];
  if (onPaste != null && !state.widget.readOnly) {
    // Before Select all, as it would have been.
    final at = state.contextMenuButtonItems
        .where((button) => button.type != ContextMenuButtonType.paste)
        .toList()
        .indexWhere((button) => button.type == ContextMenuButtonType.selectAll);
    items.insert(
      at < 0 ? items.length : at,
      GaiaMenuItem(
        label: 'Paste',
        icon: Icons.content_paste,
        shortcut: 'Ctrl+V',
        onPressed: onPaste,
      ),
    );
  }
  return GaiaMenu(
    anchor: state.contextMenuAnchors.primaryAnchor,
    items: [...items, ...extra],
    onClose: state.hideToolbar,
  );
}

GaiaMenuItem _fromButton(BuildContext context, ContextMenuButtonItem button) {
  final (icon, shortcut) = switch (button.type) {
    ContextMenuButtonType.cut => (Icons.content_cut, 'Ctrl+X'),
    ContextMenuButtonType.copy => (Icons.content_copy, 'Ctrl+C'),
    ContextMenuButtonType.paste => (Icons.content_paste, 'Ctrl+V'),
    ContextMenuButtonType.selectAll => (Icons.select_all, 'Ctrl+A'),
    _ => (null, null),
  };
  return GaiaMenuItem(
    label: AdaptiveTextSelectionToolbar.getButtonLabel(context, button),
    icon: icon,
    shortcut: shortcut,
    onPressed: button.onPressed ?? () {},
  );
}

/// Gaia's right-click menu, in the notch's look: its ring at [anchor],
/// growing on the notch's spring as the rows come in one by one out of a
/// blur. Up and Down or Tab move between rows, Enter or Space picks, Esc or
/// a click outside closes.
class GaiaMenu extends StatefulWidget {
  const GaiaMenu({
    super.key,
    required this.anchor,
    required this.items,
    required this.onClose,
    this.autofocus = false,
  });

  /// Where it opens, in global coordinates; pushed back in from the
  /// window's edges.
  final Offset anchor;
  final List<GaiaMenuItem> items;
  final VoidCallback onClose;

  /// Takes the focus, so the keys work at once, and gives it back on close.
  /// Off for a text field's, which keeps the focus.
  final bool autofocus;

  @override
  State<GaiaMenu> createState() => _GaiaMenuState();
}

/// Between the menu and the window's edges.
const _menuMargin = 8.0;

class _GaiaMenuState extends State<GaiaMenu>
    with SingleTickerProviderStateMixin {
  /// Runs, linearly, until the last row has settled.
  late final _entrance = AnimationController(
    vsync: this,
    duration:
        _optionsDelay +
        _optionsStagger * (widget.items.length - 1) +
        _springTime,
  )..forward();

  /// What had the focus when it opened, which gets it back on close.
  FocusNode? _returnFocus;

  @override
  void initState() {
    super.initState();
    // Now, before the menu's own autofocus takes it.
    if (widget.autofocus) _returnFocus = FocusManager.instance.primaryFocus;
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  void _close() {
    widget.onClose();
    _returnFocus?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + _menuMargin;
    return Padding(
      padding: EdgeInsets.fromLTRB(_menuMargin, top, _menuMargin, _menuMargin),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: widget.anchor - Offset(_menuMargin, top),
        ),
        child: TapRegion(
          onTapOutside: (_) => _close(),
          // Out of the corner at the cursor.
          child: _MenuShell(growFrom: Alignment.topLeft, child: _rows(context)),
        ),
      ),
    );
  }

  Widget _rows(BuildContext context) {
    // Outside the scope, so they're heard while the scope itself has the
    // focus, before Down moves it onto a row.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            FocusManager.instance.primaryFocus?.nextFocus(),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            FocusManager.instance.primaryFocus?.previousFocus(),
      },
      // A scope of its own, so Tab and the arrows stay among the rows.
      child: FocusScope(
        child: Focus(
          autofocus: widget.autofocus,
          skipTraversal: true,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 168),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, item) in widget.items.indexed) ...[
                      if (index > 0) const SizedBox(height: 2),
                      _Entering(
                        entrance: _entrance,
                        delay: _optionsDelay + _optionsStagger * index,
                        leaving: null,
                        leaveDelay: Duration.zero,
                        child: _Pressable(
                          onPressed: () {
                            _close();
                            item.onPressed();
                          },
                          builder: (lit) => _menuRow(context, item, lit),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer's `/` palette in a [GaiaMenu]'s look, [width] wide and
/// growing up out of its bottom left corner. The focus stays in the
/// composer, whose keys move [highlight] and pick.
class GaiaPalette extends StatefulWidget {
  const GaiaPalette({
    super.key,
    required this.items,
    required this.highlight,
    required this.width,
  });

  final List<GaiaMenuItem> items;

  /// Lit as a hovered row is.
  final int highlight;
  final double width;

  @override
  State<GaiaPalette> createState() => _GaiaPaletteState();
}

class _GaiaPaletteState extends State<GaiaPalette>
    with SingleTickerProviderStateMixin {
  /// The rows it opened with come in one by one; any more, as the query
  /// is backspaced, come in with the last of them.
  late final _rowsAtOpen = widget.items.length;
  late final _entrance = AnimationController(
    vsync: this,
    duration: _optionsDelay + _optionsStagger * (_rowsAtOpen - 1) + _springTime,
  )..forward();

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _MenuShell(
      growFrom: Alignment.bottomLeft,
      // Less the ring's edge.
      child: SizedBox(
        width: widget.width - 2,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, item) in widget.items.indexed) ...[
                  if (index > 0) const SizedBox(height: 2),
                  // Keyed, so a row's hover stays with it as the query
                  // filters the rows above it.
                  KeyedSubtree(
                    key: ValueKey(item.label),
                    child: _Entering(
                      entrance: _entrance,
                      delay:
                          _optionsDelay +
                          _optionsStagger * index.clamp(0, _rowsAtOpen - 1),
                      leaving: null,
                      leaveDelay: Duration.zero,
                      child: _Pressable(
                        onPressed: item.onPressed,
                        builder: (lit) => _menuRow(
                          context,
                          item,
                          lit || index == widget.highlight,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A [GaiaMenu]'s panel: [child] in a [GaiaGlowRing] with its shadow,
/// growing on the notch's spring out of its [growFrom] corner, as the
/// notch grows out of its bar.
class _MenuShell extends StatefulWidget {
  const _MenuShell({required this.growFrom, required this.child});

  final Alignment growFrom;
  final Widget child;

  @override
  State<_MenuShell> createState() => _MenuShellState();
}

class _MenuShellState extends State<_MenuShell>
    with SingleTickerProviderStateMixin {
  late final _grow = AnimationController(vsync: this, duration: _springTime)
    ..forward();
  late final _grown = CurvedAnimation(
    parent: _grow,
    curve: const _SpringCurve(_shellSpring),
  );

  var _hovered = false;

  @override
  void dispose() {
    _grown.dispose();
    _grow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedBuilder(
        animation: _grow,
        builder: (context, ring) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55 * _grow.value),
                offset: const Offset(0, 12),
                blurRadius: 40,
                spreadRadius: -8,
              ),
            ],
          ),
          child: ring,
        ),
        child: GaiaGlowRing(
          radius: _radius,
          hovered: _hovered,
          child: AnimatedBuilder(
            animation: _grown,
            builder: (context, rows) => Align(
              alignment: widget.growFrom,
              widthFactor: lerpDouble(0.5, 1, _grown.value),
              heightFactor: lerpDouble(0.15, 1, _grown.value),
              child: rows,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

Widget _menuRow(BuildContext context, GaiaMenuItem item, bool lit) {
  final error = Theme.of(context).colorScheme.error;
  final color = item.destructive
      ? error
      : lit
      ? Colors.white
      : _dim;
  return AnimatedContainer(
    duration: _fade,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: item.destructive
          ? error.withValues(alpha: lit ? 0.12 : 0)
          : Colors.white.withValues(alpha: lit ? 0.05 : 0),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      children: [
        if (item.icon case final icon?) ...[
          Icon(icon, size: 16, color: item.destructive || lit ? color : _muted),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: item.label),
                if (item.detail case final detail?)
                  TextSpan(
                    text: '  $detail',
                    style: const TextStyle(color: _muted),
                  ),
              ],
            ),
            style: _textStyle.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (item.shortcut case final shortcut?) ...[
          const SizedBox(width: 24),
          Text(shortcut, style: _triggerStyle.copyWith(color: _muted)),
        ],
      ],
    ),
  );
}
