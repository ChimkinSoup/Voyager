# Signs a voyager-qa-* account in (or up, with -SignUp) from the login page,
# then verifies the signed-in account over the VM service. Assumes the app
# was just launched by launch.ps1 onto the login page, maximized (client
# 2880x1800 physical px - the coordinates below are for that size).
param([Parameter(Mandatory)][string]$Email, [string]$Password = 'qavoyager2026', [switch]$SignUp)
$ErrorActionPreference = 'Stop'
if ($Email -notmatch '^voyager-qa-\d+@example\.com$') { throw "refusing: $Email is not a voyager-qa-NNN@example.com account" }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$voy = Join-Path $here 'voy.ps1'
Set-Location $repo
# Login page: Email field y=727, Password y=847, "Create account" y=1191.
# After switching to sign-up the card re-centres: Email y=783, Password y=903.
$emailY = 727; $pwY = 847
$steps = @('activate', 'maximize', 'wait 600')
if ($SignUp) { $steps += @('click 1440 1191', 'wait 800'); $emailY = 783; $pwY = 903 }
$steps += @("click 1440 $emailY", 'key ctrl+a', "type $Email", "click 1440 $pwY", 'key ctrl+a', "type $Password",
  'shot login-filled', 'key enter', 'wait 8000', 'shot login-after')
& $voy do ($steps -join ';')
& (Join-Path $here 'vm.ps1') whoami
if ($LASTEXITCODE -eq 3) { throw 'STOP: signed into a non-QA account' }
