# Wrapper for vm.dart that works from Windows PowerShell 5.1 (where a native
# command's stderr line becomes an error record). Compiles vm.dart to
# qa/logs/vm.exe on first use (and whenever vm.dart is newer), since each
# `dart run` costs several seconds. Usage: vm.ps1 whoami | shot <png> | eval <lib> <expr>
#   | find [query] | locate <n> <query> | field   (see vm.dart's header)
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))
$exe = 'qa\logs\vm.exe'
if (-not (Test-Path $exe) -or (Get-Item $exe).LastWriteTime -lt (Get-Item 'qa\harness\vm.dart').LastWriteTime) {
  $out = & dart compile exe qa/harness/vm.dart -o $exe 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { $out; exit $LASTEXITCODE }
}
& $exe @args 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -ne '' }
exit $LASTEXITCODE
