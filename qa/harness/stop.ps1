# Fully quits Voyager: every voyager.exe (debug run or the installed release)
# plus the `flutter run` tool process that launch.ps1 started. Leaves other
# Dart processes (e.g. the Dart language server) alone.
$ErrorActionPreference = 'Stop'
Get-Process voyager -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name = 'dart.exe'" |
  Where-Object { $_.CommandLine -match 'flutter_tools' -and $_.CommandLine -match '\srun\s' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
for ($i = 0; $i -lt 50 -and (Get-Process voyager -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
if (Get-Process voyager -ErrorAction SilentlyContinue) { throw 'voyager.exe is still running' }
Remove-Item (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'logs\vm_uri.txt') -ErrorAction SilentlyContinue
'stopped'
