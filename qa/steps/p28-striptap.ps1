# Phase 28A: from the top of a series detail, click each named strip mark
# (period label; " . done" appended) and print the first period labels then in view.
param([string[]]$Marks)
$env:VOYAGER_QA_PROFILE = 'qa'
$voy = 'C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1'
$re = '^text\s+\d+,(\d+)\s+\S+\s+((Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\S*|Week of|Mon|Tue|Wed|Thu|Fri|Sat|Sun).* \d{4}$'
$dot = [string][char]0xB7
foreach ($p in $Marks) {
  $m = "$p $dot done"
  & C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do "wheel 1500 900 100; wait 400; wheel 1500 900 100; wait 400; wheel 1500 900 100; wait 600; tap tip:$m; wait 1500" | Out-Null
  "--- clicked $m"
  & C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do 'find' | Select-String -Pattern $re | Select-Object -First 2 | ForEach-Object Line
}
