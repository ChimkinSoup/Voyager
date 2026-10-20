# Phase 28A: relaunch profile qa with a fake local clock that reads about
# -Target (default 23:58:00) once the launch is done (~-LeadS seconds).
# POSIX TZ "QQQ<X>" puts local at UTC - X, plus 1 h for the inherited DST rule
# (memory: fake-clock-via-tz).
param([string]$Target = '23:58:00', [int]$LeadS = 70)
$utc = (Get-Date).ToUniversalTime().AddSeconds($LeadS)
$t = [TimeSpan]::Parse($Target)
$off = $t - $utc.TimeOfDay
if ($off.TotalHours -gt 12) { $off = $off - [TimeSpan]::FromDays(1) }
if ($off.TotalHours -lt -12) { $off = $off + [TimeSpan]::FromDays(1) }
$x = [TimeSpan]::FromHours(1) - $off
$sign = if ($x.TotalMinutes -lt 0) { '-' } else { '' }
$ax = $x.Duration()
$tz = 'QQQ{0}{1}:{2:00}:{3:00}' -f $sign, [int][Math]::Floor($ax.TotalHours), $ax.Minutes, $ax.Seconds
"TZ=$tz (offset from UTC {0})" -f $off
$env:VOYAGER_QA_PROFILE = 'qa'
& C:\Users\Juno\Code\Voyager\qa\harness\stop.ps1 -Profile qa
$env:TZ = $tz
& C:\Users\Juno\Code\Voyager\qa\harness\launch.ps1 -Profile qa 2>&1 | Select-Object -Last 2
Remove-Item Env:TZ
& C:\Users\Juno\Code\Voyager\qa\harness\vm.ps1 -Profile qa eval core/dev/perf_stall_logger.dart "DateTime.now().toString()"
