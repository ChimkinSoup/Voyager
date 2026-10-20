# Phase 28A D5: launch profile qa, unlock, pick three photos on Progress, Save,
# and kill the app -KillMs after the Save click.
param([int]$KillMs = 2500)
$env:VOYAGER_QA_PROFILE = 'qa'
$h = 'C:\Users\Juno\Code\Voyager\qa'
$e = [string][char]0x2026
& C:\Users\Juno\Code\Voyager\qa\harness\launch.ps1 -Profile qa 2>&1 | Select-Object -Last 1
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do "park; wait 3000; wheel 88 1300 -10; wait 500; tap Photos; wait 2000; tap Progress; wait 2000; click 532 538; type p28vault2; key enter; wait 4000; tap Check in; wait 1500; tap Choose file$e"
& C:\Users\Juno\Code\Voyager\qa\steps\md13-filedlg.ps1 -Profile qa -Path "$h\data\p28\p06-8000.jpg"
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do "wait 2500; tap Next; wait 400; tap Choose file$e"
& C:\Users\Juno\Code\Voyager\qa\steps\md13-filedlg.ps1 -Profile qa -Path "$h\data\p28\p01-portrait-exif.jpg"
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do "wait 1500; tap Next; wait 400; tap Choose file$e"
& C:\Users\Juno\Code\Voyager\qa\steps\md13-filedlg.ps1 -Profile qa -Path "$h\data\p28\p02-landscape-noexif.jpg"
& C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1 do "wait 1500; tap Next; wait 400; tap Skip; wait 600; tap Save; wait $KillMs"
& C:\Users\Juno\Code\Voyager\qa\harness\stop.ps1 -Profile qa
