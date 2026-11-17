# Drives Voyager on the Android emulator over adb, refusing any input unless
# the app is signed out or its data belongs to a qa account (2026-11-17: taps
# meant for the login page landed in Juno's real account, which an earlier
# install had kept signed in and which showed the login page while loading).
#
#   phone.ps1 check                 who the app's data belongs to; fails if not qa
#   phone.ps1 launch                start the app (guarded)
#   phone.ps1 tap <x> <y>           tap, in physical pixels (guarded)
#   phone.ps1 long <x> <y>          long-press (guarded)
#   phone.ps1 swipe <x1> <y1> <x2> <y2> [ms]   (guarded)
#   phone.ps1 text <s>              type, no spaces (guarded)
#   phone.ps1 key <code>            key event, e.g. 4 = Back (guarded)
#   phone.ps1 shot <name>           screenshot to qa/shots/<name>.png
#   phone.ps1 ui                    on-screen texts with their bounds
#
# The account is read from the app's own database (settings_table
# .local_owner_uid, the account the local data belongs to) through run-as,
# which works on debug builds only. Allowed accounts are the UIDs listed in
# phone_accounts.txt beside this script. Signed out (no Firebase Auth store)
# is allowed, so the login page can be filled in. A check that passed is
# remembered by the auth store's contents, so only a new sign-in reads the
# database again.
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$package = 'com.example.voyager'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$logs = Join-Path $repo 'qa\logs'
$cacheFile = Join-Path $logs 'phone_guard.txt'
New-Item -ItemType Directory -Force $logs | Out-Null

function Invoke-Adb([string[]]$Arguments) {
  $out = & $adb @Arguments
  if ($LASTEXITCODE -ne 0) { throw "adb $($Arguments -join ' ') failed: $out" }
  $out
}

# Binary output (a database, a screenshot) straight to a file: PowerShell's
# pipeline would re-encode it.
function Save-AdbOutput([string[]]$Arguments, [string]$Path) {
  $p = Start-Process -FilePath $adb -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $Path
  if ($p.ExitCode -ne 0) { throw "adb $($Arguments -join ' ') failed" }
}

function Get-AllowedUids {
  $file = Join-Path $PSScriptRoot 'phone_accounts.txt'
  @(Get-Content -LiteralPath $file | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ })
}

# 'signed out', or the qa UID the data belongs to; throws for anything else.
function Assert-QaPhone {
  $prefs = @(Invoke-Adb @('shell', "run-as $package ls shared_prefs"))
  $store = $prefs | Where-Object { $_ -like 'com.google.firebase.auth.api.Store.*' } | Select-Object -First 1
  if (-not $store) {
    Remove-Item -LiteralPath $cacheFile -ErrorAction SilentlyContinue
    return 'signed out'
  }
  $session = (Invoke-Adb @('shell', "run-as $package cat 'shared_prefs/$store'")) -join "`n"
  $sha = [Security.Cryptography.SHA256]::Create()
  $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($session)))
  if ((Test-Path -LiteralPath $cacheFile) -and (Get-Content -LiteralPath $cacheFile -TotalCount 1) -eq $key) {
    return (Get-Content -LiteralPath $cacheFile)[1]
  }
  $db = Join-Path $logs 'phone_guard.sqlite'
  Save-AdbOutput @('exec-out', 'run-as', $package, 'cat', 'files/voyager.sqlite') $db
  $owner = "$(python -c "import sqlite3,sys; r=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True).execute('select local_owner_uid from settings_table where id=1').fetchone(); print(r[0] if r and r[0] else '')" $db)".Trim()
  Remove-Item -LiteralPath $db -ErrorAction SilentlyContinue
  if (-not $owner -or (Get-AllowedUids) -notcontains $owner) {
    Remove-Item -LiteralPath $cacheFile -ErrorAction SilentlyContinue
    $who = if ($owner) { "account $owner" } else { 'no recorded account yet' }
    throw "refusing: the phone's Voyager is signed in with $who, not a qa account in phone_accounts.txt. Sign it out by hand, or clear it: adb shell pm clear $package"
  }
  Set-Content -LiteralPath $cacheFile -Value @($key, $owner) -Encoding ascii
  $owner
}

switch ($Command) {
  'check' { "ok: $(Assert-QaPhone)" }
  'launch' { $null = Assert-QaPhone; $null = Invoke-Adb @('shell', "monkey -p $package -c android.intent.category.LAUNCHER 1") }
  'tap' { $null = Assert-QaPhone; $null = Invoke-Adb @('shell', "input tap $($Rest[0]) $($Rest[1])") }
  'long' { $null = Assert-QaPhone; $null = Invoke-Adb @('shell', "input swipe $($Rest[0]) $($Rest[1]) $($Rest[0]) $($Rest[1]) 900") }
  'swipe' {
    $null = Assert-QaPhone
    $ms = if ($Rest.Count -ge 5) { $Rest[4] } else { 300 }
    $null = Invoke-Adb @('shell', "input swipe $($Rest[0]) $($Rest[1]) $($Rest[2]) $($Rest[3]) $ms")
  }
  'text' { $null = Assert-QaPhone; $null = Invoke-Adb @('shell', "input text '$($Rest -join '')'") }
  'key' { $null = Assert-QaPhone; $null = Invoke-Adb @('shell', "input keyevent $($Rest[0])") }
  'shot' { Save-AdbOutput @('exec-out', 'screencap', '-p') (Join-Path $repo "qa\shots\$($Rest[0]).png"); "qa\shots\$($Rest[0]).png" }
  'ui' {
    # A dump can fail while anything animates; never show the last one.
    $null = Invoke-Adb @('shell', 'rm -f /sdcard/ui.xml; uiautomator dump /sdcard/ui.xml')
    $xml = (Invoke-Adb @('shell', 'cat /sdcard/ui.xml')) -join ''
    foreach ($m in [regex]::Matches($xml, '<node [^>]*>')) {
      $n = $m.Value
      $label = if ($n -match ' text="([^"]+)"') { $Matches[1] } elseif ($n -match 'content-desc="([^"]+)"') { $Matches[1] } else { $null }
      if ($label -and $n -match 'bounds="([^"]+)"') { "$($Matches[1]) $label" }
    }
  }
  default { Get-Content -LiteralPath $PSCommandPath -TotalCount 15 | Select-Object -Skip 3 | ForEach-Object { $_ -replace '^# ?', '' } }
}
