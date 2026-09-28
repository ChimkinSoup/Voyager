# Wrapper for vm.dart that works from Windows PowerShell 5.1 (where a native
# command's stderr line becomes an error record) and drops dart's
# "Running build hooks..." noise. Usage: vm.ps1 whoami | shot <png> | eval <lib> <expr>
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))
& dart run qa/harness/vm.dart @args 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'Running build hooks' -and $_ -ne '' }
exit $LASTEXITCODE
