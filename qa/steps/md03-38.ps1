# MD-3.8: B opens a snapshot-only record (seed-only session) and types nothing; A types; then B types.
param([string]$Nav, [string]$Item, [int]$X, [int]$Y, [string]$Sql, [string]$Col = 'body', [string]$Tag)
$h = 'C:\Users\Juno\Code\Voyager\qa\harness'
& "$h\voy.ps1" -Profile qb do "$Nav; tap $Item; wait 1500"
& "$h\voy.ps1" -Profile qa do "$Nav; tap $Item; wait 1000; click $X $Y; wait 300; key ctrl+end; type  A typed."
"B row: " + (python "$h\wait_row.py" qb "$Sql and $Col like '%A typed.'" 30)
Start-Sleep -Milliseconds 1000
& "$h\voy.ps1" -Profile qb do "shot md03-38-qb-$Tag-recv; click $X $Y; wait 300; field; key ctrl+end; type  B typed.; wait 500"
"A row: " + (python "$h\wait_row.py" qa "$Sql and $Col like '%B typed.'" 30)
Start-Sleep -Seconds 3
python C:\Users\Juno\Code\Voyager\qa\steps\md-q.py 'qa,qb' $Sql
