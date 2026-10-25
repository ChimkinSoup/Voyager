import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// A CLI an adapter drives: its name, how to read its version, and the
/// versions its adapter is tested against (§5.1).
typedef GaiaCli = ({
  String name,
  Future<GaiaCliVersion?> Function() version,
  (GaiaCliVersion, GaiaCliVersion) tested,
});

/// By adapter id.
final Map<String, GaiaCli> kGaiaClis = {
  kGaiaClaudeCodeAdapter: (
    name: 'Claude Code',
    version: claudeCodeVersion,
    tested: kClaudeCodeTestedVersions,
  ),
  kGaiaCodexAdapter: (
    name: 'Codex',
    version: codexVersion,
    tested: kCodexTestedVersions,
  ),
};
