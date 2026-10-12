# Signs a voyager-qa-* account in (or up, with -SignUp) from the login page,
# then verifies the signed-in account over the VM service. Assumes the app
# was just launched by launch.ps1 onto the login page. Runs in voy.ps1's
# background mode: `park` moves the window off-screen with a 2880x1800 client
# (the maximized size the coordinates below are for). -Profile (else
# $env:VOYAGER_QA_PROFILE) signs that dev profile in.
#
# Each field is typed with real keys, then read back over the VM service
# (`vm.ps1 field`) and retyped if it came out wrong: posted input can drop a
# key or a modifier. A field is emptied over the VM service, not with Ctrl+A,
# which is one of the keys that goes missing.
param([Parameter(Mandatory)][string]$Email, [string]$Password = 'qavoyager2026', [switch]$SignUp, [string]$Profile)
$ErrorActionPreference = 'Stop'
if ($Email -notmatch '^voyager-qa-\d+@example\.com$') { throw "refusing: $Email is not a voyager-qa-NNN@example.com account" }
$here = $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path $here 'instance.ps1')
$Profile = (Get-QaInstance $Profile).Arg
$voy = Join-Path $here 'voy.ps1'
$vm = Join-Path $here 'vm.ps1'
Set-Location $repo

# The focused field's text, or $null when no text field has focus.
function Get-FieldText {
  $out = @(& $vm -Profile $Profile field)[-1]
  if ($LASTEXITCODE -ne 0 -or $out -eq 'NOFIELD') { return $null }
  $out.Split('|', 4)[3]
}

function Clear-Field {
  $edit = 'FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>()'
  & $vm -Profile $Profile eval core/vim/vim_text_scope.dart "(() { final s = $edit; if (s == null) return 'NOFIELD'; Future(() { s.widget.controller.clear(); }); return 'ok'; })()" | Out-Null
  Start-Sleep -Milliseconds 200
}

function Set-Field([int]$Y, [string]$Value, [string]$Name) {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & $voy -Profile $Profile do "click 1440 $Y; wait 300" | Out-Null
    $text = Get-FieldText
    if ($null -eq $text) { "$Name - attempt ${attempt}: no field focused after the click"; continue }
    if ($text -ne '') { Clear-Field }
    & $voy -Profile $Profile do "type $Value; wait 200" | Out-Null
    if ((Get-FieldText) -eq $Value) { return }
    "$Name - attempt ${attempt}: the field didn't match what was typed; retrying"
    Clear-Field
  }
  throw "login: could not fill the $Name field after 3 attempts"
}

# Login page: Email field y=727, Password y=847, "Create account" y=1191.
# After switching to sign-up the card re-centres: Email y=783, Password y=903.
$emailY = 727; $pwY = 847
& $voy -Profile $Profile do 'park; wait 600'
if ($SignUp) { & $voy -Profile $Profile do 'click 1440 1191; wait 800'; $emailY = 783; $pwY = 903 }
Set-Field $emailY $Email 'email'
Set-Field $pwY $Password 'password'
& $voy -Profile $Profile do 'shot login-filled; key enter; wait 8000; shot login-after'
& $vm -Profile $Profile whoami
if ($LASTEXITCODE -eq 3) { throw 'STOP: signed into a non-QA account' }
