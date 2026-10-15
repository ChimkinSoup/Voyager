# FV-44 BUG-259: relaunch B (weekly full pull) while A saves a task and a journal
# entry every 1.2 s, $Rounds times; then count B's Riverpod scheduler assertions.
param([int]$Rounds = 4)
Set-Location C:\Users\Juno\Code\Voyager
$log = Join-Path $env:APPDATA 'Voyager\voyager-profile-qb\logs\voyager_errors.log'
for ($i = 1; $i -le $Rounds; $i++) {
  $env:VOYAGER_QA_PROFILE = 'qb'
  & .\qa\harness\stop.ps1 -Profile qb | Out-Null
  python qa/steps/md10-age-wm.py qb 8 | Out-Null
  $loop = Start-Process python -ArgumentList 'qa/steps/md4pair.py', 'features/trash/trash_item_detail.dart', 'qa/steps/md10-106-loop.dart.txt', '--tag', "fv44w$i", '--only', 'qa' -NoNewWindow -PassThru
  & .\qa\harness\launch.ps1 -Profile qb | Out-Null
  & .\qa\harness\voy.ps1 do 'park' | Out-Null
  $loop.WaitForExit()
  Start-Sleep 5
  "round $i done $(Get-Date -Format T)"
}
"Only-one-task lines: $((Select-String -Path $log -Pattern 'Only one task' -ErrorAction SilentlyContinue).Count)"
"weather warm-up errors: $((Select-String -Path $log -Pattern 'warming up weather' -ErrorAction SilentlyContinue).Count)"
"ERROR lines: $((Select-String -Path $log -Pattern 'ERROR' -ErrorAction SilentlyContinue).Count)"
