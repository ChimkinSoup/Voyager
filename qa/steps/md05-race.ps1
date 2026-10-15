# MD-5.2 / 5.3: one instance runs a voy.ps1 steps file (typing into an open record) while the
# other runs an evalc-style body (md4pair.py --only) after -DelayMs. Prints both outputs.
#   md05-race.ps1 -Typer qb -Steps qa\steps\md05-52-je-b.txt -Actor qa -Lib <lib> -Body <body> -Tag b [-DelayMs 3000]
param(
    [Parameter(Mandatory)][string]$Typer, [Parameter(Mandatory)][string]$Steps,
    [Parameter(Mandatory)][string]$Actor, [Parameter(Mandatory)][string]$Lib,
    [Parameter(Mandatory)][string]$Body, [Parameter(Mandatory)][string]$Tag,
    [int]$DelayMs = 3000
)
$repo = 'C:\Users\Juno\Code\Voyager'
$job = Start-Job -ScriptBlock {
    param($repo, $lib, $body, $tag, $prof, $delay)
    Set-Location $repo
    Start-Sleep -Milliseconds $delay
    python qa/steps/md4pair.py $lib $body --only $prof --tag $tag 2>&1
} -ArgumentList $repo, $Lib, $Body, $Tag, $Actor, $DelayMs
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 -Profile $Typer run $Steps
Receive-Job $job -Wait -AutoRemoveJob
