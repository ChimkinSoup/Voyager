# Is a Firebase sign-in persisted on this PC? The persisted user lives in
# Credential Manager (voyager-db9de.firebase.auth/[DEFAULT][n]) but is
# encrypted, so the e-mail can't be read offline. With the app running,
# `dart run qa/harness/vm.dart whoami` prints the signed-in e-mail.
# Output: SIGNED-OUT (exit 0) or SIGNED-IN-UNKNOWN-ACCOUNT (exit 3).
$present = cmdkey /list | Select-String 'voyager-db9de\.firebase\.auth'
if ($present) { 'SIGNED-IN-UNKNOWN-ACCOUNT'; exit 3 }
'SIGNED-OUT'
exit 0
