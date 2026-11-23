# Signs a qa account in on the phone's login page (or signs it up with
# -SignUp), through phone.ps1's guarded input. Refuses any e-mail that isn't
# voyager-qa-NNN@example.com. Once signed in, adds the account's UID to
# phone_accounts.txt (only after the app reports that same qa e-mail) and runs
# phone.ps1 check. Needs phone_launch.ps1's VM service.
#   phone_login.ps1 -Email voyager-qa-129@example.com [-SignUp] [-Password …]
param([Parameter(Mandatory)][string]$Email, [switch]$SignUp, [string]$Password = 'qavoyager2026', [int]$TimeoutSec = 60)
$ErrorActionPreference = 'Stop'
if ($Email -cnotmatch '^voyager-qa-\d+@example\.com$') { throw "refusing: $Email is not a voyager-qa-NNN@example.com account" }
$phone = Join-Path $PSScriptRoot 'phone.ps1'
$vm = Join-Path $PSScriptRoot 'vm.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ((& $phone check) -ne 'ok: signed out') { throw 'the phone app is not signed out; sign it out first (phone_session_end.ps1)' }

# Centre of a label, clickable or not (a text field's label lies under the field).
function Get-LabelPoint([string]$Label) {
  foreach ($line in @(& $vm -Profile phone locate 1 $Label)) {
    if ("$line" -match "^(\d+) (\d+)$") { return "$line" }
    if ("$line" -match "^text\t(\d+),(\d+)\t\S+\t(NOT-CLICKABLE\t)?$([regex]::Escape($Label))$") { return "$($Matches[1]) $($Matches[2])" }
  }
  throw "no '$Label' on screen"
}
function Invoke-Tap([string]$Point) { $x, $y = $Point -split ' '; & $phone tap $x $y; Start-Sleep -Milliseconds 700 }

# The VM service is up before the first frame: wait for the login page.
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (@(& $vm -Profile phone find 'Create account').Count -eq 0) {
  if ((Get-Date) -gt $deadline) { throw "no login page after $TimeoutSec s" }
  Start-Sleep 2
}
# Taps right after the first frame get lost (M0, 2026-11-22), so every step
# is checked and the first ones retried.
Start-Sleep 3
if ($SignUp) {
  for ($i = 0; @(& $vm -Profile phone find 'Sign up').Count -eq 0; $i++) {
    if ($i -ge 3) { throw "'Create account' didn't switch to sign-up" }
    & $phone tapf 'Create account'; Start-Sleep 1
  }
}
# Taps the field under the label until it has focus, types, and checks the text.
function Set-Field([string]$Label, [string]$Text) {
  for ($i = 0; "$(& $vm -Profile phone field)" -notmatch '^0,0\|'; $i++) {
    if ($i -ge 3) { throw "the $Label field (empty) didn't take focus" }
    Invoke-Tap (Get-LabelPoint $Label)
  }
  & $phone type $Text
  Start-Sleep -Milliseconds 500
  if ("$(& $vm -Profile phone field)" -notmatch "\|$($Text.Length)\|") { throw "the $Label field didn't get the typed text" }
}
Set-Field 'Email' $Email
Set-Field 'Password' $Password
# The soft keyboard moves the button; find it afterwards.
& $phone tapf $(if ($SignUp) { 'Sign up' } else { 'Sign in' })

# The new UID isn't allowed yet, so vm.ps1's guard would refuse: read the
# account with vm.exe directly (read-only).
$exe = Join-Path $repo 'qa\logs\vm.exe'
$saved = $env:VOYAGER_QA_PROFILE
$env:VOYAGER_QA_PROFILE = 'phone'
Push-Location $repo
try {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $who = ''
  while ((Get-Date) -lt $deadline) {
    Start-Sleep 2
    $who = "$(& $exe eval app/providers.dart "(FirebaseAuth.instanceFor(app: voyagerFirebaseApp).currentUser?.email ?? 'none') + ' ' + (FirebaseAuth.instanceFor(app: voyagerFirebaseApp).currentUser?.uid ?? '')" 2>&1)".Trim()
    if ($who -like "$Email *") { break }
  }
} finally { Pop-Location; $env:VOYAGER_QA_PROFILE = $saved }
if ($who -notlike "$Email *") { throw "not signed in as $Email after $TimeoutSec s (app says: $who); see qa\shots via phone.ps1 shot" }
$uid = ($who -split ' ')[1]
if ($uid -notmatch '^[A-Za-z0-9]{20,40}$') { throw "unexpected UID '$uid'" }
$list = Join-Path $PSScriptRoot 'phone_accounts.txt'
if (-not (Select-String -LiteralPath $list -Pattern "^$uid\b" -Quiet)) {
  Add-Content -LiteralPath $list -Value "$uid  # $Email" -Encoding ascii
  "added $uid ($Email) to phone_accounts.txt"
}
# The guard reads the UID the local data belongs to, written once the
# startup pull has set the account up.
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ($true) {
  try { & $phone check; break } catch { if ((Get-Date) -gt $deadline) { throw } ; Start-Sleep 2 }
}
"signed in: $Email"
