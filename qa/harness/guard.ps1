# Run before any destructive action. Exits 0 only when the running app is
# signed into a voyager-qa-* account. Exit 3 = STOP THE SESSION and tell Juno.
# -Profile (else $env:VOYAGER_QA_PROFILE) checks that dev profile's app.
param([string]$Profile)
$out = & (Join-Path $PSScriptRoot 'vm.ps1') -Profile $Profile whoami | Out-String
$code = $LASTEXITCODE
$email = $out.Trim()
if ($code -eq 3) { "GUARD FAIL: app is signed into '$email' - STOP, do not continue, tell Juno."; exit 3 }
if ($email -notmatch '^voyager-qa-\d+@example\.com$') { "GUARD FAIL: not signed into a QA account ('$email')"; exit 1 }
"GUARD OK: $email"
exit 0
