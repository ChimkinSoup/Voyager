# MD-17.3: CPU of one profile's voyager.exe, sampled every -Every seconds for -Seconds.
#   md17-cpu.ps1 -Profile qb -Seconds 900 [-Every 5]
# Prints one line per sample: time, % of one core, % of all cores, working set MB.
param([Parameter(Mandatory)][string]$Profile, [int]$Seconds = 900, [int]$Every = 5)
$pidFile = "C:\Users\Juno\Code\Voyager\qa\logs\pid_$Profile.txt"
$procId = [int]((Get-Content $pidFile -TotalCount 1).Split(' ')[0])
$proc = Get-Process -Id $procId
$cores = [Environment]::ProcessorCount
$end = (Get-Date).AddSeconds($Seconds)
$prevCpu = $proc.TotalProcessorTime.TotalSeconds; $prevT = Get-Date
while ((Get-Date) -lt $end) {
    Start-Sleep -Seconds $Every
    $proc.Refresh()
    $cpu = $proc.TotalProcessorTime.TotalSeconds; $t = Get-Date
    $one = 100 * ($cpu - $prevCpu) / ($t - $prevT).TotalSeconds
    "{0} cpu1={1:N1}% cpuAll={2:N1}% ws={3:N0}MB" -f $t.ToString('HH:mm:ss'), $one, ($one / $cores), ($proc.WorkingSet64 / 1MB)
    $prevCpu = $cpu; $prevT = $t
}
