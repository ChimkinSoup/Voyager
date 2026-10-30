import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_date_picker.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

/// A proposal card (GAIA_HLD.md §10): what a `propose_*` tool would write.
/// Open and waiting, it's an editor over [fields], changed through
/// [onEdit], with [onAccept] saving what it holds, [onAcceptAll] saving
/// every open proposal in the reply, and [onReject] turning it down.
/// Otherwise it's a record of what was proposed and what came of it.
class GaiaProposalCard extends StatefulWidget {
  const GaiaProposalCard({
    super.key,
    required this.card,
    required this.fields,
    this.waiting = false,
    this.sendKey,
    this.onEdit,
    this.onAccept,
    this.onAcceptAll,
    this.onReject,
  });

  final GaiaCardPart card;
  final Map<String, Object?> fields;
  final bool waiting;
  final String? sendKey;
  final void Function(String key, Object? value)? onEdit;
  final VoidCallback? onAccept;

  /// Null unless several proposals are open.
  final VoidCallback? onAcceptAll;
  final VoidCallback? onReject;

  @override
  State<GaiaProposalCard> createState() => _GaiaProposalCardState();
}

class _GaiaProposalCardState extends State<GaiaProposalCard> {
  final _text = <String, TextEditingController>{};

  GaiaProposal get _proposal => widget.card.proposal!;

  bool get _editing =>
      widget.card.isOpen && widget.waiting && widget.onEdit != null;

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String key) =>
      _text[key] ??= TextEditingController(
        text: widget.fields[key] as String? ?? '',
      )..addListener(() => widget.onEdit?.call(key, _text[key]!.text));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final fields = widget.card.state == GaiaCardState.accepted
        ? ((widget.card.answer?['fields'] as Map?)?.cast<String, Object?>() ??
              widget.fields)
        : widget.fields;
    final problem = _editing ? gaiaProposalProblem(_proposal, fields) : null;
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (_editing ? accent : theme.colorScheme.outlineVariant)
              .withValues(alpha: _editing ? 0.7 : 0.4),
        ),
        color: accent.withValues(alpha: _editing ? 0.08 : 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.edit_note, size: 18, color: kGaiaAstralGold),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  gaiaProposalTitle(_proposal, fields),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_editing) ...[
            for (final key in gaiaProposalFieldKeys(_proposal.entity))
              if (_shown(key)) _field(context, key, fields),
          ] else
            for (final key in gaiaProposalChanged(_proposal, fields))
              _summary(context, key, fields),
          const SizedBox(height: 8),
          if (_editing) ...[
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  problem,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            // The hint goes above the buttons, whole, when it can't sit
            // beside them on one line: with Save all too, it can't.
            OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.end,
              overflowSpacing: 6,
              spacing: 8,
              children: [
                Text(
                  [
                    if (widget.sendKey != null) '${widget.sendKey} saves',
                    'or type what to change',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onReject != null)
                      GaiaButton(
                        label: 'Turn down',
                        onPressed: widget.onReject,
                        size: 28,
                        color: theme.colorScheme.error,
                      ),
                    if (widget.onAcceptAll != null) ...[
                      const SizedBox(width: 8),
                      GaiaButton(
                        label: 'Save all',
                        onPressed: widget.onAcceptAll,
                        size: 28,
                      ),
                    ],
                    const SizedBox(width: 8),
                    GaiaButton(
                      label: 'Save',
                      onPressed: problem == null ? widget.onAccept : null,
                      size: 28,
                    ),
                  ],
                ),
              ],
            ),
          ] else
            Text(
              _outcome(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: widget.card.state == GaiaCardState.accepted
                    ? theme.colorScheme.onSurfaceVariant
                    : kGaiaStatusRose,
              ),
            ),
        ],
      ),
    );
  }

  /// A task's done switch shows only on an edit: a new task is open.
  bool _shown(String key) => key != 'completed' || _proposal.isEdit;

  String _outcome() {
    final answer = widget.card.answer;
    return switch (widget.card.state) {
      GaiaCardState.open => 'No longer waiting',
      GaiaCardState.accepted when answer?['undoneAt'] != null =>
        'Saved, then undone',
      GaiaCardState.accepted => 'Saved',
      GaiaCardState.rejected => [
        'Turned down',
        if ((answer?['message'] as String? ?? '').isNotEmpty)
          '"${answer!['message']}"',
      ].join(': '),
      GaiaCardState.voided when answer?['error'] != null =>
        'Not saved: ${answer!['error']}',
      GaiaCardState.voided => 'Cancelled',
      GaiaCardState.expired => 'No answer in time; nothing saved',
    };
  }

  Widget _summary(
    BuildContext context,
    String key,
    Map<String, Object?> fields,
  ) {
    final theme = Theme.of(context);
    final before = _proposal.before;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${gaiaProposalFieldLabel(key)}: ',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (before != null) ...[
              TextSpan(
                text: _clip(gaiaProposalValueLabel(_proposal, before, key)),
                style: const TextStyle(decoration: TextDecoration.lineThrough),
              ),
              const TextSpan(text: ' → '),
            ],
            TextSpan(
              text: _clip(gaiaProposalValueLabel(_proposal, fields, key)),
            ),
          ],
        ),
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  static String _clip(String text) =>
      text.length > 200 ? '${text.substring(0, 200)}…' : text;

  Widget _field(BuildContext context, String key, Map<String, Object?> fields) {
    final theme = Theme.of(context);
    final before = _proposal.before;
    final changed =
        before != null && gaiaProposalChanged(_proposal, fields).contains(key);
    final label = gaiaProposalFieldLabel(key);
    final Widget input = switch (key) {
      'title' => _textInput(key, label: label),
      'notes' || 'body' => _textInput(key, label: label, lines: 6),
      'list' || 'calendar' || 'journal' => _choice(key, label, fields),
      'due' || 'start' || 'end' || 'date' => _when(context, key, label, fields),
      'starred' || 'completed' || 'allDay' => _toggle(key, label, fields),
      'mood' => _mood(label, fields),
      _ => const SizedBox.shrink(),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          input,
          if (changed)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                'Was: ${_clip(gaiaProposalValueLabel(_proposal, before, key))}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _textInput(String key, {required String label, int lines = 1}) =>
      TextField(
        controller: _controller(key),
        minLines: 1,
        maxLines: lines,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      );

  Widget _choice(String key, String label, Map<String, Object?> fields) =>
      DropdownButtonFormField<String>(
        initialValue: _proposal.choices.any((c) => c.id == fields[key])
            ? fields[key]! as String
            : null,
        isDense: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final choice in _proposal.choices)
            DropdownMenuItem(value: choice.id, child: Text(choice.name)),
        ],
        onChanged: (id) => widget.onEdit?.call(key, id),
      );

  Widget _toggle(String key, String label, Map<String, Object?> fields) {
    final on = fields[key] == true;
    return Row(
      children: [
        Expanded(child: Text(label)),
        Switch(
          value: on,
          onChanged: (value) {
            widget.onEdit?.call(key, value);
            // An all-day event's ends are days; a timed one's, times.
            if (key == 'allDay') _retime(fields, allDay: value);
          },
        ),
      ],
    );
  }

  /// Switching an event between all day and timed: its ends become days,
  /// or start at noon for an hour, as Voyager's own event panel does.
  void _retime(Map<String, Object?> fields, {required bool allDay}) {
    final start = gaiaParseWhen(fields['start']);
    final end = gaiaParseWhen(fields['end']);
    if (start == null || end == null) return;
    if (allDay) {
      widget.onEdit?.call('start', gaiaFormatWhen(start.at, hasTime: false));
      widget.onEdit?.call('end', gaiaFormatWhen(end.at, hasTime: false));
    } else {
      final noon = DateUtils.dateOnly(start.at).add(const Duration(hours: 12));
      widget.onEdit?.call('start', gaiaFormatWhen(noon, hasTime: true));
      widget.onEdit?.call(
        'end',
        gaiaFormatWhen(noon.add(const Duration(hours: 1)), hasTime: true),
      );
    }
  }

  Widget _mood(String label, Map<String, Object?> fields) {
    final mood = (fields['mood'] as int?) ?? 5;
    return Row(
      children: [
        SizedBox(width: 60, child: Text(label)),
        Expanded(
          child: Slider(
            value: mood.toDouble(),
            max: 10,
            divisions: 10,
            label: '$mood',
            onChanged: (value) => widget.onEdit?.call('mood', value.round()),
          ),
        ),
        SizedBox(width: 36, child: Text('$mood/10')),
      ],
    );
  }

  /// A day, or a time on one. A task's due date may have no time, or none
  /// at all; an event's ends follow its all-day switch; an entry's is
  /// always a time.
  Widget _when(
    BuildContext context,
    String key,
    String label,
    Map<String, Object?> fields,
  ) {
    final when = gaiaParseWhen(fields[key]);
    final timed = switch (key) {
      'start' || 'end' => fields['allDay'] != true,
      'date' => true,
      _ => when?.hasTime ?? false,
    };
    Future<void> pick() async {
      // A due date's time is optional in the picker, as in Voyager's.
      final due = key == 'due';
      final picked = await showGaiaDatePicker(
        context,
        initial:
            when?.at ??
            DateUtils.dateOnly(DateTime.now()).add(const Duration(hours: 9)),
        timed: timed || due,
        optionalTime: due,
        initialHasTime: timed,
      );
      // Not once the card has gone, or been answered meanwhile.
      if (picked == null || !mounted || !_editing) return;
      widget.onEdit?.call(
        key,
        gaiaFormatWhen(picked.dateTime, hasTime: picked.hasTime),
      );
    }

    return Row(
      children: [
        SizedBox(width: 60, child: Text(label)),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: GaiaButton(
              label: gaiaWhenLabel(fields[key]),
              onPressed: pick,
              size: 28,
            ),
          ),
        ),
        if (key == 'due') ...[
          if (when != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: when.hasTime ? 'Day only' : 'Add a time',
              child: GaiaButton(
                icon: when.hasTime ? Icons.timer_off : Icons.schedule,
                size: 28,
                onPressed: () => widget.onEdit?.call(
                  key,
                  gaiaFormatWhen(
                    when.hasTime
                        ? DateUtils.dateOnly(when.at)
                        : DateUtils.dateOnly(
                            when.at,
                          ).add(const Duration(hours: 9)),
                    hasTime: !when.hasTime,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: 'No due date',
              child: GaiaButton(
                icon: Icons.close,
                size: 28,
                onPressed: () => widget.onEdit?.call(key, null),
              ),
            ),
          ],
        ],
      ],
    );
  }
}
