# MD-5: visit each page on one instance and list the on-screen (hit-testable) texts that
# mention a seed set: "MD5 ... <set>" titles plus the search hit for quokka<set>.
#   md05-ui.ps1 -Profile qb -Set a [-Shots md05-51-qb-a-gone]
param([Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Set, [string]$Shots)
$voy = 'C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1'
$vm = 'C:\Users\Juno\Code\Voyager\qa\harness\vm.ps1'
$pages = 'Journal', 'Dreams', 'To-Do', 'Calendar', 'Analytics', 'Finance', 'LeetCode', 'Rankings', 'Study', 'Workout'
$pat = "MD5 .*\b$Set[12]?\b|quokka$Set"
foreach ($p in $pages) {
    $wh = if ($p -in 'Study', 'Workout') { 'wheel 88 1300 -10' } else { 'wheel 88 1300 10' }
    $steps = "$wh; wait 300; tap $p; wait 1500"
    if ($Shots) { $steps += "; shot $Shots-$($p.ToLower())" }
    & $voy -Profile $Profile do $steps | Out-Null
    $hits = & $vm -Profile $Profile find 'MD5' | Select-String -Pattern $pat
    "PAGE $p : $(@($hits).Count) hit(s)"
    $hits | ForEach-Object { "    $($_.Line.Trim())" }
}
# Search page: type the set's body word.
& $voy -Profile $Profile do "wheel 88 1300 10; wait 300; tap Search; wait 1000; key ctrl+a; type quokka$Set; wait 1500" | Out-Null
$hits = & $vm -Profile $Profile find 'quokka' | Select-String -Pattern "quokka$Set"
"PAGE Search(quokka$Set) : $(@($hits).Count) hit(s)"
$hits | ForEach-Object { "    $($_.Line.Trim())" }
if ($Shots) { & $voy -Profile $Profile do "shot $Shots-search" | Out-Null }
