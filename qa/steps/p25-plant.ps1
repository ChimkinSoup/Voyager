# Phase 25: plant backdated automatic backups for the retention check. Run with Voyager stopped.
$d = "$env:APPDATA\Voyager\voyager\backups"
$src = Get-ChildItem "$d\voyager_auto_*.zip" | Sort-Object Name | Select-Object -Last 1
if (-not $src) { throw "no auto backup to copy" }
$tmp = "$env:TEMP\p25-auto-src.zip"
Copy-Item $src.FullName $tmp -Force
Remove-Item $src.FullName
$today = Get-Date '2026-10-03'
foreach ($age in 1,2,3,4,5,6,8,9,12,25,29,31,40,60) {
  $n = 'voyager_auto_' + $today.AddDays(-$age).ToString('yyyy-MM-dd') + '_09-00-00-0400.zip'
  Copy-Item $tmp "$d\$n"
}
Copy-Item $tmp "$d\voyager_auto_2026-10-10_09-00-00-0400.zip"
Copy-Item 'C:\Users\Juno\Code\Voyager\qa\exports\p25-truncated.zip' "$d\voyager_auto_2026-09-18_09-00-00-0400.zip"
Copy-Item 'C:\Users\Juno\Code\Voyager\qa\exports\p25-v3.zip' "$d\voyager_auto_2026-09-17_09-00-00-0400.zip"
Copy-Item $tmp "$d\voyager_backup_manual.zip"
Set-Content "$d\notes.txt" 'user file' -Encoding ascii
Copy-Item $tmp "$d\voyager_prerestore_2026-09-25_09-00-00-0400.zip"
Set-Content "$d\voyager_prerestore_2026-09-25_09-00-00-0400.created.json" '{}' -Encoding ascii
Copy-Item $tmp "$d\voyager_prerestore_2026-09-27_09-00-00-0400.zip"
Get-ChildItem $d | Sort-Object Name | ForEach-Object { $_.Name }
