# Settings reveal check (BUG-226, BUG-008). -Steps runs first (e.g. open
# Settings on Account), then the request named by -Kind (auto|folder|weather)
# is raised through evalc, then -After runs (e.g. click Settings for the
# not-yet-built path).
# Reports new voyager_errors.log lines and the focused text field. QA
# accounts only (guarded).
param([string]$Kind, [string]$Steps = 'activate', [string]$After = 'activate', [string]$Shot)
$repo = 'C:\Users\Juno\Code\Voyager'
$log = "$env:USERPROFILE\Documents\voyager_errors.log"
& "$repo\qa\harness\guard.ps1"
if (-not $?) { throw 'guard failed' }
$before = (Get-Content $log).Count
& "$repo\qa\harness\voy.ps1" do $Steps
& "$repo\qa\harness\evalc.ps1" -Lib features/settings/settings_page.dart -Tag "reveal-$Kind" -BodyFile "$repo\qa\steps\backup-reveal-$Kind.dart.txt"
& "$repo\qa\harness\voy.ps1" do "$After; wait 1800; shot $Shot"
$new = (Get-Content $log) | Select-Object -Skip $before
"new error-log lines: $($new.Count)"
$new | Select-String 'uncaught|#[0-9] .*(reveal|ensureVisible|getOffsetToReveal)' | Select-Object -First 6 | ForEach-Object { $_.Line }
$focus = "(() { final f = FocusManager.instance.primaryFocus; String? label; f?.context?.visitAncestorElements((e) { final w = e.widget; if (w is LabeledTextField) { label = w.label; return false; } return true; }); return 'focus in field: ' + (label ?? 'none'); })()"
& "$repo\qa\harness\vm.ps1" eval core/widgets/labeled_text_field.dart $focus
