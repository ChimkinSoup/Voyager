# Copies the phone app's database with its -wal and -shm (a copy without the
# WAL misses recent writes) through run-as into qa/logs/phone_db/, and prints
# a read-only sqlite URI for it. Read-only: never write the copy back.
#   phone_db.ps1            -> file:C:/.../qa/logs/phone_db/voyager.sqlite?mode=ro
#   python -c "import sqlite3; c=sqlite3.connect('<uri>', uri=True); ..."
$ErrorActionPreference = 'Stop'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$env:ANDROID_SERIAL = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'phone_serial.txt') -TotalCount 1).Trim()
$package = 'com.example.voyager'
$out = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\phone_db'
New-Item -ItemType Directory -Force $out | Out-Null
foreach ($name in 'voyager.sqlite', 'voyager.sqlite-wal', 'voyager.sqlite-shm') {
  $dest = Join-Path $out $name
  Remove-Item -LiteralPath $dest -ErrorAction SilentlyContinue
  # exec-out exits 0 even when cat fails (and its error would become the file).
  & $adb shell "run-as $package test -f files/$name"
  if ($LASTEXITCODE -ne 0) { continue }
  $p = Start-Process -FilePath $adb -ArgumentList 'exec-out', 'run-as', $package, 'cat', "files/$name" -NoNewWindow -Wait -PassThru -RedirectStandardOutput $dest
  if ($p.ExitCode -ne 0) { throw "pulling $name failed" }
}
if (-not (Test-Path -LiteralPath (Join-Path $out 'voyager.sqlite'))) { throw 'no files/voyager.sqlite on the phone' }
"file:$((Join-Path $out 'voyager.sqlite') -replace '\\', '/')?mode=ro"
