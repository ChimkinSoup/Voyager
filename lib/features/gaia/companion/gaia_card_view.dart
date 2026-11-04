import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_proposal_card.dart';
import 'package:voyager/features/gaia/host/gaia_flash.dart';

/// A card in a reply (GAIA_HLD.md §10): a question the agent asked through
/// `ask_user`, a permission prompt from its CLI, or a proposal. Open and
/// [waiting], it takes the user's answer: [onPick] an option, [onAllow]
/// (a proposal's save) or [onReject], and a proposal's [onEdit] and
/// [onAcceptAll]. The Gaia page shows it with none of them, as a record.
class GaiaCardView extends StatelessWidget {
  const GaiaCardView({
    super.key,
    required this.card,
    this.waiting = false,
    this.picks = const {},
    this.fields,
    this.sendKey,
    this.onPick,
    this.onAllow,
    this.onReject,
    this.onEdit,
    this.onAcceptAll,
    this.onRunAll,
    this.onRunNext,
  });

  /// A control card's approvals (§15.6), which only the desktop offers.
  final VoidCallback? onRunAll;
  final VoidCallback? onRunNext;

  final GaiaCardPart card;

  /// A tool call is waiting on it. An open question that isn't waiting is
  /// still answered, as the next message; an open permission that isn't is
  /// past answering.
  final bool waiting;

  /// The options picked so far.
  final Set<int> picks;

  /// The send keybind's label, for the hint; null leaves the hint out.
  final String? sendKey;

  /// A proposal's fields as its editor holds them; its proposed ones when
  /// null.
  final Map<String, Object?>? fields;
  final void Function(int index)? onPick;
  final VoidCallback? onAllow;
  final VoidCallback? onReject;
  final void Function(String key, Object? value)? onEdit;
  final VoidCallback? onAcceptAll;

  bool get _answerable =>
      card.isOpen && (waiting || card.kind == GaiaCardKind.question);

  @override
  Widget build(BuildContext context) {
    if (card.kind == GaiaCardKind.proposal) {
      return GaiaProposalCard(
        // Each proposal's editor keeps its own text fields.
        key: ValueKey(card.id),
        card: card,
        fields: fields ?? card.proposal!.fields,
        waiting: waiting,
        sendKey: sendKey,
        onEdit: onEdit,
        onAccept: onAllow,
        onAcceptAll: onAcceptAll,
        onReject: onReject,
      );
    }
    if (card.kind == GaiaCardKind.control && gaiaIsActivity(card)) {
      return _ActivityCard(key: ValueKey(card.id), card: card);
    }
    if (card.kind == GaiaCardKind.control) {
      return _ControlCard(
        card: card,
        waiting: waiting,
        sendKey: sendKey,
        onRunAll: onRunAll,
        onRunNext: onRunNext,
        onReject: onReject,
      );
    }
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final interactive = _answerable && (onPick != null || onAllow != null);
    final question = card.kind == GaiaCardKind.question;
    final detail = question ? null : gaiaPermissionDetail(card);
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (_answerable ? accent : theme.colorScheme.outlineVariant)
              .withValues(alpha: _answerable ? 0.7 : 0.4),
        ),
        color: accent.withValues(alpha: _answerable ? 0.08 : 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                question ? Icons.help_outline : Icons.shield_outlined,
                size: 16,
                color: kGaiaAstralGold,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  question ? card.question : 'Allow ${card.tool}?',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (!question) ...[
            if (card.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(card.description, style: theme.textTheme.bodySmall),
            ],
            if (detail != null) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  detail,
                  minLines: 1,
                  maxLines: 8,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: AppFonts.monoFamily,
                  ),
                ),
              ),
            ],
          ],
          for (final (i, option) in card.options.indexed) ...[
            const SizedBox(height: 6),
            _Option(
              index: i,
              label: option.label,
              description: option.description,
              recommended: card.recommended == i,
              picked:
                  picks.contains(i) ||
                  (card.answer?['selected'] as List?)?.contains(option.label) ==
                      true,
              onTap: interactive && onPick != null ? () => onPick!(i) : null,
            ),
          ],
          const SizedBox(height: 8),
          if (interactive)
            Row(
              children: [
                Expanded(
                  child: Text(
                    question
                        ? [
                            if (card.options.isNotEmpty)
                              card.multiSelect
                                  ? 'Pick any'
                                  : 'Pick 1–${card.options.length}',
                            'or type an answer',
                            if (sendKey != null) '$sendKey sends',
                            if (!waiting) 'it goes as your next message',
                          ].join(' · ')
                        : [
                            if (sendKey != null) '$sendKey allows',
                            'or type why not',
                          ].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                if (onReject != null)
                  GaiaButton(
                    label: question ? 'Dismiss' : 'Deny',
                    onPressed: onReject,
                    size: 28,
                    color: theme.colorScheme.error,
                  ),
                if (!question && onAllow != null) ...[
                  const SizedBox(width: 8),
                  GaiaButton(label: 'Allow', onPressed: onAllow, size: 28),
                ],
              ],
            )
          else
            Text(
              _outcome(),
              style: muted?.copyWith(
                color: card.state == GaiaCardState.accepted
                    ? null
                    : kGaiaStatusRose,
              ),
            ),
        ],
      ),
    );
  }

  String _outcome() {
    final question = card.kind == GaiaCardKind.question;
    final answer = card.answer;
    return switch (card.state) {
      GaiaCardState.open =>
        question ? 'Waiting for an answer' : 'No longer waiting',
      GaiaCardState.accepted when question => [
        'Answered',
        if ((answer?['text'] as String? ?? '').isNotEmpty)
          '"${answer!['text']}"',
      ].join(': '),
      GaiaCardState.accepted => 'Allowed',
      GaiaCardState.rejected when question => 'Dismissed',
      GaiaCardState.rejected => [
        'Denied',
        if ((answer?['message'] as String? ?? '').isNotEmpty)
          '"${answer!['message']}"',
      ].join(': '),
      GaiaCardState.voided => 'Cancelled',
      GaiaCardState.expired => 'No answer in time',
    };
  }
}

/// Whether control [card]'s remaining steps can be approved in one go: every
/// one shows its resolved target (§15.6).
bool gaiaControlCanRunAll(GaiaCardPart card) {
  final ran = (card.answer?['ran'] as num?)?.toInt() ?? 0;
  return [
    for (final step in (card.input['steps'] as List? ?? const []).skip(ran))
      (step as Map)['resolved'] == true,
  ].every((resolved) => resolved);
}

/// A step list (§15.6): the window, and every step with its target, ticked as
/// it runs.
class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.card,
    required this.waiting,
    required this.sendKey,
    required this.onRunAll,
    required this.onRunNext,
    required this.onReject,
  });

  final GaiaCardPart card;
  final bool waiting;
  final String? sendKey;
  final VoidCallback? onRunAll;
  final VoidCallback? onRunNext;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final steps = [
      for (final step in card.input['steps'] as List? ?? const [])
        (step as Map).cast<String, Object?>(),
    ];
    final ran = (card.answer?['ran'] as num?)?.toInt() ?? 0;
    final stopped = card.answer?['stopped'] as String?;
    final message = card.answer?['message'] as String?;
    final answerable = card.isOpen && waiting;
    final canRunAll = gaiaControlCanRunAll(card);
    final outcome = switch (card.state) {
      GaiaCardState.open when answerable && onRunAll == null =>
        'Waiting for approval at the desktop',
      GaiaCardState.open when answerable => [
        if (sendKey != null)
          '$sendKey runs ${canRunAll ? 'all' : 'the next step'}',
        'or type why not',
        'Esc stops a run',
      ].join(' · '),
      GaiaCardState.open => 'No longer waiting',
      GaiaCardState.accepted when stopped != null =>
        'Stopped after $ran of ${steps.length}: $stopped',
      GaiaCardState.accepted => 'Ran all ${steps.length}',
      GaiaCardState.rejected =>
        'Declined after $ran of ${steps.length}'
            '${message == null ? '' : ': "$message"'}',
      GaiaCardState.voided => 'Cancelled after $ran of ${steps.length}',
      GaiaCardState.expired => 'No answer in time',
    };
    // Ask's step preview (GAIA_AUTONOMY_HLD.md §6.4): each step still to run
    // shows its marker on the target when hovered, and once each, in order,
    // when the card opens. An Auto card runs at once, so has none.
    final previewing = answerable;
    final argb = accent.toARGB32();
    Map<String, Object?>? markerOf(int i) => previewing && i >= ran
        ? (steps[i]['flash'] as Map?)?.cast<String, Object?>()
        : null;
    return _PulseOnOpen(
      key: ValueKey(card.id),
      cardId: card.id,
      accent: argb,
      flashes: [for (var i = 0; i < steps.length; i++) ?markerOf(i)],
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (answerable ? accent : theme.colorScheme.outlineVariant)
                .withValues(alpha: answerable ? 0.7 : 0.4),
          ),
          color: accent.withValues(alpha: answerable ? 0.08 : 0.03),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.pan_tool_alt,
                  size: 16,
                  color: kGaiaAstralGold,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Control ${card.input['window'] ?? 'a window'}?',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final (i, step) in steps.indexed)
              MouseRegion(
                onEnter: markerOf(i) == null
                    ? null
                    : (_) => gaiaFlash(markerOf(i)!, argb),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 22,
                        child: i < ran
                            ? Icon(Icons.check, size: 14, color: accent)
                            : Text(
                                '${i + 1}',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                      Expanded(
                        child: SelectableText(
                          '${step['label'] ?? ''}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: AppFonts.monoFamily,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    outcome,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color:
                          card.state == GaiaCardState.accepted &&
                              stopped == null
                          ? theme.colorScheme.outline
                          : answerable
                          ? theme.colorScheme.outline
                          : kGaiaStatusRose,
                    ),
                  ),
                ),
                if (answerable && onReject != null)
                  GaiaButton(
                    label: 'Deny',
                    onPressed: onReject,
                    size: 28,
                    color: theme.colorScheme.error,
                  ),
                if (answerable &&
                    onRunNext != null &&
                    steps.length - ran > 1) ...[
                  const SizedBox(width: 8),
                  GaiaButton(
                    label: 'Next step',
                    onPressed: onRunNext,
                    size: 28,
                  ),
                ],
                if (answerable && onRunAll != null && canRunAll) ...[
                  const SizedBox(width: 8),
                  GaiaButton(
                    label: steps.length - ran > 1 ? 'Run all' : 'Run',
                    onPressed: onRunAll,
                    size: 28,
                  ),
                ] else if (answerable &&
                    onRunNext != null &&
                    steps.length - ran == 1) ...[
                  const SizedBox(width: 8),
                  GaiaButton(label: 'Run', onPressed: onRunNext, size: 28),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether control [card] is an Auto turn's activity row
/// (GAIA_AUTONOMY_HLD.md §7) rather than a step list.
bool gaiaIsActivity(GaiaCardPart card) => card.input['activity'] == true;

/// What an Auto turn ran with no cards (§7): "12 actions in Gmail", opening to
/// each one, newest last.
class _ActivityCard extends StatefulWidget {
  const _ActivityCard({super.key, required this.card});

  final GaiaCardPart card;

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = widget.card;
    final steps = [
      for (final step in card.input['steps'] as List? ?? const [])
        '${(step as Map)['label'] ?? ''}',
    ];
    final total = (card.input['total'] as num?)?.toInt() ?? steps.length;
    final app = card.input['app'] as String?;
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
        color: theme.colorScheme.primary.withValues(alpha: 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  const Icon(Icons.bolt, size: 16, color: kGaiaAstralGold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$total ${total == 1 ? 'action' : 'actions'}'
                      '${app == null ? '' : ' in $app'}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (total > steps.length)
                    Text(
                      'The first ${total - steps.length} are not kept.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  for (final label in steps)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: SelectableText(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: AppFonts.monoFamily,
                          color: label.startsWith('Stopped: ')
                              ? kGaiaStatusRose
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Plays [flashes], one after another, the first time card [cardId] builds: an
/// open control card pulsing its steps' markers (GAIA_AUTONOMY_HLD.md §6.4).
/// Scrolled back into view, or its chat opened again, it doesn't replay.
class _PulseOnOpen extends StatefulWidget {
  const _PulseOnOpen({
    super.key,
    required this.cardId,
    required this.flashes,
    required this.accent,
    required this.child,
  });

  final String cardId;
  final List<Map<String, Object?>> flashes;
  final int accent;
  final Widget child;

  @override
  State<_PulseOnOpen> createState() => _PulseOnOpenState();
}

class _PulseOnOpenState extends State<_PulseOnOpen> {
  static final _pulsed = <String>{};
  final _timers = <Timer>[];

  @override
  void initState() {
    super.initState();
    if (widget.flashes.isEmpty || !_pulsed.add(widget.cardId)) return;
    for (final (i, flash) in widget.flashes.indexed) {
      _timers.add(
        Timer(
          Duration(milliseconds: 300 * i),
          () => gaiaFlash(flash, widget.accent),
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The part of a permission's call worth reading at a glance: a command,
/// a file's path, a URL; the whole input otherwise. Null for none.
String? gaiaPermissionDetail(GaiaCardPart card) {
  final input = card.input;
  if (input.isEmpty) return null;
  for (final key in ['command', 'file_path', 'notebook_path', 'url', 'path']) {
    if (input[key] case final String value when value.isNotEmpty) {
      return value;
    }
  }
  return const JsonEncoder.withIndent('  ').convert(input);
}

class _Option extends StatelessWidget {
  const _Option({
    required this.index,
    required this.label,
    required this.description,
    required this.recommended,
    required this.picked,
    required this.onTap,
  });

  final int index;
  final String label;
  final String description;
  final bool recommended;
  final bool picked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: picked ? accent.withValues(alpha: 0.22) : null,
          border: Border.all(
            color: picked
                ? accent
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 18,
              child: Text(
                '${index + 1}',
                style: theme.textTheme.labelMedium?.copyWith(color: accent),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      text: label,
                      children: [
                        if (recommended)
                          TextSpan(
                            text: '  Recommended',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: kGaiaAstralGold,
                            ),
                          ),
                      ],
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (description.isNotEmpty) Text(description, style: muted),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
