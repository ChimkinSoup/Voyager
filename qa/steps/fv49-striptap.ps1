# FV-49 (BUG-288): from the top of a series detail, click each strip mark
# "<label> · done" and report whether <date> (the tile's date) is then on screen.
#   fv49-striptap.ps1 -Pairs 'October 2023=Oct 15, 2023', ...
param([string[]]$Pairs)
$env:VOYAGER_QA_PROFILE = 'qa'
$voy = 'C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1'
$dot = [string][char]0xB7
foreach ($pair in $Pairs) {
  $label, $date = $pair -split '=', 2
  & $voy do "wheel 1500 900 100; wait 400; wheel 1500 900 100; wait 400; wheel 1500 900 100; wait 600; tap tip:$label $dot done; wait 2500" | Out-Null
  $found = & $voy do "find $date"
  $first = & $voy do 'find' | Select-String -Pattern '^text\s+\d+,(\d+)\s+\S+\s+(\w{3} \d+, \d{4}|\d{4}|\w+ \d{4})$' | Select-Object -First 2 | ForEach-Object Line
  "--- $label -> $date : " + $(if ($found) { "ON SCREEN $found" } else { 'NOT ON SCREEN' })
  $first
}
