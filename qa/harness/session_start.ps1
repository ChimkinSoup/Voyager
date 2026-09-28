# SESSION START: quit Voyager, sign out of whatever is signed in (Juno signs
# the real account back in between sessions), wipe local state, launch a
# debug run and sign a voyager-qa-* account in (-SignUp for a new one).
# A reused account's data comes back from its cloud copy by the startup pull.
param([Parameter(Mandatory)][string]$Email, [string]$Password = 'qavoyager2026', [switch]$SignUp)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $here 'reset.ps1')
& (Join-Path $here 'launch.ps1')
if ($LASTEXITCODE -ne 0) { throw 'launch failed' }
Start-Sleep -Seconds 5
& (Join-Path $here 'login.ps1') -Email $Email -Password $Password -SignUp:$SignUp
& (Join-Path $here 'guard.ps1')
