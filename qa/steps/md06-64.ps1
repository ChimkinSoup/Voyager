# MD-6.4: create a journal through the app's "New journal" dialog on one profile: the action by eval
# (background), then the name typed into its dialog and Enter.  md06-64.ps1 -Profile qa -Name "MD6 JA1"
param([Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Name, [int]$WaitMs = 2500)
$repo = 'C:\Users\Juno\Code\Voyager'
$job = Start-Job -ScriptBlock {
    param($repo, $prof, $tag)
    Set-Location $repo
    python qa/steps/md4pair.py features/journal/journal_list_actions.dart qa/steps/md06-64-new.dart.txt --only $prof --tag $tag 2>&1
} -ArgumentList $repo, $Profile, ($Name -replace ' ', '')
Start-Sleep -Milliseconds $WaitMs
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 -Profile $Profile do "type $Name; wait 300; key enter; wait 800" | Out-Null
Receive-Job $job -Wait -AutoRemoveJob
