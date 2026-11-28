import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_routines.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_routines_tab.dart';

/// A routine run's side panel (GAIA_ROUTINES_HLD.md §11.1): the Gaia window
/// docked to the screen's right edge, on top, out of capture. The run, what
/// it's on, what's next, and its parked items with a note and Retry.
class GaiaRoutinePanel extends StatelessWidget {
  const GaiaRoutinePanel({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final runner = controller.routineRunner;
    final launched = controller.routineLaunch?.runId;
    final run =
        runner.run ??
        controller.routineRuns.firstWhereOrNull((r) => r.id == launched);
    final routine =
        runner.routine ??
        controller.routines.firstWhereOrNull((r) => r.id == run?.routineId);
    final waiting = runner.waitingOnYou;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The header takes the screen edge's colour while a handoff waits.
        AnimatedContainer(
          duration: GaiaMotion.move,
          color: waiting == null
              ? GaiaInk.hover
              : const Color(
                  0xFF000000 | kGaiaHandoffColor,
                ).withValues(alpha: 0.28),
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Row(
            children: [
              Icon(Icons.repeat, size: 16, color: GaiaInk.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  [
                    routine?.name ?? 'Routine',
                    if (run != null) _modeName(run.mode),
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: GaiaType.row.copyWith(color: GaiaInk.bright),
                ),
              ),
              GaiaButton(
                tooltip: 'Close the panel',
                icon: Icons.close,
                size: 24,
                iconSize: 16,
                onPressed: controller.closeRoutinePanel,
              ),
            ],
          ),
        ),
        Expanded(
          child: run == null
              ? Center(
                  child: Text(
                    'No run.',
                    style: GaiaType.label.copyWith(color: GaiaInk.faint),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  children: _body(run, routine, waiting),
                ),
        ),
      ],
    );
  }

  List<Widget> _body(
    GaiaRoutineRun run,
    GaiaRoutine? routine,
    String? waiting,
  ) {
    final runner = controller.routineRunner;
    final live = runner.run?.id == run.id;
    final done = run.items.where((item) => !_open(item.status)).length;
    final total = run.items.length;
    final cap = run.tokenCap ?? routine?.tokenCap;
    final elapsed = (run.endedAt ?? DateTime.now().toUtc()).difference(
      run.startedAt,
    );
    final now = run.items.firstWhereOrNull(
      (item) => item.status == GaiaRunItemStatus.running,
    );
    final posting = runner.gate?.posting;
    final next = run.items
        .where((item) => item.status == GaiaRunItemStatus.waiting)
        .take(3);
    final parked = run.items.where(gaiaItemParked);
    TextStyle style(Color color) => GaiaType.label.copyWith(color: color);
    return [
      Text(
        '$done of $total · ${gaiaRunStateLabel(run)} · '
        '${elapsed.inMinutes} min',
        style: style(GaiaInk.dim),
      ),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: total == 0 ? 0 : done / total,
          minHeight: 3,
          backgroundColor: GaiaInk.hairline,
          color: GaiaInk.muted,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        '${gaiaCompactTokens(run.usage.counted)}'
        '${cap == null ? '' : ' of ${gaiaCompactTokens(cap)}'} tokens',
        style: style(GaiaInk.faint),
      ),
      Text(gaiaRunCounts(run), style: style(GaiaInk.faint)),
      if (waiting != null) ...[
        const SizedBox(height: 12),
        _Handoff(controller: controller, reason: waiting),
      ],
      if (now != null) ...[
        const SizedBox(height: 12),
        Text('Now', style: style(GaiaInk.muted)),
        const SizedBox(height: 2),
        Text(now.label, style: style(GaiaInk.dim)),
        if (posting != null)
          Text(
            [
              '${posting['location'] ?? ''}',
              'fit: ${posting['fit']}',
            ].where((part) => part.trim().isNotEmpty).join(' · '),
            style: style(GaiaInk.faint),
          ),
      ],
      if (next.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Next', style: style(GaiaInk.muted)),
        const SizedBox(height: 2),
        for (final item in next)
          Text(
            item.label,
            overflow: TextOverflow.ellipsis,
            style: style(GaiaInk.faint),
          ),
      ],
      if (parked.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Parked', style: style(GaiaInk.muted)),
        for (final item in parked)
          GaiaParkedItem(
            key: ValueKey('${item.url} ${item.chatId}'),
            controller: controller,
            run: run,
            item: item,
          ),
      ],
      if (live) ...[
        const SizedBox(height: 14),
        GaiaRunControls(controller: controller, run: run),
      ],
    ];
  }

  static bool _open(GaiaRunItemStatus status) =>
      status == GaiaRunItemStatus.waiting ||
      status == GaiaRunItemStatus.running;

  static String _modeName(GaiaRunMode mode) => switch (mode) {
    GaiaRunMode.unattended => 'Unattended',
    GaiaRunMode.attended => 'Attended',
  };
}

/// An attended run waiting on the user (§9.3): why, and Resume with notes
/// for Gaia. An item's `ask_user` is answered in its chat instead.
class _Handoff extends StatefulWidget {
  const _Handoff({required this.controller, required this.reason});

  final GaiaController controller;
  final String reason;

  @override
  State<_Handoff> createState() => _HandoffState();
}

class _HandoffState extends State<_Handoff> {
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runner = widget.controller.routineRunner;
    final asking = runner.handoff == null ? runner.itemChat : null;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GaiaRadius.row),
        border: Border.all(color: const Color(0xFF000000 | kGaiaHandoffColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your turn',
            style: GaiaType.row.copyWith(color: GaiaInk.bright),
          ),
          const SizedBox(height: 4),
          Text(
            widget.reason.isEmpty ? 'Gaia needs you.' : widget.reason,
            style: GaiaType.label.copyWith(color: GaiaInk.dim),
          ),
          const SizedBox(height: 8),
          if (asking != null)
            Align(
              alignment: Alignment.centerRight,
              child: GaiaButton(
                label: 'Answer in chat',
                icon: Icons.chat_bubble_outline,
                size: 30,
                padding: 12,
                onPressed: () => widget.controller.openRoutineItemChat(asking),
              ),
            )
          else ...[
            GaiaPanelField(
              controller: _notes,
              hintText: 'Notes for Gaia (optional)',
              minLines: 1,
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: GaiaButton(
                label: 'Resume',
                icon: Icons.play_arrow,
                size: 30,
                padding: 12,
                onPressed: () =>
                    widget.controller.resumeRoutine(notes: _notes.text),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A parked item (§10.2): its reason, a note that also goes to the answer
/// bank when ticked, and Retry. Saving a note queues it too.
class GaiaParkedItem extends StatefulWidget {
  const GaiaParkedItem({
    super.key,
    required this.controller,
    required this.run,
    required this.item,
  });

  final GaiaController controller;
  final GaiaRoutineRun run;
  final GaiaRunItem item;

  @override
  State<GaiaParkedItem> createState() => _GaiaParkedItemState();
}

class _GaiaParkedItemState extends State<GaiaParkedItem> {
  final _note = TextEditingController();
  var _toBank = true;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _retry({required bool withNote}) async {
    setState(() => _busy = true);
    final controller = widget.controller;
    final error = withNote
        ? await controller.noteRoutineItem(
            widget.run,
            widget.item,
            _note.text,
            toBank: _toBank,
          )
        : await controller.retryRoutineItem(widget.run, widget.item);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final chatId = item.chatId;
    final hasNote = _note.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: chatId == null
                ? null
                : () => widget.controller.openRoutineItemChat(chatId),
            child: Text(
              '${_statusName(item.status)}: ${item.label}',
              overflow: TextOverflow.ellipsis,
              style: GaiaType.label.copyWith(color: GaiaInk.dim),
            ),
          ),
          if ((item.reason ?? '').isNotEmpty)
            Text(
              item.reason!,
              style: GaiaType.label.copyWith(color: GaiaInk.faint),
            ),
          const SizedBox(height: 4),
          GaiaPanelField(
            controller: _note,
            hintText: 'Note: answer what it asked',
            minLines: 1,
            maxLines: 4,
          ),
          Row(
            children: [
              Checkbox(
                value: _toBank,
                visualDensity: VisualDensity.compact,
                onChanged: (on) => setState(() => _toBank = on ?? false),
              ),
              Expanded(
                child: Text(
                  'Save to answer bank',
                  style: GaiaType.label.copyWith(color: GaiaInk.faint),
                ),
              ),
              GaiaButton(
                label: hasNote ? 'Save' : 'Retry',
                icon: Icons.replay,
                size: 28,
                padding: 10,
                onPressed: _busy ? null : () => _retry(withNote: hasNote),
              ),
            ],
          ),
          if (_error case final error?)
            Text(error, style: GaiaType.label.copyWith(color: kGaiaStatusRose)),
        ],
      ),
    );
  }

  static String _statusName(GaiaRunItemStatus status) => switch (status) {
    GaiaRunItemStatus.ready => 'Ready',
    GaiaRunItemStatus.failed => 'Failed',
    _ => 'Needs you',
  };
}

/// A live run's Pause, Resume and End (§8.7), on its card and the panel.
class GaiaRunControls extends StatelessWidget {
  const GaiaRunControls({
    super.key,
    required this.controller,
    required this.run,
  });

  final GaiaController controller;
  final GaiaRoutineRun run;

  @override
  Widget build(BuildContext context) {
    final runner = controller.routineRunner;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: [
        if (run.state == GaiaRunState.running)
          GaiaButton(
            label: 'Pause',
            icon: Icons.pause,
            size: 30,
            padding: 12,
            onPressed: runner.pause,
          ),
        if (run.state == GaiaRunState.paused && run.stopReason == 'token cap')
          GaiaButton(
            label: 'Raise cap and resume',
            icon: Icons.play_arrow,
            size: 30,
            padding: 12,
            onPressed: () => runner.resume(
              tokenCap: run.usage.counted + (runner.routine?.tokenCap ?? 0),
            ),
          )
        else if (run.state == GaiaRunState.paused)
          GaiaButton(
            label: 'Resume run',
            icon: Icons.play_arrow,
            size: 30,
            padding: 12,
            onPressed: runner.resume,
          ),
        GaiaButton(
          label: 'End run',
          icon: Icons.stop,
          size: 30,
          padding: 12,
          onPressed: runner.end,
        ),
      ],
    );
  }
}
