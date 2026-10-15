# FV-42: BUG-238 round. Creates journal entry fx-je-<N> on A (qa), types a synced
# sentence, then a tail and kills A inside the upload debounce; B (qb) appends twice;
# A relaunches. Prints A, B and the cloud.
param([int]$N, [string]$Uid = 'lffh4ISjyHhQUAxrhrp6FVoVRyl2')
$h = 'C:\Users\Juno\Code\Voyager\qa\harness'
Set-Location C:\Users\Juno\Code\Voyager
$id = "fx-je-$N"
Set-Content -Encoding ascii qa\steps\fv42-jeN.dart.txt "final now = DateTime.now().toUtc(); final en = JournalEntry(id: '$id', createdAt: now, updatedAt: now, version: 1, journalId: 'fx-j-def', title: 'FX $N', body: '', entryDate: DateTime.now()); await c.read(journalRepositoryProvider).upsertEntry(en); c.read(remoteSyncServiceProvider).pushJournalEntryNow(en); invalidateAllDataProvidersIn(c);"
& "$h\evalc.ps1" -Profile qa -Lib features/trash/trash_item_detail.dart -Tag "je$N" -BodyFile qa\steps\fv42-jeN.dart.txt | Out-Null
python "$h\wait_row.py" qb "select id from journal_entries_table where id='$id'" 30 | Out-Null
$sql = "select body from journal_entries_table where id='$id'"
foreach ($p in 'qa','qb') { & "$h\voy.ps1" -Profile $p do "key esc; wait 300; tap Journal; wait 1200; tap FX $N; wait 1200" | Out-Null }
& "$h\voy.ps1" -Profile qa do "click 1840 1500; wait 300; type A flushed.; wait 5000" | Out-Null
python "$h\wait_row.py" qb "$sql and body='A flushed.'" 30
& "$h\voy.ps1" -Profile qa do "type  A unflushed tail; wait 700" | Out-Null
& "$h\stop.ps1" -Profile qa | Out-Null
& "$h\voy.ps1" -Profile qb do "click 1840 1500; wait 300; key ctrl+end; type  B continues.; wait 2500; type  B more.; wait 4000" | Out-Null
"before relaunch:"; python qa\steps\md-q.py qa,qb $sql
& "$h\launch.ps1" -Profile qa | Out-Null
& "$h\voy.ps1" -Profile qa do "park" | Out-Null
python "$h\wait_row.py" qb "$sql and body like '%tail%'" 45
python qa\steps\md-textcmp.py $Uid journal_entries journal_entries_table $id
