# Phase 28A: run voy.ps1 steps on profile qa, then print the focused node.
param([string]$Steps)
$env:VOYAGER_QA_PROFILE = 'qa'
if ($Steps) { & C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do $Steps }
& C:\Users\Juno\Code\Voyager\qa\harness\vm.ps1 -Profile qa eval features/shell/app_shell.dart "FocusManager.instance.primaryFocus?.toStringShort() ?? 'none'"
