# Wrapper for vm.dart that works from Windows PowerShell 5.1 (where a native
# command's stderr line becomes an error record). Compiles vm.dart to
# qa/logs/vm.exe on first use (and whenever vm.dart is newer), since each
# `dart run` costs several seconds. Usage: vm.ps1 [-Profile <name>] whoami | pid
#   | shot <png> | eval <lib> <expr> | find [query] | locate <n> <query> | field
#   (see vm.dart's header). -Profile (else $env:VOYAGER_QA_PROFILE) picks the
#   dev profile's VM service; see instance.ps1.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'instance.ps1')
$rest = @($args)
$name = ''
if ($rest.Count -ge 2 -and $rest[0] -eq '-Profile') { $name = $rest[1]; $rest = @($rest | Select-Object -Skip 2) }
$name = Resolve-QaProfile $name
Set-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$exe = 'qa\logs\vm.exe'
if (-not (Test-Path $exe) -or (Get-Item $exe).LastWriteTime -lt (Get-Item 'qa\harness\vm.dart').LastWriteTime) {
  $out = & dart compile exe qa/harness/vm.dart -o $exe 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { $out; exit $LASTEXITCODE }
}
# Set for vm.exe only: callers run this script in their own process, and a
# leftover value would point their next call at the wrong instance.
$saved = $env:VOYAGER_QA_PROFILE
$env:VOYAGER_QA_PROFILE = $name
try {
  & $exe @rest 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -ne '' }
} finally { $env:VOYAGER_QA_PROFILE = $saved }
exit $LASTEXITCODE
