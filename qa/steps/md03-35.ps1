# MD-3.5: B Force offline types a sentence; A edits the same text online; B reconnects. Both must survive.
#   md03-35.ps1 -Nav "<voy steps>" -Item "<label>" -X <x> -Y <y> -Sql "<select text where id=...>" -Col body -Tag je08
param([string]$Nav, [string]$Item, [int]$X, [int]$Y, [string]$Sql, [string]$Col = 'body', [string]$Tag)
$h = 'C:\Users\Juno\Code\Voyager\qa\harness'; $s = 'C:\Users\Juno\Code\Voyager\qa\steps'
& "$h\voy.ps1" -Profile qa do "$Nav; tap $Item; wait 800; click $X $Y; wait 300; type BASE text."
& "$h\voy.ps1" -Profile qb do "$Nav; tap $Item; wait 800"
python "$h\wait_row.py" qb "$Sql and $Col = 'BASE text.'" 30
& "$h\evalc.ps1" -Profile qb -Lib features/dev/dev_page.dart -Tag off -BodyFile "$s\md-offline-on.dart.txt" | Out-Null
& "$h\voy.ps1" -Profile qb do "click $X $Y; wait 300; key ctrl+end; type  B offline sentence.; wait 6000; field"
"B row: " + (python "$h\wait_row.py" qb "$Sql and $Col like '%B offline sentence.'" 20)
python "$s\md-outbox.py"
& "$h\voy.ps1" -Profile qa do "click $X $Y; wait 300; key ctrl+home; type A online first-; wait 6000; field"
"cloud/A has A's edit, B not: " + (python "$h\wait_row.py" qa "$Sql and $Col like 'A online first-BASE text.'" 20)
& "$h\evalc.ps1" -Profile qb -Lib features/dev/dev_page.dart -Tag on -BodyFile "$s\md-offline-off.dart.txt" | Out-Null
"A gets B's sentence: " + (python "$h\wait_row.py" qa "$Sql and $Col like '%B offline sentence.%'" 90)
"B gets A's edit: " + (python "$h\wait_row.py" qb "$Sql and $Col like 'A online first-%'" 90)
Start-Sleep -Seconds 5
python "$s\md-q.py" 'qa,qb' $Sql
python "$s\md-outbox.py"
& "$h\voy.ps1" -Profile qb do "shot md03-35-qb-$Tag"
