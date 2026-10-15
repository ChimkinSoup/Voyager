# FV-42: BUG-239 rounds. Creates dream fx-dr-<n> on A, opens its note on both, types together.
param([int[]]$Rounds)
$h = 'C:\Users\Juno\Code\Voyager\qa\harness'
Set-Location C:\Users\Juno\Code\Voyager
foreach ($n in $Rounds) {
  $id = "fx-dr-$n"
  Set-Content -Encoding ascii qa\steps\fv42-dreamN.dart.txt "final now = DateTime.now().toUtc(); final d = DreamEntry(id: '$id', createdAt: now, updatedAt: now, version: 1, title: 'FX dream $n', body: '', entryDate: DateTime.now(), notes: '', tags: const []); await c.read(dreamRepositoryProvider).upsertEntry(d); c.read(remoteSyncServiceProvider).pushDreamEntryNow(d); invalidateAllDataProvidersIn(c);"
  & "$h\evalc.ps1" -Profile qa -Lib features/trash/trash_item_detail.dart -Tag "d$n" -BodyFile qa\steps\fv42-dreamN.dart.txt | Out-Null
  python "$h\wait_row.py" qb "select id from dream_entries_table where id='$id'" 30 | Out-Null
  foreach ($p in 'qa','qb') { & "$h\voy.ps1" -Profile $p do "key esc; wait 300; tap FX dream $n; wait 1200; click 2782 1704; wait 1000" | Out-Null }
  & "$h\together.ps1" -A qa\steps\md03-318-a.txt -B qa\steps\md03-318-b.txt | Out-Null
  Start-Sleep 10
  "round $n"
  python qa\steps\md-textcmp.py lffh4ISjyHhQUAxrhrp6FVoVRyl2 dream_entries dream_entries_table $id notes
  python qa\steps\md-q.py qa,qb "select version, updated_at from dream_entries_table where id='$id'"
}
