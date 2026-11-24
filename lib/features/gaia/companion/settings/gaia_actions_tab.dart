import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_actions.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

/// The settings panel's Actions tab (GAIA_SETTINGS_HLD.md §4): the action
/// log, as the Gaia page shows it (GAIA_HLD.md §17). A row's chat opens
/// that chat; Undo takes back what an accepted proposal saved.
class GaiaActionsTab extends StatelessWidget {
  const GaiaActionsTab({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final actions = controller.actions;
    if (actions != null && actions.isEmpty) {
      return const GaiaPanelEmpty(
        title: 'Nothing yet.',
        detail: 'What Gaia saves or does after you accept it shows here.',
      );
    }
    return GaiaPanelScroll(
      key: const PageStorageKey('gaia panel actions'),
      slivers: [
        if (actions == null)
          const SliverToBoxAdapter(child: SizedBox.shrink())
        else
          SliverList.list(
            children: [
              for (final action in actions)
                _ActionRow(
                  key: ValueKey('${action.message.id}/${action.card.id}'),
                  controller: controller,
                  action: action,
                ),
            ],
          ),
      ],
    );
  }
}

class _ActionRow extends StatefulWidget {
  const _ActionRow({super.key, required this.controller, required this.action});

  final GaiaController controller;
  final GaiaAction action;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  var _hovered = false;
  var _undoing = false;

  Future<void> _undo() async {
    setState(() => _undoing = true);
    try {
      await widget.controller.undoAction(widget.action);
    } on GaiaPipeException catch (error) {
      if (mounted) {
        showGaiaToast(
          context,
          mark: GaiaToastMark.error,
          title: "Couldn't undo",
          body: error.message,
        );
      }
    } finally {
      if (mounted) setState(() => _undoing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (:chat, :message, :card) = widget.action;
    final when = DateFormat.yMMMd().add_Hm().format(
      message.createdAt.toLocal(),
    );
    final IconData icon;
    final String title;
    final String? note;
    var undoable = false;
    var undone = false;
    // Input can't be taken back, so no Undo (GAIA_HLD.md §15.6). The chat
    // has every step.
    if (card.kind == GaiaCardKind.control) {
      final steps = card.input['steps'] as List? ?? const [];
      final ran = (card.answer?['ran'] as num?)?.toInt() ?? 0;
      icon = Icons.ads_click;
      title = gaiaIsActivity(card)
          ? 'Auto: ${card.input['total'] ?? ran} actions'
                "${card.input['app'] == null ? '' : ' in ${card.input['app']}'}"
          : 'Ran $ran of ${steps.length} '
                "${steps.length == 1 ? 'step' : 'steps'} "
                "in ${card.input['app'] ?? 'a window'}";
      note = gaiaControlStopped(card) ? 'stopped' : null;
    } else {
      final proposal = card.proposal!;
      final fields =
          (card.answer?['fields'] as Map?)?.cast<String, Object?>() ??
          proposal.fields;
      undone = card.answer?['undoneAt'] != null;
      undoable = !undone;
      icon = switch (proposal.entity) {
        GaiaProposalEntity.todo => Icons.check_box_outlined,
        GaiaProposalEntity.event => Icons.event_outlined,
        GaiaProposalEntity.journal => Icons.menu_book_outlined,
        GaiaProposalEntity.reminder => Icons.inbox_outlined,
      };
      title = gaiaProposalTitle(proposal, fields);
      note = undone ? 'undone' : null;
    }
    final lit = _hovered && !undone;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: GaiaMotion.quick,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(GaiaRadius.row),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: lit ? GaiaInk.bright : GaiaInk.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: GaiaType.row.copyWith(
                      color: undone
                          ? GaiaInk.faint
                          : lit
                          ? GaiaInk.bright
                          : GaiaInk.dim,
                      decoration: undone ? TextDecoration.lineThrough : null,
                      decorationColor: GaiaInk.faint,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: _ChatLink(
                          title: chat.title,
                          onTap: () => widget.controller.selectChat(chat.id),
                        ),
                      ),
                      Text(
                        [' · $when', ?note].join(' · '),
                        style: GaiaType.label.copyWith(color: GaiaInk.faint),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (undoable) ...[
              const SizedBox(width: 8),
              GaiaButton(
                label: 'Undo',
                icon: Icons.undo,
                size: 30,
                padding: 10,
                onPressed: _undoing ? null : _undo,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The row's chat, which a click opens, closing the panel.
class _ChatLink extends StatefulWidget {
  const _ChatLink({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  State<_ChatLink> createState() => _ChatLinkState();
}

class _ChatLinkState extends State<_ChatLink> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: Text(
        widget.title,
        overflow: TextOverflow.ellipsis,
        style: GaiaType.label.copyWith(
          color: _hovered ? GaiaInk.bright : GaiaInk.muted,
          decoration: _hovered ? TextDecoration.underline : null,
          decorationColor: GaiaInk.bright,
        ),
      ),
    ),
  );
}
