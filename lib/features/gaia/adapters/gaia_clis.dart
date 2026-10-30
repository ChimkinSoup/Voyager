import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// A CLI an adapter drives: its name, how to read its version, the
/// versions its adapter is tested against (§5.1), and the host its runs
/// talk to, which the header's offline icon probes.
typedef GaiaCli = ({
  String name,
  String apiHost,
  Future<GaiaCliVersion?> Function() version,
  (GaiaCliVersion, GaiaCliVersion) tested,
});

/// By adapter id.
final Map<String, GaiaCli> kGaiaClis = {
  kGaiaClaudeCodeAdapter: (
    name: 'Claude Code',
    apiHost: 'api.anthropic.com',
    version: claudeCodeVersion,
    tested: kClaudeCodeTestedVersions,
  ),
  kGaiaCodexAdapter: (
    name: 'Codex',
    // Signed in with ChatGPT; an API key would go to api.openai.com.
    apiHost: 'chatgpt.com',
    version: codexVersion,
    tested: kCodexTestedVersions,
  ),
};
