# MD-5: run one evalc-style body on one profile in the background (md4pair.py --only),
# answer the confirm dialog it opens with a real tap on that instance, then print the result.
#   md05-dlg.ps1 -Profile qa -Lib features/journal/journal_list_actions.dart -Body qa\steps\md05-del-journal.dart.txt -Tag a [-Tap "Delete all entries"] [-Shot md05-...]
param(
    [Parameter(Mandatory)][string]$Profile,
    [Parameter(Mandatory)][string]$Lib,
    [Parameter(Mandatory)][string]$Body,
    [Parameter(Mandatory)][string]$Tag,
    [string]$Tap,
    [string]$Shot,
    [int]$WaitMs = 3000
)
$repo = 'C:\Users\Juno\Code\Voyager'
$job = Start-Job -ScriptBlock {
    param($repo, $lib, $body, $tag, $prof)
    Set-Location $repo
    python qa/steps/md4pair.py $lib $body --only $prof --tag $tag 2>&1
} -ArgumentList $repo, $Lib, $Body, $Tag, $Profile
if ($Tap) {
    Start-Sleep -Milliseconds $WaitMs
    $steps = ''
    if ($Shot) { $steps = "shot $Shot-dialog; " }
    $steps += "tap $Tap; wait 800"
    & C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 -Profile $Profile do $steps
}
Receive-Job $job -Wait -AutoRemoveJob
