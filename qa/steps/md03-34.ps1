# MD-3.4: open-editor receive. Both have the record open (opened by Open, a voy step list).
#   md03-34.ps1 -Open "<steps>" -X <fieldX> -Y <fieldY> -Sql "<select text ... where id='x'>" -Tag J
# Part 1: B unfocused, A types; B's shot. B then types; text on both.
# Part 2: B's caret mid-text (after the 6th char); A inserts at the start, then at the end; B's selection after each.
param([string]$Open, [int]$X, [int]$Y, [string]$Sql, [string]$Tag, [string]$Col = 'body')
$h = 'C:\Users\Juno\Code\Voyager\qa\harness'
$q = 'C:\Users\Juno\Code\Voyager\qa\steps\md-q.py'
function W($p, $cond) { python "$h\wait_row.py" $p "$Sql and $Col $cond" 30 }
& "$h\voy.ps1" -Profile qa do $Open | Out-Null
& "$h\voy.ps1" -Profile qb do $Open | Out-Null
& "$h\voy.ps1" -Profile qa do "click $X $Y; wait 300; key ctrl+end; type Hello from A unfocused."
"B unfocused receive: " + (W 'qb' "like '%Hello from A unfocused.%'")
Start-Sleep -Milliseconds 800
& "$h\voy.ps1" -Profile qb do "shot md03-34-qb-$Tag-unfocused"
& "$h\voy.ps1" -Profile qb do "click $X $Y; wait 300; key ctrl+end; type  B reply."
"A receives B: " + (W 'qa' "like '%Hello from A unfocused. B reply.%'")
# Part 2: caret mid-text on B
& "$h\voy.ps1" -Profile qb do "click $X $Y; wait 300; key ctrl+home; key right; key right; key right; key right; key right; key right; field"
& "$h\voy.ps1" -Profile qa do "click $X $Y; wait 300; key ctrl+home; type PRE-"
"B gets PRE: " + (W 'qb' "like 'PRE-%'")
Start-Sleep -Milliseconds 800
"B caret after insert before it (expect 10,10):"; & "$h\voy.ps1" -Profile qb do "field"
& "$h\voy.ps1" -Profile qa do "key ctrl+end; type  POST"
"B gets POST: " + (W 'qb' "like '% POST'")
Start-Sleep -Milliseconds 800
"B caret after insert after it (expect 10,10):"; & "$h\voy.ps1" -Profile qb do "field"
& "$h\voy.ps1" -Profile qb do "type X; wait 4000"
"A gets B's X at the caret: " + (W 'qa' "like 'PRE-Hello Xfrom%'")
python $q 'qa,qb' $Sql
& "$h\voy.ps1" -Profile qb do "shot md03-34-qb-$Tag-end"
