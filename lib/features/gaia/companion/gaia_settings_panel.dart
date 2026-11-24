import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_actions_tab.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_memories_tab.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_queue_tab.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_settings_tab.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_setup_tab.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_status_tab.dart';
import 'package:voyager/features/gaia/gaia_keybinds.dart';

/// The settings panel's tabs (GAIA_SETTINGS_HLD.md §1), in the strip's order.
enum GaiaPanelTab {
  memories('Memories'),
  actions('Actions'),
  queue('Queue'),
  status('Status'),
  setup('Setup'),
  settings('Settings');

  const GaiaPanelTab(this.label);

  final String label;
}

/// The settings panel (GAIA_SETTINGS_HLD.md §2.2): whether it's open in the
/// Gaia window, and the tab it shows. Local to this desktop, like
/// `GaiaSidebar`: only the last tab is kept, in a JSON [file]. Null in tests,
/// which keep nothing.
class GaiaSettingsPanel extends ChangeNotifier {
  GaiaSettingsPanel({this.file});

  final File? file;

  var open = false;
  var tab = GaiaPanelTab.actions;

  Future<void> load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map;
      tab = GaiaPanelTab.values.asNameMap()[json['tab']] ?? tab;
    } catch (error) {
      debugPrint('[gaia] settings panel unreadable, using defaults: $error');
    }
    notifyListeners();
  }

  void setOpen(bool value) {
    if (open == value) return;
    open = value;
    notifyListeners();
  }

  void setTab(GaiaPanelTab value) {
    if (tab == value) return;
    tab = value;
    notifyListeners();
    // In turn, so an older write never lands after a newer one.
    _saved = _saved.then((_) => _save());
  }

  var _saved = Future<void>.value();

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'tab': tab.name}));
    } catch (error) {
      debugPrint('[gaia] settings panel not saved: $error');
    }
  }
}

/// The panel's body under the Gaia window's header: the tab strip with ×,
/// then the tab. Its keys: Esc closes it (a text box or menu with the focus
/// keeps its own), Ctrl+1 to Ctrl+6 pick a tab.
class GaiaSettingsPanelView extends StatefulWidget {
  const GaiaSettingsPanelView({
    super.key,
    required this.controller,
    this.askChat,
  });

  final GaiaController controller;

  /// The Ask Gaia chat for the Memories tab's review, while it shows one
  /// (GAIA_SETTINGS_HLD.md §7).
  final Widget? askChat;

  @override
  State<GaiaSettingsPanelView> createState() => _GaiaSettingsPanelViewState();
}

class _GaiaSettingsPanelViewState extends State<GaiaSettingsPanelView> {
  /// Times the Memories tab was left with its chat open. Left so, it goes
  /// at once rather than fading: fading out, its chat column would show the
  /// chat it gave back, and only one chat column is ever built.
  var _cuts = 0;

  @override
  void didUpdateWidget(GaiaSettingsPanelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.askChat != null &&
        widget.controller.panel.tab != GaiaPanelTab.memories) {
      _cuts++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final panel = controller.panel;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused?.findAncestorStateOfType<EditableTextState>() == null) {
            controller.closePanel();
          }
        },
        for (final (i, tab) in GaiaPanelTab.values.indexed)
          gaiaPanelTabActivator(i): () => controller.showPanelTab(tab),
      },
      child: FocusScope(
        autofocus: true,
        // The sky shows through, dimmed, so the panel is still in Gaia's
        // window rather than over it.
        child: Material(
          color: Theme.of(
            context,
          ).scaffoldBackgroundColor.withValues(alpha: 0.82),
          child: AnimatedSwitcher(
            key: ValueKey(_cuts),
            duration: GaiaMotion.quick,
            switchInCurve: GaiaMotion.curve,
            switchOutCurve: GaiaMotion.curve,
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.01),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey(panel.tab),
              child: switch (panel.tab) {
                GaiaPanelTab.actions => GaiaActionsTab(controller: controller),
                GaiaPanelTab.queue => GaiaQueueTab(controller: controller),
                GaiaPanelTab.status => GaiaStatusTab(controller: controller),
                GaiaPanelTab.setup => GaiaSetupTab(controller: controller),
                GaiaPanelTab.settings => GaiaSettingsTab(
                  controller: controller,
                ),
                GaiaPanelTab.memories => GaiaMemoriesTab(
                  controller: controller,
                  askChat: widget.askChat,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The panel's tabs, in the Gaia window's header in place of a chat's
/// title. They start where a tab's content does, at [kGaiaPanelContentWidth]
/// centred, once the window is wide enough; [start] is where they'd be
/// otherwise, from the window's left edge.
class GaiaPanelTabs extends StatelessWidget {
  const GaiaPanelTabs({
    super.key,
    required this.controller,
    required this.start,
  });

  final GaiaController controller;
  final double start;

  @override
  Widget build(BuildContext context) {
    final side = gaiaPanelSide(MediaQuery.sizeOf(context).width);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.only(left: max(0, side - start)),
      child: Row(
        children: [
          for (final (i, tab) in GaiaPanelTab.values.indexed)
            Tooltip(
              message: 'Ctrl+${i + 1}',
              child: _TabLabel(
                label: tab.label,
                selected: controller.panel.tab == tab,
                onTap: () => controller.showPanelTab(tab),
              ),
            ),
        ],
      ),
    );
  }
}

/// A tab's label in the sidebar's row look: dim, white under the cursor,
/// and the selected one lit and edged in the glow rings' rim.
class _TabLabel extends StatefulWidget {
  const _TabLabel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TabLabel> createState() => _TabLabelState();
}

class _TabLabelState extends State<_TabLabel> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: GaiaMotion.quick,
          height: 32,
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? GaiaInk.selected
                : _hovered
                ? GaiaInk.hover
                : GaiaInk.hover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(GaiaRadius.row),
            border: Border.all(
              color: selected
                  ? GaiaInk.hairline
                  : GaiaInk.hairline.withValues(alpha: 0),
            ),
          ),
          child: AnimatedDefaultTextStyle(
            duration: GaiaMotion.quick,
            style: DefaultTextStyle.of(context).style
                .merge(GaiaType.row)
                .copyWith(
                  color: selected || _hovered ? Colors.white : GaiaInk.muted,
                ),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}

/// The readable width a tab's content is held to, centred in the panel.
const kGaiaPanelContentWidth = 760.0;

/// The space each side of a tab's content in a panel [width] wide.
double gaiaPanelSide(double width) =>
    max(24.0, (width - kGaiaPanelContentWidth) / 2);

/// A tab's one scroll (GAIA_SETTINGS_HLD.md §2.3): [slivers] held to
/// [kGaiaPanelContentWidth] and centred. Nothing inside scrolls on its own.
class GaiaPanelScroll extends StatelessWidget {
  const GaiaPanelScroll({super.key, required this.slivers});

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = gaiaPanelSide(constraints.maxWidth);
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 20, side, 32),
            sliver: SliverMainAxisGroup(slivers: slivers),
          ),
        ],
      );
    },
  );
}

/// A section's heading in a tab, in the sidebar's heading style.
class GaiaPanelHeading extends StatelessWidget {
  const GaiaPanelHeading(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 14, 4, 6),
    child: SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: GaiaType.heading,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

/// What a section is for, muted, under its heading.
class GaiaPanelNote extends StatelessWidget {
  const GaiaPanelNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
    child: Text(
      text,
      style: GaiaType.row.copyWith(
        color: GaiaInk.muted,
        fontWeight: FontWeight.w400,
      ),
    ),
  );
}

/// A setting that's on or off, as a Gaia row: its [title] and what it does,
/// the switch at the right. A click anywhere on the row flips it.
class GaiaPanelSwitch extends StatefulWidget {
  const GaiaPanelSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<GaiaPanelSwitch> createState() => _GaiaPanelSwitchState();
}

class _GaiaPanelSwitchState extends State<GaiaPanelSwitch> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onChanged(!widget.value),
      child: AnimatedContainer(
        duration: GaiaMotion.quick,
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        decoration: BoxDecoration(
          color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(GaiaRadius.row),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: GaiaType.row.copyWith(
                      color: _hovered ? GaiaInk.bright : GaiaInk.dim,
                    ),
                  ),
                  if (widget.subtitle case final subtitle?)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: GaiaType.label.copyWith(
                          color: GaiaInk.muted,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            GaiaToggle(value: widget.value, onChanged: widget.onChanged),
            const SizedBox(width: 6),
          ],
        ),
      ),
    ),
  );
}

/// A text box in the panel: [GaiaTextField], with its own focus node.
/// Enter calls [onSubmitted] in a one-line box (Shift+Enter is a newline in
/// a taller one, where Enter is too).
class GaiaPanelField extends StatefulWidget {
  const GaiaPanelField({
    super.key,
    required this.controller,
    this.hintText,
    this.minLines,
    this.maxLines = 1,
    this.onSubmitted,
    this.trailing,
  });

  final TextEditingController controller;
  final String? hintText;
  final int? minLines;
  final int maxLines;
  final VoidCallback? onSubmitted;

  /// Inside the box at its bottom right, such as Save.
  final Widget? trailing;

  @override
  State<GaiaPanelField> createState() => _GaiaPanelFieldState();
}

class _GaiaPanelFieldState extends State<GaiaPanelField> {
  late final _focus = FocusNode(
    debugLabel: 'gaia panel field',
    onKeyEvent: (node, event) {
      final submit = widget.onSubmitted;
      if (submit == null ||
          widget.maxLines != 1 ||
          event is! KeyDownEvent ||
          (event.logicalKey != LogicalKeyboardKey.enter &&
              event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
        return KeyEventResult.ignored;
      }
      submit();
      return KeyEventResult.handled;
    },
  );

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GaiaTextField(
    controller: widget.controller,
    focusNode: _focus,
    hintText: widget.hintText,
    minLines: widget.minLines,
    maxLines: widget.maxLines,
    trailing: widget.trailing,
    style: kGaiaPanelFieldStyle,
    fill: gaiaPanelFieldFill(context),
  );
}

/// A panel text box's text: at the rows' size.
const kGaiaPanelFieldStyle = TextStyle(fontSize: 13);

/// A panel text box's fill: the surface a little towards black, so it sits
/// in the panel's blue rather than as a grey slab on it.
Color gaiaPanelFieldFill(BuildContext context) =>
    Color.lerp(Theme.of(context).colorScheme.surface, Colors.black, 0.25)!;

/// One of a few choices, as a pill in the tab strip's look: dim, lit under
/// the cursor, and the chosen one filled and edged.
class GaiaPanelChoice extends StatelessWidget {
  const GaiaPanelChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  // As wide as its label: the tab label's centring fills a Wrap's width.
  Widget build(BuildContext context) => IntrinsicWidth(
    child: _TabLabel(label: label, selected: selected, onTap: onTap),
  );
}

/// A section of a tab: its [heading], then its [children] together on a
/// card, so a long tab reads as groups rather than one column.
class GaiaPanelSection extends StatelessWidget {
  const GaiaPanelSection({
    super.key,
    required this.heading,
    this.trailing,
    required this.children,
  });

  final String heading;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      GaiaPanelHeading(heading, trailing: trailing),
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        decoration: BoxDecoration(
          color: GaiaInk.hover,
          borderRadius: BorderRadius.circular(GaiaRadius.panel),
          border: Border.all(color: GaiaInk.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ],
  );
}

/// On or off, in Gaia's look: a pill in the glow rings' rim, filled with
/// the accent while on.
class GaiaToggle extends StatefulWidget {
  const GaiaToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<GaiaToggle> createState() => _GaiaToggleState();
}

class _GaiaToggleState extends State<GaiaToggle> {
  /// Reached with Tab, and flipped with Enter or Space: its rim lit.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final value = widget.value;
    final onChanged = widget.onChanged;
    final flip = onChanged == null ? null : () => onChanged(!value);
    return Semantics(
      toggled: value,
      child: FocusableActionDetector(
        enabled: flip != null,
        mouseCursor: flip == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => flip?.call(),
          ),
        },
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: flip,
          child: AnimatedContainer(
            duration: GaiaMotion.quick,
            curve: GaiaMotion.curve,
            width: 32,
            height: 18,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: value
                  ? accent.withValues(alpha: 0.25)
                  : accent.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: _focused
                    ? accent
                    : value
                    ? accent.withValues(alpha: 0.8)
                    : GaiaInk.faint.withValues(alpha: 0.6),
              ),
            ),
            child: AnimatedAlign(
              duration: GaiaMotion.quick,
              curve: GaiaMotion.curve,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: AnimatedContainer(
                duration: GaiaMotion.quick,
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? GaiaInk.bright : GaiaInk.faint,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A key's name in a chip, as the empty chat's hints show it. With [onTap],
/// it lights under the cursor and takes a click.
class GaiaKeyChip extends StatefulWidget {
  const GaiaKeyChip(this.label, {super.key, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<GaiaKeyChip> createState() => _GaiaKeyChipState();
}

class _GaiaKeyChipState extends State<GaiaKeyChip> {
  var _hovered = false;

  /// Reached with Tab, and pressed with Enter or Space: lit as hovered.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final lit = (_hovered || _focused) && widget.onTap != null;
    return FocusableActionDetector(
      enabled: widget.onTap != null,
      mouseCursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => widget.onTap?.call(),
        ),
      },
      onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: GaiaMotion.quick,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: lit ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(GaiaRadius.chip),
            border: Border.all(color: lit ? GaiaInk.faint : GaiaInk.hairline),
          ),
          child: Text(
            widget.label,
            style: GaiaType.label.copyWith(
              color: lit ? GaiaInk.bright : GaiaInk.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// A tab with nothing in it, as the empty chat is: a line in the middle,
/// then [detail] or the keys that would fill it.
class GaiaPanelEmpty extends StatelessWidget {
  const GaiaPanelEmpty({
    super.key,
    required this.title,
    this.detail,
    this.hints = const [],
  });

  final String title;
  final String? detail;

  /// Each key's name and what it does.
  final List<(String, String)> hints;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w500,
              color: GaiaInk.dim,
            ),
          ),
          if (detail case final detail?) ...[
            const SizedBox(height: 10),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: GaiaType.row.copyWith(
                color: GaiaInk.muted,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
          if (hints.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 20,
              runSpacing: 8,
              children: [
                for (final (key, does) in hints)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GaiaKeyChip(key),
                      const SizedBox(width: 6),
                      Text(
                        does,
                        style: GaiaType.label.copyWith(color: GaiaInk.faint),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}
