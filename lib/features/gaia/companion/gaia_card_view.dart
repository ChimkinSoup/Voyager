import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_proposal_card.dart';

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
  });

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
                    fontFamily: 'Consolas',
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
