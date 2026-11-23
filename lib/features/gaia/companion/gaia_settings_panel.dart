import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_actions_tab.dart';
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
class GaiaSettingsPanelView extends StatelessWidget {
  const GaiaSettingsPanelView({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
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
        child: Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TabStrip(controller: controller),
              const Divider(height: 1),
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey(panel.tab),
                  child: switch (panel.tab) {
                    GaiaPanelTab.actions => GaiaActionsTab(
                      controller: controller,
                    ),
                    GaiaPanelTab.queue => GaiaQueueTab(controller: controller),
                    GaiaPanelTab.status => GaiaStatusTab(
                      controller: controller,
                    ),
                    GaiaPanelTab.setup => GaiaSetupTab(controller: controller),
                    GaiaPanelTab.settings => GaiaSettingsTab(
                      controller: controller,
                    ),
                    _ => const _NotYet(),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      children: [
        const SizedBox(width: 12),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
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
          ),
        ),
        Tooltip(
          message: 'Close settings (Esc)',
          child: GaiaButton(
            icon: Icons.close,
            size: 30,
            onPressed: controller.closePanel,
          ),
        ),
        const SizedBox(width: 12),
      ],
    ),
  );
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

/// A tab still to come here (GAIA_SETTINGS_HLD.md §10).
class _NotYet extends StatelessWidget {
  const _NotYet();

  @override
  Widget build(BuildContext context) => GaiaPanelScroll(
    slivers: [
      SliverToBoxAdapter(
        child: Text(
          "Not here yet. It's on the Gaia page in Voyager for now.",
          style: GaiaType.row.copyWith(color: GaiaInk.muted),
        ),
      ),
    ],
  );
}

/// The readable width a tab's content is held to, centred in the panel.
const kGaiaPanelContentWidth = 760.0;

/// A tab's one scroll (GAIA_SETTINGS_HLD.md §2.3): [slivers] held to
/// [kGaiaPanelContentWidth] and centred. Nothing inside scrolls on its own.
class GaiaPanelScroll extends StatelessWidget {
  const GaiaPanelScroll({super.key, required this.slivers});

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = max(
        24.0,
        (constraints.maxWidth - kGaiaPanelContentWidth) / 2,
      );
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
            Transform.scale(
              scale: 0.75,
              child: Switch(value: widget.value, onChanged: widget.onChanged),
            ),
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
  });

  final TextEditingController controller;
  final String? hintText;
  final int? minLines;
  final int maxLines;
  final VoidCallback? onSubmitted;

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
  );
}

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
