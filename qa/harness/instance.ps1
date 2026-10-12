# Dot-sourced by the harness scripts: which Voyager instance a script acts on,
# and where that instance keeps things (DEV_PROFILE_HLD.md §7).
#
# A profile name is a dev profile run beside the normal app (VOYAGER_PROFILE).
# 'default' is the normal instance. Scripts take -Profile; without it they fall
# back to $env:VOYAGER_QA_PROFILE, so one `$env:VOYAGER_QA_PROFILE = 'b'`
# points a whole sequence of calls at B, and `-Profile default` still reaches
# the normal instance meanwhile. With neither, it's the normal instance.

# '' for the normal instance, else the profile name.
function Resolve-QaProfile([string]$Name) {
  if ($Name -eq 'default') { return '' }
  if (-not $Name) { $Name = "$env:VOYAGER_QA_PROFILE" }
  if ($Name -eq 'default') { return '' }
  if ($Name -and $Name -cnotmatch '^[a-z0-9]{1,16}$') {
    throw "profile must be 'default' or 1-16 of a-z and 0-9: '$Name'"
  }
  $Name
}

function Get-QaInstance([string]$Name) {
  $Name = Resolve-QaProfile $Name
  $logs = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
  $suffix = if ($Name) { "_$Name" } else { '' }
  # The Firebase app name, which keys the SDK's Firestore cache and
  # Credential Manager sign-in.
  $app = if ($Name) { "voyager-$Name" } else { '[DEFAULT]' }
  [pscustomobject]@{
    Profile      = $Name
    # What to pass as -Profile to another script: never '', which would fall
    # back to the environment variable.
    Arg          = if ($Name) { $Name } else { 'default' }
    Label        = if ($Name) { "profile $Name" } else { 'the normal instance' }
    DataDir      = Join-Path $env:APPDATA $(if ($Name) { "Voyager\voyager-profile-$Name" } else { 'Voyager\voyager' })
    FirestoreDir = Join-Path $env:LOCALAPPDATA "firestore\$app\voyager-db9de"
    CredPrefix   = "voyager-db9de.firebase.auth/$app"
    VmUriFile    = Join-Path $logs "vm_uri$suffix.txt"
    PidFile      = Join-Path $logs "pid$suffix.txt"
  }
}

# Records $Process in $File as "<pid> <start time>", so a PID Windows has
# since reused for another process is never mistaken for it.
function Save-QaPid([string]$File, $Process) {
  Set-Content -LiteralPath $File -Value "$($Process.Id) $($Process.StartTime.ToUniversalTime().Ticks)" -Encoding ascii
}

# The live process a PID file names, or nothing if it has exited.
function Get-QaPidProcess([string]$File) {
  if (-not (Test-Path -LiteralPath $File)) { return }
  $id, $ticks = (Get-Content -Raw -LiteralPath $File).Trim() -split '\s+'
  $proc = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue
  if ($proc -and $proc.ProcessName -eq 'voyager' -and "$($proc.StartTime.ToUniversalTime().Ticks)" -eq $ticks) { $proc }
}

# The instance's running voyager.exe, or nothing. A profile is found only by
# the PID launch.ps1 recorded. The normal instance is any other voyager.exe:
# it may not have come from launch.ps1 (Juno's installed release).
function Get-QaProcess($Instance) {
  if ($Instance.Profile) { return Get-QaPidProcess $Instance.PidFile }
  $logs = Split-Path -Parent $Instance.PidFile
  $profilePids = @(Get-ChildItem -LiteralPath $logs -Filter 'pid_*.txt' -ErrorAction SilentlyContinue |
      ForEach-Object { (Get-QaPidProcess $_.FullName).Id })
  Get-Process voyager -ErrorAction SilentlyContinue | Where-Object { $profilePids -notcontains $_.Id }
}
