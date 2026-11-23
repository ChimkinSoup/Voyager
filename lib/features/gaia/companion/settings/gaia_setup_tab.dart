import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_clis.dart';
import 'package:voyager/features/gaia/companion/gaia_action_icon.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_bar.dart';

/// What installs each CLI.
const _install = {
  kGaiaClaudeCodeAdapter: 'npm install -g @anthropic-ai/claude-code',
  kGaiaCodexAdapter: 'npm install -g @openai/codex',
};

/// The settings panel's Setup tab (GAIA_SETTINGS_HLD.md §4): each CLI's
/// checklist with Check again, then its accounts with their logins and
/// usage, and Add account. The checks run here in the companion, which runs
/// the CLIs; accounts are saved through the main instance with
/// `putSettings`.
class GaiaSetupTab extends StatelessWidget {
  const GaiaSetupTab({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) => GaiaPanelScroll(
    key: const PageStorageKey('gaia panel setup'),
    slivers: [
      for (final adapter in _install.keys)
        SliverToBoxAdapter(
          child: _CliSection(controller: controller, adapter: adapter),
        ),
    ],
  );
}

String _v(GaiaCliVersion version) =>
    '${version.$1}.${version.$2}.${version.$3}';

class _CliSection extends StatelessWidget {
  const _CliSection({required this.controller, required this.adapter});

  final GaiaController controller;
  final String adapter;

  @override
  Widget build(BuildContext context) {
    final cli = kGaiaClis[adapter]!;
    final version = controller.cliVersions[adapter];
    final (low, high) = cli.tested;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GaiaPanelHeading(
          cli.name.toUpperCase(),
          trailing: GaiaButton(
            label: 'Check again',
            icon: Icons.refresh,
            size: 28,
            padding: 10,
            onPressed: controller.checkingSetup
                ? null
                : () => unawaited(controller.checkSetup()),
          ),
        ),
        if (!controller.cliChecked)
          const _CheckRow(state: null, label: 'Checking…')
        else if (version == null)
          _CheckRow(
            state: false,
            label: 'Not installed',
            fix: _install[adapter],
          )
        else ...[
          _CheckRow(state: true, label: 'Installed: ${_v(version)}'),
          if (isVersionInRange(version, cli.tested))
            const _CheckRow(state: true, label: 'A tested version')
          else
            _CheckRow(
              state: null,
              label:
                  'Untested version: Gaia is tested with ${_v(low)} up to '
                  '${_v(high)}. Chats still run.',
            ),
          _Accounts(controller: controller, adapter: adapter),
        ],
      ],
    );
  }
}

/// An adapter's accounts in order (GAIA_HLD.md §6.1), the first being the
/// default, each with its login and usage.
class _Accounts extends StatelessWidget {
  const _Accounts({required this.controller, required this.adapter});

  final GaiaController controller;
  final String adapter;

  /// True when saved; otherwise says why in a toast.
  Future<bool> _save(BuildContext context, List<GaiaAccount> list) async {
    try {
      await controller.putSettings({
        'accounts': [
          for (final account in controller.accounts)
            if (account.adapter != adapter) account.toJson(),
          for (final account in list) account.toJson(),
        ],
      });
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

  @override
  Widget build(BuildContext context) {
    final accounts = controller.accountsFor(adapter);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        for (final (index, account) in accounts.indexed)
          _AccountRow(
            key: ValueKey(account.id),
            controller: controller,
            account: account,
            several: accounts.length > 1,
            // Every adapter's accounts share the composer's `/` palette.
            takenAliases: {
              ...kGaiaReservedCommandNames,
              for (final command in controller.commands) command.name,
              for (final other in controller.accounts)
                if (other.id != account.id || other.adapter != adapter)
                  other.alias,
            },
            onSave: (label, alias) => _save(context, [
              for (final other in accounts)
                other == account
                    ? other.copyWith(label: label, alias: alias)
                    : other,
            ]),
            onUp: index == 0
                ? null
                : () => _save(
                    context,
                    [...accounts]
                      ..removeAt(index)
                      ..insert(index - 1, account),
                  ),
            onDown: index == accounts.length - 1
                ? null
                : () => _save(
                    context,
                    [...accounts]
                      ..removeAt(index)
                      ..insert(index + 1, account),
                  ),
            onRemove: accounts.length == 1
                ? null
                : () => _save(context, [...accounts]..removeAt(index)),
          ),
        _AddAccount(
          adapter: adapter,
          taken: {for (final account in accounts) account.dir},
          onAdd: (label, dir) => _save(context, [
            ...accounts,
            GaiaAccount(
              id: const Uuid().v4(),
              label: label,
              adapter: adapter,
              dir: dir,
            ),
          ]),
        ),
      ],
    );
  }
}

class _AccountRow extends StatefulWidget {
  const _AccountRow({
    super.key,
    required this.controller,
    required this.account,
    required this.several,
    required this.takenAliases,
    required this.onSave,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });

  final GaiaController controller;
  final GaiaAccount account;
  final bool several;

  /// Names its alias can't take.
  final Set<String> takenAliases;
  final Future<void> Function(String label, String alias) onSave;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onRemove;

  @override
  State<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends State<_AccountRow> {
  late final _label = TextEditingController(text: widget.account.label)
    ..addListener(_changed);
  late final _alias = TextEditingController(text: widget.account.alias)
    ..addListener(_changed);
  var _hovered = false;

  void _changed() => setState(() {});

  @override
  void didUpdateWidget(_AccountRow old) {
    super.didUpdateWidget(old);
    // Renamed elsewhere, while nothing here is unsaved.
    if (_label.text == old.account.label) _label.text = widget.account.label;
    if (_alias.text == old.account.alias) _alias.text = widget.account.alias;
  }

  @override
  void dispose() {
    _label.dispose();
    _alias.dispose();
    super.dispose();
  }

  String? get _aliasError =>
      gaiaCommandNameError(_alias.text.trim(), widget.takenAliases);

  bool get _canSave {
    final label = _label.text.trim();
    final alias = _alias.text.trim();
    return label.isNotEmpty &&
        _aliasError == null &&
        (label != widget.account.label || alias != widget.account.alias);
  }

  void _save() {
    if (_canSave) {
      unawaited(widget.onSave(_label.text.trim(), _alias.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final account = widget.account;
    final codex = account.adapter == kGaiaCodexAdapter;
    final check = controller.accountChecks[account.key];
    final error = _aliasError;
    final health = controller.usageHealth[account.key];
    final usage = controller.usage[account.key];
    // The login check already says so, with the command to fix it.
    final usageNote =
        health == GaiaUsageHealth.signedOut && check?.loggedIn == false
        ? null
        : controller.usageUntracked(account.adapter, account);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        margin: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        padding: const EdgeInsets.all(12),
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
                SizedBox(
                  width: 150,
                  child: GaiaPanelField(
                    controller: _label,
                    hintText: 'Account',
                    onSubmitted: _save,
                  ),
                ),
                const SizedBox(width: 8),
                Text('/', style: GaiaType.row.copyWith(color: GaiaInk.muted)),
                const SizedBox(width: 2),
                SizedBox(
                  width: 120,
                  child: GaiaPanelField(
                    controller: _alias,
                    hintText: 'alias',
                    onSubmitted: _save,
                  ),
                ),
                if (_canSave) ...[
                  const SizedBox(width: 8),
                  GaiaButton(label: 'Save', size: 32, onPressed: _save),
                ],
                const Spacer(),
                if (widget.several)
                  AnimatedOpacity(
                    duration: GaiaMotion.quick,
                    opacity: _hovered ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !_hovered,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GaiaActionIcon(
                            label: 'Move up',
                            icon: Icons.arrow_upward,
                            compact: true,
                            onPressed: widget.onUp,
                          ),
                          GaiaActionIcon(
                            label: 'Move down',
                            icon: Icons.arrow_downward,
                            compact: true,
                            onPressed: widget.onDown,
                          ),
                          GaiaActionIcon(
                            label: 'Remove',
                            icon: Icons.delete_outline,
                            compact: true,
                            onPressed: widget.onRemove,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(170, 4, 0, 0),
                child: Text(
                  error,
                  style: GaiaType.label.copyWith(color: kGaiaStatusRose),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 0, 2),
              child: Text(
                account.dir.isEmpty
                    ? 'The folder Voyager was started with'
                    : account.dir,
                overflow: TextOverflow.ellipsis,
                style: GaiaType.label.copyWith(
                  color: GaiaInk.faint,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            // A login's check, once there's an answer: a CLI that hasn't
            // said shouldn't hold the tab up.
            if (check != null)
              _CheckRow(
                state: check.loggedIn == true,
                label: switch (check.loggedIn) {
                  true =>
                    'Logged in'
                        '${check.email == null ? '' : ' as ${check.email}'}',
                  false => 'Not logged in',
                  null => "Couldn't read the login status",
                },
                fix: check.loggedIn == true
                    ? null
                    : codex
                    ? account.dir.isEmpty
                          ? 'codex login'
                          : '\$env:CODEX_HOME="${account.dir}"; codex login'
                    : account.dir.isEmpty
                    ? 'claude auth login'
                    : '\$env:CLAUDE_CONFIG_DIR="${account.dir}"; '
                          'claude auth login',
              ),
            if (check?.sandboxReady case final ready?)
              _CheckRow(
                state: ready,
                label: ready
                    ? 'Sandbox set up for Gaia'
                    : "Codex's Windows sandbox needs setting up once for this "
                          'account. Windows will ask you to approve it.',
                action: ready
                    ? null
                    : GaiaButton(
                        label: 'Set up',
                        size: 28,
                        padding: 10,
                        onPressed:
                            controller.settingUpSandbox.contains(account.key)
                            ? null
                            : () => unawaited(
                                controller.setUpCodexSandbox(account),
                              ),
                      ),
              ),
            if (usageNote != null)
              _CheckRow(state: null, label: usageNote)
            else if (usage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 0, 0),
                child: Wrap(
                  spacing: 20,
                  runSpacing: 10,
                  children: gaiaUsageBars(usage),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A new account's name and folder (GAIA_HLD.md §6.1). A folder is fixed
/// once it's added: its sessions, and a Codex account's home, belong to
/// that login.
class _AddAccount extends StatefulWidget {
  const _AddAccount({
    required this.adapter,
    required this.taken,
    required this.onAdd,
  });

  final String adapter;
  final Set<String> taken;
  final Future<bool> Function(String label, String dir) onAdd;

  @override
  State<_AddAccount> createState() => _AddAccountState();
}

class _AddAccountState extends State<_AddAccount> {
  final _label = TextEditingController();
  final _dir = TextEditingController();

  @override
  void initState() {
    super.initState();
    _label.addListener(() => setState(() {}));
    _dir.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _label.dispose();
    _dir.dispose();
    super.dispose();
  }

  // Explorer's "Copy as path" wraps the path in quotes, which can't be part
  // of a Windows path.
  String get _folder => _dir.text.replaceAll('"', '').trim();

  bool get _valid =>
      _label.text.trim().isNotEmpty &&
      _folder.isNotEmpty &&
      !widget.taken.contains(_folder);

  Future<void> _add() async {
    if (!_valid) return;
    if (!await widget.onAdd(_label.text.trim(), _folder) || !mounted) return;
    _label.clear();
    _dir.clear();
  }

  @override
  Widget build(BuildContext context) {
    final codex = widget.adapter == kGaiaCodexAdapter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 150,
                child: GaiaPanelField(
                  controller: _label,
                  hintText: 'New account',
                  onSubmitted: _add,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GaiaPanelField(
                  controller: _dir,
                  hintText: codex
                      ? r'Folder, e.g. C:\Users\you\.codex-2'
                      : r'Folder, e.g. C:\Users\you\.claude-2',
                  onSubmitted: _add,
                ),
              ),
              const SizedBox(width: 8),
              GaiaButton(
                label: 'Add account',
                size: 32,
                onPressed: _valid ? _add : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          GaiaPanelNote(
            codex
                ? 'A folder is a CODEX_HOME holding a login, which Gaia copies '
                      'into a Codex home of its own. The first account is the '
                      'default. Synced to all your devices.'
                : "A folder is a CLAUDE_CONFIG_DIR, used on Gaia's runs only. "
                      'The first account is the default. Synced to all your '
                      'devices.',
          ),
        ],
      ),
    );
  }
}

/// One line of a checklist: ok (true), a blocker (false) or a warning
/// (null), with the command that fixes it shown copyable, or a button.
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.state,
    required this.label,
    this.fix,
    this.action,
  });

  final bool? state;
  final String label;
  final String? fix;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final (icon, color) = switch (state) {
      true => (
        Icons.check_circle_outline,
        Theme.of(context).colorScheme.primary,
      ),
      false => (Icons.highlight_off, kGaiaStatusRose),
      null => (
        Icons.error_outline,
        light ? kGaiaAstralGoldOnLight : kGaiaAstralGold,
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: GaiaType.row.copyWith(color: GaiaInk.dim)),
                if (action case final action?)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: action,
                  ),
                if (fix case final command?)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Flexible(
                          child: SelectableText(
                            command,
                            style: GaiaType.label.copyWith(
                              fontFamily: AppFonts.monoFamily,
                              color: GaiaInk.muted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        GaiaActionIcon(
                          label: 'Copy',
                          icon: Icons.copy,
                          compact: true,
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: command),
                            );
                            if (!context.mounted) return;
                            showGaiaToast(
                              context,
                              mark: GaiaToastMark.done,
                              title: 'Copied',
                              body: 'The command is on the clipboard.',
                            );
                          },
                        ),
                      ],
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
