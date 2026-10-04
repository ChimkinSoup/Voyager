# Eval a body file in the running app (c = ProviderContainer), wait for SEED-OK/ERR <tag>, print matching run-log lines.
param([Parameter(Mandatory)][string]$BodyFile, [string]$Lib = 'features/trash/trash_item_detail.dart', [string]$Tag = ('t' + (Get-Random)), [string]$Grep = '', [int]$TimeoutSec = 120)
$ErrorActionPreference = 'Continue'
$repo = 'C:\Users\Juno\Code\Voyager'
$vm = if ($env:VM_EXE) { $env:VM_EXE } else { throw 'set VM_EXE to a compiled vm.dart: dart compile exe qa/harness/vm.dart -o <path>' }
$log = Get-ChildItem (Join-Path $repo 'qa\logs\run-*.log') | Sort-Object LastWriteTime | Select-Object -Last 1
$start = (Get-Content -LiteralPath $log.FullName).Count
$body = (Get-Content -Raw -LiteralPath $BodyFile) -replace "`r?`n", ' '
$walk = "Element? e; void v(Element x) { if (e != null) return; if (x.widget.runtimeType.toString().startsWith('MaterialApp')) { e = x; } else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); final c = ProviderScope.containerOf(e!, listen: false);"
$expr = "Future(() async { try { $walk $body debugPrint('SEED-OK $Tag'); } catch (err, st) { debugPrint('SEED-ERR $Tag ' + err.toString()); } })"
Set-Location $repo
$out = & $vm eval $Lib $expr 2>&1 | ForEach-Object { "$_" }
$out | Select-Object -First 15
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while (-not $done -and (Get-Date) -lt $deadline) {
  $lines = Get-Content -LiteralPath $log.FullName | Select-Object -Skip $start
  if ($lines | Where-Object { $_ -match "SEED-(OK|ERR) $Tag" }) { $done = $true } else { [System.Threading.Thread]::Sleep(1000) }
}
$lines = Get-Content -LiteralPath $log.FullName | Select-Object -Skip $start
if ($Grep) { $lines | Where-Object { $_ -match $Grep -or $_ -match "SEED-" } | Select-Object -Last 60 } else { $lines | Where-Object { $_ -match "SEED-|P26" } | Select-Object -Last 60 }
if (-not $done) { 'TIMEOUT waiting for ' + $Tag }
