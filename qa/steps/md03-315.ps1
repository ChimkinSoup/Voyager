# MD-3.15: both Force offline, both edit the same dream body (different and overlapping places), reconnect First then the other.
param([string]$Item, [string]$Id, [string]$First = 'qa')
$h = 'C:\Users\Juno\Code\Voyager\qa\harness'; $s = 'C:\Users\Juno\Code\Voyager\qa\steps'
$Second = if ($First -eq 'qa') { 'qb' } else { 'qa' }
$sql = "select body from dream_entries_table where id='$Id'"
foreach ($p in 'qa', 'qb') { & "$h\voy.ps1" -Profile $p do "click 88 418; wait 800; wheel 460 900 -25; wait 500; tap $Item; wait 800" }
& "$h\voy.ps1" -Profile qa do "click 2000 1300; wait 300; type BASE MIDDLE END"
python "$h\wait_row.py" qb "$sql and body='BASE MIDDLE END'" 30
foreach ($p in 'qa', 'qb') { & "$h\evalc.ps1" -Profile $p -Lib features/dev/dev_page.dart -Tag off -BodyFile "$s\md-offline-on.dart.txt" | Out-Null }
# A: start + after "BASE "; B: end + after "BASE "
& "$h\voy.ps1" -Profile qa do "click 2000 1300; wait 300; key ctrl+home; type A1-; key right; key right; key right; key right; key right; type aaa; wait 5000"
& "$h\voy.ps1" -Profile qb do "click 2000 1300; wait 300; key ctrl+end; type -B1; key ctrl+home; key right; key right; key right; key right; key right; type bbb; wait 5000"
python "$s\md-q.py" 'qa,qb' $sql
& "$h\evalc.ps1" -Profile $First -Lib features/dev/dev_page.dart -Tag on -BodyFile "$s\md-offline-off.dart.txt" | Out-Null
Start-Sleep -Seconds 8
& "$h\evalc.ps1" -Profile $Second -Lib features/dev/dev_page.dart -Tag on -BodyFile "$s\md-offline-off.dart.txt" | Out-Null
python "$h\wait_row.py" $First "$sql and body like '%-B1%' and body like 'A1-%'" 60
python "$h\wait_row.py" $Second "$sql and body like '%-B1%' and body like 'A1-%'" 60
Start-Sleep -Seconds 5
python "$s\md-textcmp.py" Fv8tvOf7GfTxCX6m8U34mcQCdUb2 dream_entries dream_entries_table $Id
python "$s\md-outbox.py"
