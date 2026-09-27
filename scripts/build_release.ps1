# Release build with the version, commit and date baked in (Settings -> About),
# installed to %LOCALAPPDATA%\Programs\Voyager with a Start Menu shortcut.
#   .\scripts\build_release.ps1
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value).Trim()
$sha = (git rev-parse --short HEAD).Trim()
# Uncommitted changes mean the build doesn't match the commit.
if (git status --porcelain) { $sha = "$sha-dirty" }
$date = Get-Date -Format "yyyy-MM-dd"

Write-Host "Building $version · $sha · $date"
flutter build windows --release `
    --dart-define=BUILD_VERSION=$version `
    --dart-define=BUILD_SHA=$sha `
    --dart-define=BUILD_DATE=$date
if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }

$installDir = Join-Path $env:LOCALAPPDATA "Programs\Voyager"
$exe = Join-Path $installDir "voyager.exe"

# The installed copy locks its files while it runs (it stays in the tray).
# Dev builds run from build\ and are left alone.
$running = Get-Process voyager -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }
if ($running) {
    Write-Host "Closing the installed Voyager"
    # Quit the way the tray does (flush edits, remove the tray icon); only
    # one Voyager runs per session, so the broadcast reaches just this copy.
    Add-Type -Namespace Win32 -Name User32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
'@
    [void][Win32.User32]::PostMessage([IntPtr]0xffff, [Win32.User32]::RegisterWindowMessage("Voyager.Quit"), [IntPtr]::Zero, [IntPtr]::Zero)
    $running | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
    # Builds from before the quit message, or a flush that hangs.
    $running | Where-Object { -not $_.HasExited } | Stop-Process -Force
    $running | Wait-Process
}

$installed = $false
try {
    Write-Host "Installing to $installDir"
    # /MIR deletes anything else in $installDir, so nothing the app writes may live here.
    robocopy "build\windows\x64\runner\Release" $installDir /MIR /R:3 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    # robocopy exit codes below 8 mean success.
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    $installed = $true

    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Programs")) "Voyager.lnk"
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Save()

    # Start with Windows records whichever exe turned it on, often a dev build.
    # Point an existing entry here; leave it off if it's off.
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $loginCommand = "`"$exe`" --hidden"
    $current = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).Voyager
    if ($current -and $current -cne $loginCommand) {
        Set-ItemProperty $runKey -Name Voyager -Value $loginCommand
        Write-Host "Start with Windows now starts the installed copy (was $current)"
    }
}
finally {
    # Bring the hotkeys back if it was running before, even if the shortcut or
    # Run entry failed. Not after a failed copy: /MIR may have left a mix of
    # old and new files, or no exe.
    if ($running -and $installed) { Start-Process $exe -ArgumentList "--hidden" -WorkingDirectory $installDir }
}

# It holds the single-instance lock, so the installed copy can't start until it quits.
$other = Get-Process voyager -ErrorAction SilentlyContinue | Where-Object { $_.Path -ne $exe }
if ($other) { Write-Warning "Another Voyager is running from $($other[0].Path). Quit it to use the installed copy." }
Write-Host "Installed $version · $sha"
exit 0
