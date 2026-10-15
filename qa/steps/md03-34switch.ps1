# MD-3.4 follow-up (BUG-236 shape) on any editor: A types in record 1, B appends there,
# A receives while focused and types again, then A selects record 2 and types.
#   md03-34switch.ps1 -Nav "<voy steps to show the list>" -One "<label 1>" -Two "<label 2>" -X <x> -Y <y> -Sql1 "<select text where id=1>" -Sql2 "<... id=2>" -Col body
param([string]$Nav, [string]$One, [string]$Two, [int]$X, [int]$Y, [string]$Sql1, [string]$Sql2, [string]$Col = 'body')
$q = 'C:\Users\Juno\Code\Voyager\qa\steps\md-q.py'
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 -Profile qa do "$Nav; tap $One; wait 800; click $X $Y; wait 300; type FIRST by A.; wait 4000"
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 -Profile qb do "$Nav; tap $One; wait 1000; click $X $Y; wait 300; key ctrl+end; type  then B.; wait 500"
python C:\Users\Juno\Code\Voyager\qa\harness\wait_row.py qa "$Sql1 and $Col like '%then B.'" 30
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 -Profile qa do "wait 1500; key ctrl+end; type  again; wait 4000; tap $Two; wait 1200; click $X $Y; wait 300; field; type SECOND.; wait 4000; field"
python $q 'qa,qb' $Sql1
python $q 'qa,qb' $Sql2
