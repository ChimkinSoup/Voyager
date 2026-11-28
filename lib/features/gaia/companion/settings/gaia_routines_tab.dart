import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_routines.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';

/// The settings panel's Routines tab (GAIA_ROUTINES_HLD.md §6): what
/// routines have spent, the routines, which a click edits, and past runs.
class GaiaRoutinesTab extends StatefulWidget {
  const GaiaRoutinesTab({super.key, required this.controller});

  final GaiaController controller;

  @override
  State<GaiaRoutinesTab> createState() => _GaiaRoutinesTabState();
}

class _GaiaRoutinesTabState extends State<GaiaRoutinesTab> {
  /// The routine open in its editor, by id; '' for a new one, null for none.
  String? _editing;

  Future<void> _save(GaiaRoutine routine) async {
    try {
      await widget.controller.saveRoutine(routine);
      if (mounted) setState(() => _editing = null);
    } on GaiaPipeException catch (error) {
      if (mounted) {
        showGaiaToast(
          context,
          mark: GaiaToastMark.error,
          title: "Couldn't save the routine",
          body: error.message,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final routines = controller.routines;
    final runs = controller.routineRuns.reversed.toList();
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    return GaiaPanelScroll(
      key: const PageStorageKey('gaia panel routines'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GaiaPanelSection(
                heading: 'Usage',
                children: [
                  GaiaPanelNote(
                    'This week: ${_tokens(runs.where((r) => r.startedAt.isAfter(weekAgo)))}. '
                    'In all: ${_tokens(runs)}, over ${runs.length} '
                    "${runs.length == 1 ? 'run' : 'runs'}.",
                  ),
                ],
              ),
              GaiaPanelSection(
                heading: 'Routines',
                trailing: _editing == ''
                    ? null
                    : GaiaButton(
                        label: 'Add routine',
                        icon: Icons.add,
                        size: 28,
                        padding: 10,
                        onPressed: () => setState(() => _editing = ''),
                      ),
                children: [
                  if (routines.isEmpty && _editing != '')
                    const GaiaPanelNote(
                      'A routine runs the same instructions over a list of '
                      'links, one fresh chat each, such as applying to jobs. '
                      'Start one with /routine and its name.',
                    ),
                  for (final routine in routines)
                    if (_editing == routine.id)
                      _RoutineEditor(
                        key: ValueKey('edit ${routine.id}'),
                        controller: controller,
                        routine: routine,
                        onCancel: () => setState(() => _editing = null),
                        onSave: _save,
                      )
                    else
                      _Row(
                        key: ValueKey('routine ${routine.id}'),
                        title: routine.name,
                        detail: [
                          controller.project(routine.projectId)?.name ??
                              'no project',
                          _tokens(runs.where((r) => r.routineId == routine.id)),
                          if (runs.firstWhereOrNull(
                                (r) => r.routineId == routine.id,
                              )
                              case final last?)
                            'last run ${_date(last.startedAt)}',
                        ].join(' · '),
                        onTap: () => setState(() => _editing = routine.id),
                        trailing: GaiaButton(
                          tooltip: 'Delete',
                          icon: Icons.delete_outline,
                          size: 24,
                          iconSize: 16,
                          onPressed: () =>
                              _save(routine.copyWith(deletedAt: utcNow())),
                        ),
                      ),
                  if (_editing == '')
                    _RoutineEditor(
                      key: const ValueKey('new routine'),
                      controller: controller,
                      routine: null,
                      onCancel: () => setState(() => _editing = null),
                      onSave: _save,
                    ),
                ],
              ),
              if (runs.isNotEmpty)
                GaiaPanelSection(
                  heading: 'Runs',
                  children: [
                    for (final run in runs)
                      _Row(
                        key: ValueKey('run ${run.id}'),
                        title:
                            '${routines.firstWhereOrNull((r) => r.id == run.routineId)?.name ?? 'A routine'}'
                            ' · ${_date(run.startedAt)} · ${gaiaRunStateLabel(run)}',
                        detail: [
                          gaiaRunCounts(run),
                          _tokens([run]),
                          for (final MapEntry(key: account, value: start)
                              in run.usage.planStart.entries)
                            for (final MapEntry(key: window, value: used)
                                in start.entries)
                              '$window ${_percent(used)} → '
                                  '${_percent(run.usage.planEnd[account]?[window])}',
                        ].join(' · '),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _date(DateTime at) =>
      DateFormat.MMMd().add_Hm().format(at.toLocal());

  static String _percent(double? share) =>
      share == null ? '?' : '${(share * 100).round()}%';

  /// [runs]' tokens as the cap counts them, cache reads beside (§6).
  static String _tokens(Iterable<GaiaRoutineRun> runs) {
    var counted = 0;
    var reads = 0;
    for (final run in runs) {
      counted += run.usage.counted;
      reads += run.usage.cacheRead;
    }
    return '${gaiaCompactTokens(counted)} tokens '
        '(+${gaiaCompactTokens(reads)} cache reads)';
  }
}

/// [tokens] short: 412k, 1.2M.
String gaiaCompactTokens(int tokens) => NumberFormat.compact().format(tokens);

/// A run's state as its row and card say it.
String gaiaRunStateLabel(GaiaRoutineRun run) => switch (run.state) {
  GaiaRunState.running => 'running',
  GaiaRunState.paused =>
    'paused${run.stopReason == null ? '' : ': ${run.stopReason}'}',
  GaiaRunState.done => 'done',
  GaiaRunState.ended => 'ended',
};

/// "3 submitted, 1 ready, 2 need you": a run's items by status, the empty
/// ones left out.
String gaiaRunCounts(GaiaRoutineRun run) {
  int count(GaiaRunItemStatus status) =>
      run.items.where((item) => item.status == status).length;
  return [
    for (final (status, label) in const [
      (GaiaRunItemStatus.submitted, 'submitted'),
      (GaiaRunItemStatus.ready, 'ready'),
      (GaiaRunItemStatus.needsYou, 'need you'),
      (GaiaRunItemStatus.skipped, 'skipped'),
      (GaiaRunItemStatus.failed, 'failed'),
      (GaiaRunItemStatus.waiting, 'waiting'),
    ])
      if (count(status) > 0) '${count(status)} $label',
  ].join(', ');
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.title,
    required this.detail,
    this.onTap,
    this.trailing,
  });

  final String title;
  final String detail;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: GaiaType.row.copyWith(
                      color: _hovered ? GaiaInk.bright : GaiaInk.dim,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.detail,
                    style: GaiaType.label.copyWith(color: GaiaInk.faint),
                  ),
                ],
              ),
            ),
            if (_hovered && widget.trailing != null) widget.trailing!,
          ],
        ),
      ),
    ),
  );
}

/// A routine's fields (§5.1), a new one's from the job applier's template.
class _RoutineEditor extends StatefulWidget {
  const _RoutineEditor({
    super.key,
    required this.controller,
    required this.routine,
    required this.onCancel,
    required this.onSave,
  });

  final GaiaController controller;

  /// Null for a new one.
  final GaiaRoutine? routine;
  final VoidCallback onCancel;
  final Future<void> Function(GaiaRoutine routine) onSave;

  @override
  State<_RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends State<_RoutineEditor> {
  late final GaiaRoutine? _was = widget.routine;
  late final _name = TextEditingController(text: _was?.name);
  late final _instructions = TextEditingController(
    text: _was?.instructions ?? kGaiaJobApplierInstructions,
  );
  late final _skipRules = TextEditingController(
    text: _was?.skipRules ?? kGaiaDefaultSkipRules,
  );
  late final _materials = TextEditingController(
    text: (_was?.materials ?? kGaiaRoutineMaterials).join(', '),
  );
  late final _uploads = TextEditingController(
    text: (_was?.uploads ?? kGaiaRoutineUploads).join(', '),
  );
  late final _domains = TextEditingController(
    text: (_was?.domains ?? kGaiaRoutineDomains).join(', '),
  );
  late final _google = TextEditingController(text: _was?.googleAccount);
  late final _stage = TextEditingController(text: _was?.jobStage ?? 'Applied');
  late final _calls = TextEditingController(text: '${_was?.budgetCalls ?? 80}');
  late final _minutes = TextEditingController(
    text: '${_was?.budgetMinutes ?? 15}',
  );
  late final _context = TextEditingController(
    text: '${_was?.budgetContext ?? 400000}',
  );
  late final _cap = TextEditingController(text: '${_was?.tokenCap ?? 1000000}');
  late final _wrap = TextEditingController(
    text: '${((_was?.wrapAt ?? 0.95) * 100).round()}',
  );
  late String? _projectId = _was?.projectId;
  late var _submit = _was?.submit ?? GaiaRoutineSubmit.review;
  late var _tier = _was?.tier ?? GaiaTier.standard;

  late final _fields = [
    _name,
    _instructions,
    _skipRules,
    _materials,
    _uploads,
    _domains,
    _google,
    _stage,
    _calls,
    _minutes,
    _context,
    _cap,
    _wrap,
  ];

  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      field.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  static List<String> _list(TextEditingController field) => [
    for (final part in field.text.split(RegExp(r'[,\n]')))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  static int? _number(TextEditingController field) =>
      int.tryParse(field.text.trim());

  String? get _error {
    final name = _name.text.trim();
    if (name.isEmpty) return 'Give it a name.';
    if (widget.controller.routines.any(
      (r) => r.id != _was?.id && r.name.toLowerCase() == name.toLowerCase(),
    )) {
      return 'Another routine has that name.';
    }
    if (widget.controller.project(_projectId) == null) {
      return 'Pick the project whose folder holds its materials.';
    }
    if (_instructions.text.trim().isEmpty) return 'Write its instructions.';
    if (_stage.text.trim().isEmpty) return 'Name the Jobs stage to file under.';
    final wrap = _number(_wrap);
    if ([_calls, _minutes, _context, _cap].any((f) => (_number(f) ?? 0) <= 0) ||
        wrap == null ||
        wrap <= 0 ||
        wrap >= 100) {
      return 'Budgets and caps are whole numbers above 0; the plan line is '
          '1 to 99%.';
    }
    return null;
  }

  GaiaRoutine _edited() {
    final now = utcNow();
    final base =
        _was ??
        GaiaRoutine(
          id: newId(),
          createdAt: now,
          updatedAt: now,
          name: '',
          instructions: '',
          projectId: '',
        );
    final google = _google.text.trim();
    return base.copyWith(
      name: _name.text.trim(),
      instructions: _instructions.text.trim(),
      projectId: _projectId,
      materials: _list(_materials),
      uploads: _list(_uploads),
      skipRules: _skipRules.text.trim(),
      submit: _submit,
      tier: _tier,
      budgetCalls: _number(_calls),
      budgetMinutes: _number(_minutes),
      budgetContext: _number(_context),
      googleAccount: google.isEmpty ? null : google,
      clearGoogleAccount: google.isEmpty,
      domains: _list(_domains),
      jobStage: _stage.text.trim(),
      tokenCap: _number(_cap),
      wrapAt: _number(_wrap)! / 100,
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
    child: Text(text, style: GaiaType.label.copyWith(color: GaiaInk.muted)),
  );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final error = _error;
    final project = controller.project(_projectId);
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GaiaInk.hover,
        borderRadius: BorderRadius.circular(GaiaRadius.panel),
        border: Border.all(color: GaiaInk.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GaiaPanelField(
            controller: _name,
            hintText: 'Name, as /routine takes it',
          ),
          _label('Project, whose folder holds the materials'),
          Builder(
            builder: (context) => GaiaButton(
              label: project?.name ?? 'Pick a project',
              icon: Icons.folder_outlined,
              size: 32,
              onPressed: () {
                final box = context.findRenderObject()! as RenderBox;
                showGaiaMenu(
                  context,
                  box.localToGlobal(Offset(0, box.size.height)),
                  [
                    for (final project in controller.projects)
                      GaiaMenuItem(
                        label: project.name,
                        icon: Icons.folder_outlined,
                        onPressed: () =>
                            setState(() => _projectId = project.id),
                      ),
                  ],
                );
              },
            ),
          ),
          _label('Instructions: what to do with one item'),
          GaiaPanelField(controller: _instructions, minLines: 4, maxLines: 14),
          _label('Skip rules, checked against the posting first'),
          GaiaPanelField(controller: _skipRules, minLines: 3, maxLines: 10),
          _label('Materials put in every prompt, and files it may upload'),
          GaiaPanelField(
            controller: _materials,
            hintText: 'profile.md, answers.md',
          ),
          const SizedBox(height: 6),
          GaiaPanelField(controller: _uploads, hintText: 'resume.pdf'),
          _label('Submit'),
          Wrap(
            spacing: 6,
            children: [
              GaiaPanelChoice(
                label: 'Stop at Submit',
                selected: _submit == GaiaRoutineSubmit.review,
                onTap: () => setState(() => _submit = GaiaRoutineSubmit.review),
              ),
              GaiaPanelChoice(
                label: 'Submit when sure',
                selected: _submit == GaiaRoutineSubmit.auto,
                onTap: () => setState(() => _submit = GaiaRoutineSubmit.auto),
              ),
            ],
          ),
          _label('Tier'),
          Wrap(
            spacing: 6,
            children: [
              for (final tier in GaiaTier.values)
                GaiaPanelChoice(
                  label: tier.label,
                  selected: _tier == tier,
                  onTap: () => setState(() => _tier = tier),
                ),
            ],
          ),
          _label('Per item: tool calls, minutes, most context in tokens'),
          Row(
            children: [
              Expanded(child: GaiaPanelField(controller: _calls)),
              const SizedBox(width: 6),
              Expanded(child: GaiaPanelField(controller: _minutes)),
              const SizedBox(width: 6),
              Expanded(child: GaiaPanelField(controller: _context)),
            ],
          ),
          _label('Per run: token cap (no cache reads), and the plan line in %'),
          Row(
            children: [
              Expanded(child: GaiaPanelField(controller: _cap)),
              const SizedBox(width: 6),
              Expanded(child: GaiaPanelField(controller: _wrap)),
            ],
          ),
          _label('Google account to sign in with (optional)'),
          GaiaPanelField(controller: _google, hintText: 'you@gmail.com'),
          _label('Sites an item may go to besides its own'),
          GaiaPanelField(controller: _domains, minLines: 2, maxLines: 6),
          _label('Jobs stage for submitted applications'),
          GaiaPanelField(controller: _stage),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                error,
                style: GaiaType.label.copyWith(color: kGaiaStatusRose),
              ),
            ),
          if (_was == null)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                'Saving opens its setup interview: a chat in the project that '
                'writes answers.md.',
              ),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GaiaButton(label: 'Cancel', size: 32, onPressed: widget.onCancel),
              const SizedBox(width: 8),
              GaiaButton(
                label: 'Save',
                size: 32,
                onPressed: error == null
                    ? () => widget.onSave(_edited())
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
