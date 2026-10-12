# Runs Dart statements inside the running app with `c` = the app's
# ProviderContainer (found from the widget tree), for seeding test data through
# the app's own repositories and upload calls. Added in the FV session
# (2026-09-30); seed bodies: qa/steps/fv-seed*.dart.txt.
#
#   evalc.ps1 -Lib features/trash/trash_item_detail.dart -Tag seed1 -BodyFile qa\steps\fv-seed1.dart.txt
#
# -Lib must import flutter widgets, flutter_riverpod, app/providers.dart and
# every model the body names (trash_item_detail.dart imports nearly all of
# them). The body runs inside Future(() async { ... }), so the result is not
# returned: it goes to the flutter run log as "SEED-OK <tag>" or
# "SEED-ERR <tag> <error>". Use debugPrint in the body to report values.
# Guard first: only ever run this against a voyager-qa-* account.
# -Profile (else $env:VOYAGER_QA_PROFILE) targets a dev profile; its output
# then goes to launch.ps1's run-<name>-*.exe.log.
param([Parameter(Mandatory)][string]$Lib, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$BodyFile, [string]$VmExe, [string]$Profile)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'instance.ps1')
$inst = Get-QaInstance $Profile
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$body = (Get-Content -Raw -LiteralPath $BodyFile) -replace "`r?`n", ' '
$walk = "Element? e; void v(Element x) { if (e != null) return; if (x.widget.runtimeType.toString().startsWith('MaterialApp')) { e = x; } else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); final c = ProviderScope.containerOf(e!, listen: false);"
$expr = "Future(() async { try { $walk $body debugPrint('SEED-OK $Tag'); } catch (err) { debugPrint('SEED-ERR $Tag ' + err.toString()); } })"
Set-Location $repo
if ($VmExe) {
  $saved = $env:VOYAGER_QA_PROFILE
  $env:VOYAGER_QA_PROFILE = $inst.Profile
  try { & $VmExe eval $Lib $expr } finally { $env:VOYAGER_QA_PROFILE = $saved }
} else { & (Join-Path $repo 'qa\harness\vm.ps1') -Profile $inst.Arg eval $Lib $expr }
