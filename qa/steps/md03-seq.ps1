# MD-3.1: sequential alternations on one CRDT field open on both devices.
#   md03-seq.ps1 -Sql "<select body ... where id='x'>" -Rounds 10 [-Start 2] [-Tag J]
# Each round the writer (odd = qa, even = qb) clicks the field (BodyX/BodyY), Ctrl+End,
# types " <Tag><i>w words.", then waits for the receiver's DB row to hold it
# and reads the receiver's own editor (click + field) to show it on screen.
param([string]$Sql, [int]$Rounds = 10, [int]$Start = 1, [string]$Tag = 'J', [int]$BodyX = 1840, [int]$BodyY = 1500)
$h = 'C:\Users\Juno\Code\Voyager\qa\harness'
for ($i = $Start; $i -le $Rounds; $i++) {
  $w = if ($i % 2) { 'qa' } else { 'qb' }; $rcv = if ($i % 2) { 'qb' } else { 'qa' }
  $m = "$Tag$i$($w)x"
  $out = & "$h\voy.ps1" -Profile $w do "click $BodyX $BodyY; wait 250; key ctrl+end; type  $m words here."
  $rsql = $Sql.Replace('@M@', $m)
  $wr = python "$h\wait_row.py" $rcv $rsql 30
  $f = & "$h\voy.ps1" -Profile $rcv do "click $BodyX $BodyY; wait 300; field"
  $ok = ($f -join ' ') -like "*$m*"
  "round $i $w->$rcv : $($wr -join ' ') | editor has it: $ok"
}
