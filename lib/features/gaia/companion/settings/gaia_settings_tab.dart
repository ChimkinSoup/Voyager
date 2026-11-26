import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/gaia_keybinds.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';

/// The settings panel's Settings tab (GAIA_SETTINGS_HLD.md §4): the Gaia
/// page's settings in Gaia's look, each saved through the main instance
/// with `putSettings`, and the inbox alert's threshold (§5.5). What it
/// shows is [GaiaController.settings], which the `settings` event keeps
/// fresh, so a change from the page or another device shows here too.
class GaiaSettingsTab extends StatelessWidget {
  const GaiaSettingsTab({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    Future<bool> save(Map<String, Object?> changes) =>
        _save(context, controller, changes);
    return GaiaPanelScroll(
      key: const PageStorageKey('gaia panel settings'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GaiaPanelSection(
                heading: 'Notifications',
                children: [
                  GaiaPanelSwitch(
                    title: 'Notify when a run finishes',
                    subtitle:
                        'A Windows notification when Gaia finishes, or has a '
                        'question, while it is hidden.',
                    value: settings['notifyOnDone'] != false,
                    onChanged: (on) => save({'notifyOnDone': on}),
                  ),
                ],
              ),
              GaiaPanelSection(
                heading: 'Your name',
                children: [
                  const GaiaPanelNote(
                    'Gaia uses it to greet you in a new chat. Synced to all '
                    'your devices.',
                  ),
                  _SavedText(
                    key: const ValueKey('userName'),
                    stored: settings['userName'] as String? ?? '',
                    maxLength: 24,
                    normalize: (text) => text.trim(),
                    onSave: (text) => save({'userName': text}),
                  ),
                ],
              ),
              GaiaPanelSection(
                heading: 'GAIA.md',
                children: [
                  const GaiaPanelNote(
                    "Instructions every agent gets, in place of the CLIs' own "
                    'global files (your CLAUDE.md is left out of Gaia chats). '
                    'Synced to all your devices.',
                  ),
                  _SavedText(
                    key: const ValueKey('gaiaMd'),
                    stored: settings['gaiaMd'] as String? ?? '',
                    hint: 'e.g. Keep answers short. I use Windows and Flutter.',
                    minLines: 8,
                    maxLines: 20,
                    onSave: (text) => save({'gaiaMd': text}),
                  ),
                ],
              ),
              GaiaPanelSection(
                heading: 'Context',
                children: [
                  GaiaPanelSwitch(
                    title: 'Say which window Gaia was opened from',
                    subtitle:
                        'Each message carries the app, window title and, in a '
                        'browser, the address you were on. It shows on the '
                        'draft, where you can remove it. Off, type /window to '
                        'attach it to one message.',
                    value: settings['windowContext'] != false,
                    onChanged: (on) => save({'windowContext': on}),
                  ),
                  const SizedBox(height: 8),
                  const GaiaPanelNote(
                    "Never read: apps and sites Gaia doesn't describe or read "
                    'a selection from, one per line: an app or its exe name, '
                    'or a site like rbc.com.',
                  ),
                  _SavedText(
                    key: const ValueKey('contextExclusions'),
                    stored: gaiaContextExclusionsFromJson(
                      settings['contextExclusions'],
                    ).join('\n'),
                    minLines: 3,
                    maxLines: 8,
                    onSave: (text) => save({
                      'contextExclusions': [
                        for (final line in text.split('\n'))
                          if (line.trim().isNotEmpty) line.trim(),
                      ],
                    }),
                  ),
                  const GaiaPanelNote(
                    "Gaia's window is hidden from screenshots and screen "
                    'recordings, including your own screen shares, so it '
                    'never shows up in what it captures.',
                  ),
                ],
              ),
              _AgentsSection(controller: controller, save: save),
              _UtilitySection(controller: controller, save: save),
              _CommandsSection(controller: controller, save: save),
              _KeysSection(controller: controller, save: save),
              GaiaPanelSection(
                heading: 'Inbox alert',
                children: [
                  const GaiaPanelNote(
                    'Alert me when this many memories are waiting: a chip in '
                    "Gaia's header counts them down as you decide them, once "
                    'there are at least this many.',
                  ),
                  _SavedText(
                    key: const ValueKey('memoryAlertAt'),
                    stored: '${controller.memoryAlertAt}',
                    // Room for Save inside it.
                    width: 170,
                    digitsOnly: true,
                    valid: (text) => (int.tryParse(text) ?? 0) >= 1,
                    onSave: (text) => save({'memoryAlertAt': int.parse(text)}),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Saves [changes], or says why it couldn't in a toast. True when saved.
Future<bool> _save(
  BuildContext context,
  GaiaController controller,
  Map<String, Object?> changes,
) async {
  try {
    await controller.putSettings(changes);
    return true;
  } on GaiaPipeException catch (error) {
    if (context.mounted) {
      showGaiaToast(
        context,
        mark: GaiaToastMark.error,
        title: 'Not saved',
        body: error.message,
      );
    }
    return false;
  }
}

/// A stored text and its box, with Save while it differs. It reloads when
/// the stored text changes elsewhere while nothing here is unsaved.
class _SavedText extends StatefulWidget {
  const _SavedText({
    super.key,
    required this.stored,
    required this.onSave,
    this.hint,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
    this.width,
    this.digitsOnly = false,
    this.normalize,
    this.valid,
  });

  final String stored;
  final Future<bool> Function(String text) onSave;
  final String? hint;
  final int? minLines;
  final int maxLines;
  final int? maxLength;
  final double? width;
  final bool digitsOnly;

  /// What's saved of what's typed, such as without the spaces round it.
  final String Function(String text)? normalize;

  /// Whether what's typed can be saved.
  final bool Function(String text)? valid;

  @override
  State<_SavedText> createState() => _SavedTextState();
}

class _SavedTextState extends State<_SavedText> {
  late final _text = TextEditingController(text: widget.stored)
    ..addListener(_onText);

  /// The text as last loaded or saved.
  late var _saved = widget.stored;
  var _saving = false;

  void _onText() {
    final text = _text.text;
    final kept = text
        .replaceAll(widget.digitsOnly ? RegExp(r'\D') : RegExp(r'(?!)'), '')
        .substring(
          0,
          widget.maxLength == null
              ? null
              : text.length.clamp(0, widget.maxLength!),
        );
    if (kept.length != text.length) {
      _text.value = TextEditingValue(
        text: kept,
        selection: TextSelection.collapsed(offset: kept.length),
      );
      return;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(_SavedText old) {
    super.didUpdateWidget(old);
    if (_text.text == _saved && widget.stored != _saved) {
      _saved = widget.stored;
      _text.text = widget.stored;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _value => widget.normalize?.call(_text.text) ?? _text.text;

  bool get _dirty =>
      _value != _saved && (widget.valid?.call(_value) ?? true) && !_saving;

  Future<void> _submit() async {
    if (!_dirty) return;
    final value = _value;
    setState(() => _saving = true);
    try {
      // A failure is said in a toast; what was typed stays.
      if (!await widget.onSave(value) || !mounted) return;
      _saved = value;
      if (_text.text != value) _text.text = value;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Save shows in the box only while there's something to save.
    final field = GaiaPanelField(
      controller: _text,
      hintText: widget.hint,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      onSubmitted: _submit,
      trailing: AnimatedSwitcher(
        duration: GaiaMotion.quick,
        child: _dirty
            ? GaiaButton(
                key: const ValueKey('save'),
                label: 'Save',
                size: 28,
                padding: 10,
                onPressed: _submit,
              )
            : const SizedBox(width: 8),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: widget.width == null
          ? field
          : Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(width: widget.width, child: field),
            ),
    );
  }
}

/// The adapters an agent can be added on, with their names.
const _adapterLabels = {
  kGaiaClaudeCodeAdapter: 'Claude Code',
  kGaiaCodexAdapter: 'Codex',
};

String _agentLine(GaiaAgent agent) =>
    '${_adapterLabels[agent.adapter] ?? agent.adapter} · ${agent.model}'
    '${agent.effort == null ? '' : ' · ${agent.effort} effort'}';

/// Tiers and agents (GAIA_HLD.md §7.1): which agent each tier runs on, and
/// the agents to pick from. A tier's agent is picked from a menu; a new
/// agent is made in an editor that opens in place.
class _AgentsSection extends StatefulWidget {
  const _AgentsSection({required this.controller, required this.save});

  final GaiaController controller;
  final Future<bool> Function(Map<String, Object?> changes) save;

  @override
  State<_AgentsSection> createState() => _AgentsSectionState();
}

class _AgentsSectionState extends State<_AgentsSection> {
  var _adding = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final agents = controller.agents;
    final tiers = controller.tiers;
    final inUse = tiers.values.toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GaiaPanelSection(
          heading: 'Tiers',
          children: [
            const GaiaPanelNote(
              "Each tier runs on an agent. Pick the tier for a message from "
              "Gaia's composer.",
            ),
            for (final tier in GaiaTier.values)
              _PickRow(
                key: ValueKey('tier ${tier.name}'),
                label: tier.label,
                value: switch (agents
                    .where((agent) => agent.id == tiers[tier])
                    .firstOrNull) {
                  final agent? => '${agent.label} · ${_agentLine(agent)}',
                  null => 'No agent',
                },
                items: [
                  for (final agent in agents)
                    GaiaMenuItem(
                      label: agent.label,
                      detail: _agentLine(agent),
                      onPressed: () => widget.save({
                        'tiers': gaiaTiersToJson({...tiers, tier: agent.id}),
                      }),
                    ),
                ],
              ),
          ],
        ),
        GaiaPanelSection(
          heading: 'Agents',
          trailing: _adding
              ? null
              : GaiaButton(
                  label: 'Add agent',
                  icon: Icons.add,
                  size: 28,
                  padding: 10,
                  onPressed: () => setState(() => _adding = true),
                ),
          children: [
            for (final agent in agents)
              _HoverRow(
                key: ValueKey('agent ${agent.id}'),
                title: agent.label,
                detail: _agentLine(agent),
                actions: [
                  GaiaButton(
                    tooltip: inUse.contains(agent.id)
                        ? 'A tier uses this agent'
                        : 'Remove',
                    icon: Icons.delete_outline,
                    size: 24,
                    iconSize: 16,
                    onPressed: inUse.contains(agent.id)
                        ? null
                        : () => widget.save({
                            'agents': [
                              for (final other in agents)
                                if (other.id != agent.id) other.toJson(),
                            ],
                          }),
                  ),
                ],
              ),
            if (_adding)
              _AgentEditor(
                onCancel: () => setState(() => _adding = false),
                onAdd: (agent) async {
                  final saved = await widget.save({
                    'agents': [
                      for (final other in agents) other.toJson(),
                      agent.toJson(),
                    ],
                  });
                  if (saved && mounted) setState(() => _adding = false);
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// A new agent: its CLI, model, effort and name, each chosen from pills
/// where there's a list, typed where there isn't.
class _AgentEditor extends StatefulWidget {
  const _AgentEditor({required this.onCancel, required this.onAdd});

  final VoidCallback onCancel;
  final Future<void> Function(GaiaAgent agent) onAdd;

  @override
  State<_AgentEditor> createState() => _AgentEditorState();
}

class _AgentEditorState extends State<_AgentEditor> {
  final _label = TextEditingController();
  final _model = TextEditingController();
  var _adapter = kGaiaClaudeCodeAdapter;

  /// Null for the CLI's default.
  String? _effort;

  /// The model is typed in, not one of [kGaiaModels].
  var _custom = false;

  @override
  void initState() {
    super.initState();
    _label.addListener(() => setState(() {}));
    _model.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _label.dispose();
    _model.dispose();
    super.dispose();
  }

  List<String> get _efforts => gaiaEfforts(_adapter, _model.text.trim());

  /// [_effort], unless the model now chosen doesn't take it.
  String? get _chosenEffort => _efforts.contains(_effort) ? _effort : null;

  bool get _valid =>
      _label.text.trim().isNotEmpty && _model.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final models = kGaiaModels[_adapter] ?? const <String>[];
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 0, 6),
      child: Text(text, style: GaiaType.label.copyWith(color: GaiaInk.muted)),
    );
    return _EditorBox(
      fields: [
        label('CLI'),
        Wrap(
          children: [
            for (final MapEntry(:key, :value) in _adapterLabels.entries)
              GaiaPanelChoice(
                label: value,
                selected: _adapter == key,
                onTap: () => setState(() {
                  _adapter = key;
                  // Each CLI has its own models and levels.
                  if (!_custom) _model.clear();
                }),
              ),
          ],
        ),
        label('Model'),
        Wrap(
          runSpacing: 4,
          children: [
            for (final model in models)
              GaiaPanelChoice(
                label: model,
                selected: !_custom && _model.text == model,
                onTap: () => setState(() {
                  _custom = false;
                  _model.text = model;
                }),
              ),
            GaiaPanelChoice(
              label: 'Custom…',
              selected: _custom,
              onTap: () => setState(() {
                _custom = true;
                _model.clear();
              }),
            ),
          ],
        ),
        if (_custom)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GaiaPanelField(
              controller: _model,
              hintText: _adapter == kGaiaCodexAdapter
                  ? 'e.g. gpt-6.1-sol'
                  : 'e.g. claude-sonnet-5-5',
            ),
          ),
        label('Effort'),
        Wrap(
          children: [
            GaiaPanelChoice(
              label: 'Default',
              selected: _chosenEffort == null,
              onTap: () => setState(() => _effort = null),
            ),
            for (final effort in _efforts)
              GaiaPanelChoice(
                label: effort,
                selected: _chosenEffort == effort,
                onTap: () => setState(() => _effort = effort),
              ),
          ],
        ),
        label('Name'),
        GaiaPanelField(controller: _label, hintText: 'e.g. GPT-6.1 Sol'),
      ],
      actions: [
        GaiaButton(label: 'Cancel', size: 32, onPressed: widget.onCancel),
        GaiaButton(
          label: 'Add',
          size: 32,
          onPressed: _valid
              ? () => widget.onAdd(
                  GaiaAgent(
                    id: const Uuid().v4(),
                    label: _label.text.trim(),
                    adapter: _adapter,
                    model: _model.text.trim(),
                    effort: _chosenEffort,
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

/// The utility model (GAIA_HLD.md §5.1) and the router (§7.2) it powers.
class _UtilitySection extends StatelessWidget {
  const _UtilitySection({required this.controller, required this.save});

  final GaiaController controller;
  final Future<bool> Function(Map<String, Object?> changes) save;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final defaultTier = controller.defaultTier;
    return GaiaPanelSection(
      heading: 'Utility model',
      children: [
        const GaiaPanelNote(
          'A fast Claude model on Claude Code, on the same login as your '
          'chats: it picks the tier for a new chat, writes chat titles and '
          'sums up a chat for another agent. No API key needed.',
        ),
        _SavedText(
          key: const ValueKey('utilityModel'),
          stored: settings['utilityModel'] as String? ?? '',
          hint: kGaiaDefaultUtilityModel,
          normalize: (text) =>
              text.trim().isEmpty ? kGaiaDefaultUtilityModel : text.trim(),
          onSave: (text) => save({'utilityModel': text}),
        ),
        GaiaPanelSwitch(
          title: 'Pick the tier for a new chat',
          subtitle:
              "Only a chat's first message. After that, the tier only "
              'changes when you change it.',
          value: settings['autoRoute'] != false,
          onChanged: (on) => save({'autoRoute': on}),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: Text(
            'Default tier',
            style: GaiaType.row.copyWith(color: GaiaInk.dim),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Wrap(
            children: [
              GaiaPanelChoice(
                label: 'Last used',
                selected: defaultTier == null,
                onTap: () => save({'defaultTier': null}),
              ),
              for (final tier in GaiaTier.values)
                GaiaPanelChoice(
                  label: tier.label,
                  selected: defaultTier == tier,
                  onTap: () => save({'defaultTier': tier.name}),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const GaiaPanelNote(
          'A new chat starts on it when the router is off or fails, and the '
          'router picks it when unsure.',
        ),
        const GaiaPanelNote('Router rubric'),
        _SavedText(
          key: const ValueKey('routerRubric'),
          stored: settings['routerRubric'] as String? ?? '',
          hint: kGaiaDefaultRouterRubric,
          minLines: 3,
          maxLines: 8,
          onSave: (text) => save({'routerRubric': text}),
        ),
      ],
    );
  }
}

/// The user's slash commands (GAIA_HLD.md §9.2): templates `/name args`
/// expands to on send. A row opens into its editor in place.
class _CommandsSection extends StatefulWidget {
  const _CommandsSection({required this.controller, required this.save});

  final GaiaController controller;
  final Future<bool> Function(Map<String, Object?> changes) save;

  @override
  State<_CommandsSection> createState() => _CommandsSectionState();
}

class _CommandsSectionState extends State<_CommandsSection> {
  /// The command open in its editor, by name; '' for a new one, null for
  /// none.
  String? _editing;

  Set<String> _taken(String? except) => {
    ...kGaiaReservedCommandNames,
    for (final account in widget.controller.accounts) account.alias,
    for (final command in widget.controller.commands)
      if (command.name != except) command.name,
  };

  Future<void> _put(GaiaCommand? was, GaiaCommand edited) async {
    final commands = widget.controller.commands;
    final saved = await widget.save({
      'commands': [
        if (was == null)
          for (final command in [...commands, edited]) command.toJson()
        else
          for (final command in commands)
            (command.name == was.name ? edited : command).toJson(),
      ],
    });
    if (saved && mounted) setState(() => _editing = null);
  }

  @override
  Widget build(BuildContext context) {
    final commands = widget.controller.commands;
    return GaiaPanelSection(
      heading: 'Commands',
      trailing: _editing == ''
          ? null
          : GaiaButton(
              label: 'Add command',
              icon: Icons.add,
              size: 28,
              padding: 10,
              onPressed: () => setState(() => _editing = ''),
            ),
      children: [
        const GaiaPanelNote(
          r'Type /name in Gaia, then anything after it: it becomes the '
          r'template, with $ARGUMENTS (what you typed after the name), $1 to '
          r'$9 (its words), $CLIPBOARD, $SELECTION (the text selected '
          r'where you opened Gaia) and $DATE filled in.',
        ),
        for (final command in commands)
          if (_editing == command.name)
            _CommandEditor(
              key: ValueKey('edit ${command.name}'),
              command: command,
              taken: _taken(command.name),
              onCancel: () => setState(() => _editing = null),
              onSave: (edited) => _put(command, edited),
            )
          else
            _HoverRow(
              key: ValueKey('command ${command.name}'),
              title: '/${command.name}',
              detail: command.description.isEmpty
                  ? command.template.split('\n').first
                  : command.description,
              onTap: () => setState(() => _editing = command.name),
              actions: [
                GaiaButton(
                  tooltip: 'Remove',
                  icon: Icons.delete_outline,
                  size: 24,
                  iconSize: 16,
                  onPressed: () => widget.save({
                    'commands': [
                      for (final other in commands)
                        if (other.name != command.name) other.toJson(),
                    ],
                  }),
                ),
              ],
            ),
        if (_editing == '')
          _CommandEditor(
            key: const ValueKey('new command'),
            command: null,
            taken: _taken(null),
            onCancel: () => setState(() => _editing = null),
            onSave: (edited) => _put(null, edited),
          ),
      ],
    );
  }
}

class _CommandEditor extends StatefulWidget {
  const _CommandEditor({
    super.key,
    required this.command,
    required this.taken,
    required this.onCancel,
    required this.onSave,
  });

  /// Null for a new one.
  final GaiaCommand? command;

  /// Names already in use.
  final Set<String> taken;
  final VoidCallback onCancel;
  final Future<void> Function(GaiaCommand command) onSave;

  @override
  State<_CommandEditor> createState() => _CommandEditorState();
}

class _CommandEditorState extends State<_CommandEditor> {
  late final _name = TextEditingController(text: widget.command?.name);
  late final _description = TextEditingController(
    text: widget.command?.description,
  );
  late final _template = TextEditingController(text: widget.command?.template);
  late var _standalone = widget.command?.standalone ?? false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _template.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _template.dispose();
    super.dispose();
  }

  String? get _nameError =>
      gaiaCommandNameError(_name.text.trim(), widget.taken);

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _nameError == null &&
      _template.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final error = _nameError;
    return _EditorBox(
      fields: [
        Row(
          children: [
            Text('/', style: GaiaType.row.copyWith(color: GaiaInk.muted)),
            const SizedBox(width: 4),
            Expanded(
              child: GaiaPanelField(controller: _name, hintText: 'Name'),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 0, 0),
            child: Text(
              error,
              style: GaiaType.label.copyWith(color: kGaiaStatusRose),
            ),
          ),
        const SizedBox(height: 8),
        GaiaPanelField(
          controller: _description,
          hintText: 'Description (optional)',
        ),
        const SizedBox(height: 8),
        GaiaPanelField(
          controller: _template,
          hintText: r'Template, e.g. Explain this in plain words: $ARGUMENTS',
          minLines: 3,
          maxLines: 10,
        ),
        const SizedBox(height: 4),
        GaiaPanelSwitch(
          title: 'Send as soon as it is picked',
          subtitle: 'For a command that takes no arguments.',
          value: _standalone,
          onChanged: (on) => setState(() => _standalone = on),
        ),
      ],
      actions: [
        GaiaButton(label: 'Cancel', size: 32, onPressed: widget.onCancel),
        GaiaButton(
          label: 'Save',
          size: 32,
          onPressed: _valid
              ? () => widget.onSave(
                  GaiaCommand(
                    name: _name.text.trim(),
                    template: _template.text,
                    description: _description.text.trim(),
                    standalone: _standalone,
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

/// Gaia's rebindable keys (GAIA_HLD.md §9.1, §15.1): send, settings, and
/// the global hotkeys. Change waits for the keys in a small overlay.
class _KeysSection extends StatelessWidget {
  const _KeysSection({required this.controller, required this.save});

  final GaiaController controller;
  final Future<bool> Function(Map<String, Object?> changes) save;

  Future<void> _change(BuildContext context, GaiaKeybind keybind) async {
    final combo = await showDialog<GaiaCombo>(
      context: context,
      builder: (_) => _ComboCapture(keybind: keybind),
    );
    if (combo == null || !context.mounted) return;
    final keybinds = controller.keybinds;
    final stored = '$combo';
    final clash = GaiaKeybind.values
        .where(
          (other) =>
              other != keybind &&
              other.global == keybind.global &&
              gaiaComboFor(other, keybinds) == stored,
        )
        .firstOrNull
        ?.label;
    // Send only works inside Gaia, so it can't take a system-wide hotkey.
    final voyagerClash = clash != null
        ? null
        : !keybind.global
        ? gaiaFixedKeyClash(stored, [
            for (final tab in GaiaPanelTab.values) tab.label,
          ])
        : gaiaHotkeyClash(stored, await controller.voyagerHotkeys());
    if (!context.mounted) return;
    if (clash ?? voyagerClash case final taken?) {
      showGaiaToast(
        context,
        mark: GaiaToastMark.error,
        title: 'Not changed',
        body: '$stored is already $taken.',
      );
      return;
    }
    await save({
      'keybinds': {...keybinds, keybind.name: stored},
    });
  }

  @override
  Widget build(BuildContext context) {
    final keybinds = controller.keybinds;
    return GaiaPanelSection(
      heading: 'Keys',
      children: [
        const GaiaPanelNote(
          'Send and Settings work in Gaia. The others work from any app; '
          'they need Ctrl, Alt or Win so they never take over plain typing.',
        ),
        for (final keybind in GaiaKeybind.values)
          _HoverRow(
            key: ValueKey('key ${keybind.name}'),
            title: keybind.label,
            onTap: () => _change(context, keybind),
            alwaysShowActions: true,
            actions: [
              if (keybinds.containsKey(keybind.name))
                GaiaButton(
                  tooltip: keybind.defaultCombo.isEmpty
                      ? 'Clear'
                      : 'Reset to ${keybind.defaultCombo}',
                  icon: Icons.restart_alt,
                  size: 24,
                  iconSize: 16,
                  onPressed: () => save({
                    'keybinds': {
                      for (final MapEntry(:key, :value) in keybinds.entries)
                        if (key != keybind.name) key: value,
                    },
                  }),
                ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Change',
                child: GaiaKeyChip(switch (gaiaComboFor(keybind, keybinds)) {
                  '' => 'Not set',
                  final combo => combo,
                }, onTap: () => _change(context, keybind)),
              ),
              const SizedBox(width: 6),
            ],
          ),
        GaiaPanelSwitch(
          title: 'Put Gaia on the right in a split',
          subtitle:
              'Split the screen with Gaia puts the other window on the '
              'left. Off, Gaia goes on the left and the other window on the '
              'right.',
          value: controller.settings['splitGaiaRight'] == true,
          onChanged: (on) => save({'splitGaiaRight': on}),
        ),
      ],
    );
  }
}

/// Waits for a key combo: the key pressed with the modifiers held. Esc on
/// its own cancels.
class _ComboCapture extends StatefulWidget {
  const _ComboCapture({required this.keybind});

  final GaiaKeybind keybind;

  @override
  State<_ComboCapture> createState() => _ComboCaptureState();
}

class _ComboCaptureState extends State<_ComboCapture> {
  String? _refused;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      Navigator.of(context).pop();
      return true;
    }
    final combo = gaiaComboFromEvent(event);
    if (combo == null) return false;
    // Settings' plain key would be eaten from every Gaia text box.
    if ((widget.keybind.global || widget.keybind == GaiaKeybind.settings) &&
        !combo.hasModifier) {
      setState(() => _refused = '$combo needs Ctrl, Alt or Win with it.');
      return true;
    }
    Navigator.of(context).pop(combo);
    return true;
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 360,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: gaiaFloating(
        Theme.of(context).colorScheme,
        radius: GaiaRadius.panel,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.keybind.label,
              style: GaiaType.row.copyWith(color: GaiaInk.bright),
            ),
            const SizedBox(height: 8),
            Text(
              _refused ??
                  'Press the keys for ${widget.keybind.label}: a letter, '
                      'digit, F-key, Space, Enter or Backspace, with any '
                      'modifiers. Esc to cancel.',
              style: GaiaType.row.copyWith(
                color: _refused == null ? GaiaInk.muted : kGaiaStatusRose,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A label, what's chosen, and a menu of the choices on a click.
class _PickRow extends StatefulWidget {
  const _PickRow({
    super.key,
    required this.label,
    required this.value,
    required this.items,
  });

  final String label;
  final String value;
  final List<GaiaMenuItem> items;

  @override
  State<_PickRow> createState() => _PickRowState();
}

class _PickRowState extends State<_PickRow> {
  var _hovered = false;

  /// What's chosen: the menu opens under its start, at the row's foot.
  final _valueKey = GlobalKey();

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) {
        final row = context.findRenderObject()! as RenderBox;
        final value =
            _valueKey.currentContext!.findRenderObject()! as RenderBox;
        final start = value.localToGlobal(Offset.zero).dx;
        showGaiaMenu(
          context,
          Offset(start, row.localToGlobal(Offset(0, row.size.height)).dy),
          widget.items,
        );
      },
      child: AnimatedContainer(
        duration: GaiaMotion.quick,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(GaiaRadius.row),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(
                widget.label,
                style: GaiaType.row.copyWith(
                  color: _hovered ? GaiaInk.bright : GaiaInk.dim,
                ),
              ),
            ),
            Expanded(
              child: Text(
                key: _valueKey,
                widget.value,
                overflow: TextOverflow.ellipsis,
                style: GaiaType.row.copyWith(color: GaiaInk.muted),
              ),
            ),
            Icon(Icons.unfold_more, size: 16, color: GaiaInk.faint),
          ],
        ),
      ),
    ),
  );
}

/// A Gaia row: a [title], a muted [detail], and [actions] shown on hover.
class _HoverRow extends StatefulWidget {
  const _HoverRow({
    super.key,
    required this.title,
    this.detail,
    required this.actions,
    this.onTap,
    this.alwaysShowActions = false,
  });

  final String title;
  final String? detail;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final bool alwaysShowActions;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final shown = _hovered || widget.alwaysShowActions;
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: GaiaMotion.quick,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(
            color: _hovered
                ? GaiaInk.hover
                : GaiaInk.hover.withValues(alpha: 0),
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
                    if (widget.detail case final detail?) ...[
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GaiaType.label.copyWith(
                          color: GaiaInk.muted,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AnimatedOpacity(
                duration: GaiaMotion.quick,
                opacity: shown ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !shown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: widget.actions,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An editor opened in place of a row: a card in the hairline, its fields,
/// then its buttons at the right.
class _EditorBox extends StatelessWidget {
  const _EditorBox({required this.fields, required this.actions});

  final List<Widget> fields;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
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
        ...fields,
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (final (i, action) in actions.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              action,
            ],
          ],
        ),
      ],
    ),
  );
}
