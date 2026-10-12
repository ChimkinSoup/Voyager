# SESSION START: wipe the QA instance's local state (quitting it and signing it
# out), launch a debug run and sign a voyager-qa-* account in (-SignUp for a
# new one). A reused account's data comes back from its cloud copy by the
# startup pull.
#
# Runs in dev profile 'qa' (DEV_PROFILE_HLD.md) by default: its own data,
# Firestore cache and sign-in beside Juno's normal install, which is never
# stopped, signed out or wiped. The exe is rebuilt first, so the session runs
# the working tree. -Profile default runs it in the normal instance as before
# (signs Juno out and wipes %APPDATA%\Voyager\voyager); that's needed only for
# what a profile leaves off: global hotkeys, Start with Windows, folder backups.
param([Parameter(Mandatory)][string]$Email, [string]$Password = 'qavoyager2026', [switch]$SignUp, [string]$Profile = 'qa')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'instance.ps1')
$inst = Get-QaInstance $Profile
$Profile = $inst.Arg
& (Join-Path $here 'reset.ps1') -Profile $Profile
if ($inst.Profile) { & (Join-Path $here 'launch.ps1') -Profile $Profile -Build }
else { & (Join-Path $here 'launch.ps1') -Profile $Profile }
if ($LASTEXITCODE -ne 0) { throw 'launch failed' }
Start-Sleep -Seconds 5
& (Join-Path $here 'login.ps1') -Email $Email -Password $Password -SignUp:$SignUp -Profile $Profile
& (Join-Path $here 'guard.ps1') -Profile $Profile
