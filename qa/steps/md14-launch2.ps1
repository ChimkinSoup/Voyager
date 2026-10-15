# MD-14.1: launch profiles qa and qb at the same instant (two jobs released
# by one timestamp, as together.ps1 does for voy.ps1). Both must be stopped
# first (stop.ps1 -Profile qa / -Profile qb). Prints each launch's output and
# the release time. Usage: md14-launch2.ps1 [-LeadMs 3000]
param([int]$LeadMs = 3000)
$h = Join-Path (Split-Path -Parent $PSScriptRoot) 'harness'
$at = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() + $LeadMs
$jobs = foreach ($p in 'qa', 'qb') {
  Start-Job -ArgumentList $h, $p, $at -ScriptBlock {
    param($h, $p, $at)
    while ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() -lt $at) { Start-Sleep -Milliseconds 5 }
    "$p released $([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $at) ms after $at"
    & (Join-Path $h 'launch.ps1') -Profile $p 2>&1 | ForEach-Object { "$p | $_" }
  }
}
$jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
