# The Claude Code contract check for Gaia (test/gaia_cli_contract_test.dart):
# runs Gaia's own CLI invocation against the installed Claude Code and says
# whether its output still parses, for every shape of turn Gaia relies on (a
# plain turn, a tool call, a second turn on one process, a resume after the
# process is killed, an unknown model).
#
# Run it whenever Claude Code updates. It makes a few real model calls on the
# subscription login, as Gaia does, so it's never part of `flutter test`.
# Raw output goes to qa/logs/gaia_cli/<version>/<scenario>.jsonl: the source
# for refreshing test/fixtures/gaia/claude_code/ (trim the init event and
# sanitise paths to C:\\gaia\\ws first, as the existing fixtures are).
#
# On a pass with an untested version, widen kClaudeCodeTestedVersions in
# lib/features/gaia/adapters/claude_code/claude_code_events.dart.
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repo
$env:GAIA_CLI_CHECK = '1'
try {
  $out = cmd /c 'flutter test test/gaia_cli_contract_test.dart --reporter expanded 2>&1'
  $code = $LASTEXITCODE
} finally { $env:GAIA_CLI_CHECK = $null }
$out | ForEach-Object { "$_" } |
  Where-Object { $_ -match 'GAIA-CLI|\[E\]|Expected:|Actual:|Which:|Reason:|exited|All tests passed|Some tests failed' }
$version = 'unknown'
$tested = $false
foreach ($line in $out) {
  if ("$line" -match 'GAIA-CLI version (\S+) (tested|untested)') { $version = $Matches[1]; $tested = $Matches[2] -eq 'tested' }
}
''
if ($code -eq 0 -and $tested) {
  "PASS: the contract holds on Claude Code $version, already in the tested range."
} elseif ($code -eq 0) {
  "PASS: the contract holds on Claude Code $version, which isn't in kClaudeCodeTestedVersions yet; widen the range in claude_code_events.dart."
} else {
  "FAIL: Gaia can't rely on Claude Code $version as it stands; see the failures above and the transcripts in qa\logs\gaia_cli\$version."
}
exit $code
