# Multi-device plan §5: run one voy.ps1 steps file on profile qa and one on qb, released together.
#   together.ps1 -A <stepsA.txt> -B <stepsB.txt> [-LeadMs 8000]
# Each file gets an `at <T>` first step (T = now + LeadMs), runs in its own PowerShell
# process, and both outputs are printed when both finish.
param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B, [int]$LeadMs = 8000)
$ErrorActionPreference = 'Stop'
$h = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmp = Join-Path $env:TEMP 'voy-together'
New-Item -ItemType Directory -Force $tmp | Out-Null
$t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $LeadMs
$procs = @()
foreach ($pair in @(@('qa', $A), @('qb', $B))) {
  $f = Join-Path $tmp "$($pair[0]).txt"
  Set-Content -LiteralPath $f -Value (@("at $t") + (Get-Content -LiteralPath $pair[1])) -Encoding ascii
  $procs += Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $h 'voy.ps1'), '-Profile', $pair[0], 'run', $f `
    -RedirectStandardOutput (Join-Path $tmp "$($pair[0]).out") -RedirectStandardError (Join-Path $tmp "$($pair[0]).err") -NoNewWindow -PassThru
}
$procs | ForEach-Object { $_.WaitForExit() }
foreach ($p in 'qa', 'qb') {
  "== $p"
  Get-Content (Join-Path $tmp "$p.out")
  Get-Content (Join-Path $tmp "$p.err") -ErrorAction SilentlyContinue
}
