# MD-6: the on-screen order of texts matching -Q on both profiles (vm find, top to bottom).
#   md06-scr.ps1 -Q "MD6 task" [-N 6]
param([Parameter(Mandatory)][string]$Q, [int]$N = 6)
foreach ($p in 'qa', 'qb') {
    $rows = & C:\Users\Juno\Code\Voyager\qa\harness\vm.ps1 -Profile $p find $Q 2>&1 | Where-Object { "$_" -match "`t" }
    $rows = $rows | Sort-Object { [int](("$_" -split "`t")[1] -split ',')[1] }, { [int](("$_" -split "`t")[1] -split ',')[0] }
    "$p screen: " + (($rows | Select-Object -First $N | ForEach-Object { ("$_" -split "`t")[-1] }) -join ', ')
}
