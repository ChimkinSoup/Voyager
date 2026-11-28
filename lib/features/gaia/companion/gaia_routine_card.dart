import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_routine_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_routines.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/settings/gaia_routines_tab.dart';

/// The card `/routine` posts above the composer (GAIA_ROUTINES_HLD.md §7.1):
/// links pasted in or open tabs imported, the mode and the Google account,
/// then Ctrl+Enter. Once the run starts it shows the run: its counts, usage,
/// the item under way, its parked items with a note and Retry, and Pause,
/// Resume or End.
class GaiaRoutineCard extends StatefulWidget {
  const GaiaRoutineCard({super.key, required this.controller});

  final GaiaController controller;

  @override
  State<GaiaRoutineCard> createState() => _GaiaRoutineCardState();
}

class _GaiaRoutineCardState extends State<GaiaRoutineCard> {
  final _links = TextEditingController();
  late final _google = TextEditingController(
    text: widget.controller.routineLaunch?.routine.googleAccount,
  );
  var _mode = GaiaRunMode.unattended;

  /// Duplicates ticked to run anyway, by place in the list.
  final _kept = <int>{};

  /// The browser's open tabs once imported (§7.2), each ticked to run.
  List<({String title, String url, bool ticked})>? _tabs;
  var _importing = false;
  String? _error;
  var _starting = false;

  @override
  void initState() {
    super.initState();
    _links.addListener(() => setState(() => _kept.clear()));
  }

  @override
  void dispose() {
    _links.dispose();
    _google.dispose();
    super.dispose();
  }

  /// The pasted links and the ticked tabs, in that order, each once.
  List<String> get _urls => gaiaRoutineUrls(
    [
      _links.text,
      for (final tab in _tabs ?? const [])
        if (tab.ticked) tab.url,
    ].join('\n'),
  );

  Future<void> _importTabs() async {
    setState(() => _importing = true);
    final tabs = await widget.controller.browserTabs();
    if (!mounted) return;
    setState(() {
      _importing = false;
      _kept.clear();
      _tabs = [
        for (final tab in tabs) (title: tab.title, url: tab.url, ticked: true),
      ];
    });
  }

  Future<void> _start() async {
    final urls = _urls;
    final duplicates = gaiaDuplicateUrls(urls, widget.controller.routineRuns);
    setState(() => _starting = true);
    final error = await widget.controller.startRoutine(
      [
        for (final (i, url) in urls.indexed)
          if (!duplicates.contains(i) || _kept.contains(i)) url,
      ],
      mode: _mode,
      googleAccount: _google.text,
    );
    if (mounted) {
      setState(() {
        _starting = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final launch = controller.routineLaunch!;
    final runner = controller.routineRunner;
    final run = launch.runId == null
        ? null
        : runner.run?.id == launch.runId
        ? runner.run
        : controller.routineRuns.firstWhereOrNull((r) => r.id == launch.runId);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      decoration: BoxDecoration(
        color: GaiaInk.hover,
        borderRadius: BorderRadius.circular(GaiaRadius.panel),
        border: Border.all(color: GaiaInk.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.repeat, size: 16, color: GaiaInk.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Routine: ${launch.routine.name}'
                  '${run == null ? '' : ' · ${gaiaRunStateLabel(run)}'}',
                  overflow: TextOverflow.ellipsis,
                  style: GaiaType.row.copyWith(color: GaiaInk.bright),
                ),
              ),
              if (run == null || run.state != GaiaRunState.running)
                GaiaButton(
                  tooltip: 'Close',
                  icon: Icons.close,
                  size: 24,
                  iconSize: 16,
                  onPressed: controller.closeRoutineLaunch,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (run == null) ..._launch(launch.routine) else ..._status(run),
        ],
      ),
    );
  }

  List<Widget> _launch(GaiaRoutine routine) {
    final urls = _urls;
    final duplicates = gaiaDuplicateUrls(urls, widget.controller.routineRuns);
    final count = urls.length - duplicates.length + _kept.length;
    return [
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
            if (!_starting) _start();
          },
        },
        child: GaiaPanelField(
          controller: _links,
          hintText: 'Paste links, one per line or mixed with text',
          minLines: 3,
          maxLines: 8,
        ),
      ),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: GaiaButton(
          label: _importing ? 'Reading tabs…' : 'Import open tabs',
          icon: Icons.tab,
          size: 28,
          padding: 10,
          tooltip:
              'Selects each tab in turn to read its address, then puts '
              'back the one you were on',
          onPressed: _importing ? null : _importTabs,
        ),
      ),
      if (_tabs case final tabs? when tabs.isEmpty)
        Text(
          'No open tabs found.',
          style: GaiaType.label.copyWith(color: GaiaInk.faint),
        ),
      for (final (i, tab) in (_tabs ?? const []).indexed)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: tab.ticked,
          onChanged: (on) => setState(() {
            _kept.clear();
            _tabs![i] = (title: tab.title, url: tab.url, ticked: on ?? false);
          }),
          title: Text(
            tab.title.isEmpty ? tab.url : tab.title,
            overflow: TextOverflow.ellipsis,
            style: GaiaType.label.copyWith(color: GaiaInk.muted),
          ),
        ),
      for (final i in duplicates)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _kept.contains(i),
          onChanged: (on) => setState(() {
            on == true ? _kept.add(i) : _kept.remove(i);
          }),
          title: Text(
            'Duplicate: ${urls[i]}',
            overflow: TextOverflow.ellipsis,
            style: GaiaType.label.copyWith(color: GaiaInk.muted),
          ),
        ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          GaiaPanelChoice(
            label: 'Unattended',
            selected: _mode == GaiaRunMode.unattended,
            onTap: () => setState(() => _mode = GaiaRunMode.unattended),
          ),
          GaiaPanelChoice(
            label: 'Attended',
            selected: _mode == GaiaRunMode.attended,
            onTap: () => setState(() => _mode = GaiaRunMode.attended),
          ),
        ],
      ),
      const SizedBox(height: 8),
      GaiaPanelField(
        controller: _google,
        hintText: 'Google account for "Sign in with Google" (optional)',
      ),
      if (_error case final error?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            error,
            style: GaiaType.label.copyWith(color: kGaiaStatusRose),
          ),
        ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text(
              count == 0
                  ? 'No links yet.'
                  : '$count ${count == 1 ? 'item' : 'items'}, at most '
                        '${count * routine.budgetMinutes} minutes',
              style: GaiaType.label.copyWith(color: GaiaInk.faint),
            ),
          ),
          GaiaButton(
            label: 'Start',
            icon: Icons.play_arrow,
            size: 30,
            padding: 12,
            tooltip: 'Ctrl+Enter',
            onPressed: count == 0 || _starting ? null : _start,
          ),
        ],
      ),
    ];
  }

  List<Widget> _status(GaiaRoutineRun run) {
    final controller = widget.controller;
    final runner = controller.routineRunner;
    final live = runner.run?.id == run.id;
    final done = run.items
        .where(
          (item) =>
              item.status != GaiaRunItemStatus.waiting &&
              item.status != GaiaRunItemStatus.running,
        )
        .length;
    final cap = run.tokenCap ?? runner.routine?.tokenCap;
    final now = run.items.firstWhereOrNull(
      (item) => item.status == GaiaRunItemStatus.running,
    );
    final posting = runner.gate?.posting;
    return [
      Text(
        '$done of ${run.items.length} · ${gaiaRunCounts(run)}',
        style: GaiaType.label.copyWith(color: GaiaInk.dim),
      ),
      const SizedBox(height: 2),
      Text(
        '${gaiaCompactTokens(run.usage.counted)}'
        '${cap == null ? '' : ' of ${gaiaCompactTokens(cap)}'} tokens',
        style: GaiaType.label.copyWith(color: GaiaInk.faint),
      ),
      if (now != null) ...[
        const SizedBox(height: 6),
        Text(
          [
            'Now: ${now.label}',
            if (posting != null) ...[
              '${posting['location'] ?? ''}',
              'fit: ${posting['fit']}',
            ],
          ].where((part) => part.trim().isNotEmpty).join(' · '),
          overflow: TextOverflow.ellipsis,
          style: GaiaType.label.copyWith(color: GaiaInk.muted),
        ),
      ],
      const SizedBox(height: 6),
      for (final item in run.items)
        if (gaiaItemParked(item))
          GaiaParkedItem(
            key: ValueKey('${item.url} ${item.chatId}'),
            controller: controller,
            run: run,
            item: item,
          )
        else if (item.status != GaiaRunItemStatus.waiting &&
            item.status != GaiaRunItemStatus.running)
          InkWell(
            onTap: item.chatId == null
                ? null
                : () => controller.selectChat(item.chatId!),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${_statusName(item.status)}: ${item.label}'
                '${(item.reason ?? '').isEmpty ? '' : ' — ${item.reason}'}',
                overflow: TextOverflow.ellipsis,
                style: GaiaType.label.copyWith(color: GaiaInk.faint),
              ),
            ),
          ),
      if (live) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            GaiaButton(
              label: 'Panel',
              icon: Icons.view_sidebar_outlined,
              size: 30,
              padding: 12,
              tooltip: 'The side panel',
              onPressed: controller.openRoutinePanel,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GaiaRunControls(controller: controller, run: run),
            ),
          ],
        ),
      ],
    ];
  }

  static String _statusName(GaiaRunItemStatus status) => switch (status) {
    GaiaRunItemStatus.waiting => 'Waiting',
    GaiaRunItemStatus.running => 'Running',
    GaiaRunItemStatus.submitted => 'Submitted',
    GaiaRunItemStatus.ready => 'Ready',
    GaiaRunItemStatus.needsYou => 'Needs you',
    GaiaRunItemStatus.skipped => 'Skipped',
    GaiaRunItemStatus.failed => 'Failed',
  };
}
