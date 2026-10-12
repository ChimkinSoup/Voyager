# Is a Firebase sign-in persisted on this PC? The persisted user lives in
# Credential Manager (voyager-db9de.firebase.auth/[DEFAULT][n], or
# .../voyager-<name>[n] for a dev profile, see instance.ps1) but is
# encrypted, so the e-mail can't be read offline. With the app running,
# `vm.ps1 whoami` prints the signed-in e-mail.
# Output: SIGNED-OUT (exit 0) or SIGNED-IN-UNKNOWN-ACCOUNT (exit 3).
param([string]$Profile)
. (Join-Path $PSScriptRoot 'instance.ps1')
$inst = Get-QaInstance $Profile
$present = cmdkey /list | Select-String -SimpleMatch "$($inst.CredPrefix)["
if ($present) { 'SIGNED-IN-UNKNOWN-ACCOUNT'; exit 3 }
'SIGNED-OUT'
exit 0
