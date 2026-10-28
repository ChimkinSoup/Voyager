# Gaia's live, cross-process checks (GAIA_HLD.md §3.2, §3.3, §15.7) on a dev
# profile: the real main instance, its real companion and the native pipe
# between them. What the Dart tests (test/gaia_*_test.dart) can't reach.
#
#   gaia.ps1 checks [-WithCli] [-NoWindows] [-Keep] [-Only <pattern>]
#                                  run the checks (or those matching), PASS/FAIL
#   gaia.ps1 start                 launch the profile, attach to its companion
#   gaia.ps1 attach                re-attach to the companion (after a relaunch)
#   gaia.ps1 status                main and companion PIDs, pipe, Abort flag
#   gaia.ps1 ceval <expr>          evaluate in the companion; GAIA = its controller
#   gaia.ps1 meval <lib> <expr>    evaluate in the main instance (vm.ps1 eval)
#   gaia.ps1 stop                  stop the profile and its companion
#
# -Profile <name> (default gaiaqa, at most 15 characters) is the dev profile;
# the normal instance is refused, since the checks kill, suspend and abort its
# companion. -Exe runs the profile from another debug build (launch.ps1
# -ExePath):
# the build must have this session's native code, which gives the companion
# its own VM service port (gaia_pipe.cpp, VOYAGER_QA_COMPANION_VM_PORT).
#
# The companion is reached as profile "<name>c": vm.ps1 -Profile <name>c,
# its files vm_uri_<name>c.txt and pid_<name>c.txt. -WithCli adds checks that
# run real Claude Code turns (a few small model calls). -NoWindows skips the
# window checks, which show Gaia's windows on screen and take the focus.
# Expressions are passed to vm.exe as one argument: use single quotes in Dart.
param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Rest,
  [string]$Profile = 'gaiaqa',
  [string]$Exe,
  [switch]$WithCli,
  [switch]$NoWindows,
  [switch]$Keep,
  [string]$Only
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'instance.ps1')
if (-not $Profile -or $Profile -eq 'default') { throw 'Gaia checks run on a dev profile only' }
if ($Profile.Length -gt 15) { throw "profile must be at most 15 characters (the companion is '<name>c'): '$Profile'" }
$inst = Get-QaInstance $Profile
$companionName = "${Profile}c"
$cinst = Get-QaInstance $companionName
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$logs = Join-Path $repo 'qa\logs'
$portFile = Join-Path $logs "gaia_port_$Profile.txt"
$vmps = Join-Path $PSScriptRoot 'vm.ps1'
$flagFile = Join-Path $inst.DataDir 'gaia_aborted'
Set-Location $repo

if (-not ('GaiaQaWin' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class GaiaQaWin {
  delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT point, uint flags);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr process);
  [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr process);

  // Physical pixels: PowerShell isn't DPI aware, and Windows would hand it
  // rects scaled to 96 DPI. Per monitor v2.
  public static void Aware() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }

  // The process's top-level window titled "Gaia".
  public static IntPtr FindGaia(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate (IntPtr hwnd, IntPtr unused) {
      uint owner;
      GetWindowThreadProcessId(hwnd, out owner);
      if (owner != pid) return true;
      StringBuilder title = new StringBuilder(64);
      GetWindowText(hwnd, title, 64);
      if (title.ToString() != "Gaia") return true;
      found = hwnd;
      return false;
    }, IntPtr.Zero);
    return found;
  }
  // Visible and not DWM-cloaked: actually on screen.
  public static bool OnScreen(IntPtr hwnd) {
    int cloaked;
    DwmGetWindowAttribute(hwnd, 14, out cloaked, 4);
    return IsWindowVisible(hwnd) && cloaked == 0;
  }
  public static int[] Frame(IntPtr hwnd) {
    RECT r;
    GetWindowRect(hwnd, out r);
    return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
  }
  public static uint Affinity(IntPtr hwnd) { uint a; GetWindowDisplayAffinity(hwnd, out a); return a; }
  public static bool Topmost(IntPtr hwnd) { return (GetWindowLong(hwnd, -20) & 0x8) != 0; }
  public static bool ToolWindow(IntPtr hwnd) { return (GetWindowLong(hwnd, -20) & 0x80) != 0; }
  public static uint Dpi(IntPtr hwnd) { return GetDpiForWindow(hwnd); }
  public static bool OnCursorMonitor(IntPtr hwnd) {
    POINT p;
    GetCursorPos(out p);
    return MonitorFromPoint(p, 2) == MonitorFromWindow(hwnd, 2);
  }
  // No z-order change, no activation.
  public static void Move(IntPtr hwnd, int x, int y, int w, int h) { SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, 0x0014); }
  public static void Suspend(IntPtr process) { NtSuspendProcess(process); }
  public static void Resume(IntPtr process) { NtResumeProcess(process); }
}
'@
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds = 20) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $Condition) { return $true }
    Start-Sleep -Milliseconds 250
  }
  [bool](& $Condition)
}

function Get-FreePort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
  $port
}

function Test-Port([int]$Port) {
  $client = [Net.Sockets.TcpClient]::new()
  try { $client.Connect('127.0.0.1', $Port); $true } catch { $false } finally { $client.Dispose() }
}

function Get-Main { Get-QaProcess $inst }

# The main instance's companion processes (one, unless something's wrong).
function Get-Companion {
  $main = Get-Main
  if (-not $main) { return @() }
  @(Get-CimInstance Win32_Process -Filter "Name = 'voyager.exe' AND ParentProcessId = $($main.Id)" |
      Where-Object { $_.CommandLine -match '--companion' })
}

function Get-CompanionId {
  $companions = @(Get-Companion)
  if ($companions.Count -ne 1) { return 0 }
  [int]$companions[0].ProcessId
}

# The profile's Gaia pipe name (without \\.\pipe\), or nothing.
function Get-GaiaPipe {
  foreach ($path in [IO.Directory]::GetFiles('\\.\pipe\')) {
    $name = $path.Substring(9)
    if ($name -like "Voyager.Gaia.$Profile.*") { return $name }
  }
}

function Get-Descendants([int]$RootId) {
  $all = @(Get-CimInstance Win32_Process)
  $ids = [System.Collections.Generic.List[int]]::new()
  $ids.Add($RootId)
  $found = @()
  for ($i = 0; $i -lt $ids.Count; $i++) {
    foreach ($proc in $all) {
      if ($proc.ParentProcessId -eq $ids[$i] -and $proc.ProcessId -ne $ids[$i]) { $ids.Add([int]$proc.ProcessId); $found += $proc }
    }
  }
  $found
}

function Get-CompanionPort { [int](Get-Content -Raw -LiteralPath $portFile).Trim() }

function Stop-CompanionAttach {
  if (-not (Test-Path -LiteralPath $portFile)) { return }
  $port = Get-CompanionPort
  Get-CimInstance Win32_Process -Filter "Name = 'dart.exe'" |
    Where-Object { $_.CommandLine -match 'flutter_tools' -and $_.CommandLine -match "--debug-url http://127\.0\.0\.1:$port/" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# Launches the profile with a fixed VM service port for its companion.
function Start-Main {
  if (Get-Main) { throw "profile $Profile is already running; gaia.ps1 stop first" }
  $port = Get-FreePort
  Set-Content -LiteralPath $portFile -Value $port -Encoding ascii
  $saved = $env:VOYAGER_QA_COMPANION_VM_PORT
  $env:VOYAGER_QA_COMPANION_VM_PORT = "$port"
  try {
    $launch = @{ Profile = $Profile }
    if ($Exe) { $launch.ExePath = $Exe }
    & (Join-Path $PSScriptRoot 'launch.ps1') @launch | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { throw 'launch.ps1 failed' }
  } finally { $env:VOYAGER_QA_COMPANION_VM_PORT = $saved }
}

# Waits for the one companion and its VM service, and attaches to it for
# expression evaluation. Returns its PID.
function Connect-Companion {
  $port = Get-CompanionPort
  if (-not (Wait-Until { (Get-CompanionId) -ne 0 -and (Test-Port $port) } 40)) {
    throw "the companion isn't up (VM service port $port); is the build current (see -Exe)?"
  }
  $proc = Get-Process -Id (Get-CompanionId)
  Stop-CompanionAttach
  Remove-Item -LiteralPath $cinst.VmUriFile -ErrorAction SilentlyContinue
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $log = Join-Path $logs "run-$companionName-$stamp.log"
  $err = Join-Path $logs "run-$companionName-$stamp.err.log"
  Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "flutter attach -d windows --debug-url http://127.0.0.1:$port/" `
    -WorkingDirectory $repo -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
  $pattern = 'Dart VM Service on Windows is available at: (http://127\.0\.0\.1:\d+/[^/\s]+/)'
  if (-not (Wait-Until { (Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue) -match $pattern } 300)) {
    throw "flutter attach to the companion didn't come up; see $log"
  }
  $null = (Get-Content -Raw -LiteralPath $log) -match $pattern
  Set-Content -LiteralPath $cinst.VmUriFile -Value (($Matches[1] -replace '^http', 'ws') + 'ws') -Encoding ascii
  Save-QaPid $cinst.PidFile $proc
  $proc.Id
}

function Stop-Gaia {
  Stop-CompanionAttach
  if (Get-Main) { & (Join-Path $PSScriptRoot 'stop.ps1') -Profile $Profile | ForEach-Object { "  $_" } }
  $null = Wait-Until { (Get-QaPidProcess $cinst.PidFile) -eq $null } 10
  Remove-Item -LiteralPath $cinst.VmUriFile, $cinst.PidFile -ErrorAction SilentlyContinue
}

# Finds the companion's controller from the widget tree, as evalc.ps1 finds
# the ProviderContainer.
$controllerExpr = '(() { GaiaController? c; void v(Element x) { if (c != null) return; final w = x.widget; if (w is GaiaApp) { c = w.controller; } else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); return c!; })()'

function Invoke-CEval([string]$Expr) {
  $out = & $vmps -Profile $companionName eval 'features/gaia/companion/gaia_app.dart' ($Expr -creplace '\bGAIA\b', $controllerExpr)
  "$(@($out)[-1])".Trim()
}

function Invoke-MEval([string]$Lib, [string]$Expr) {
  $out = & $vmps -Profile $Profile eval $Lib $Expr
  "$(@($out)[-1])".Trim()
}

# The main instance's ProviderContainer, for settings (as evalc.ps1).
$containerExpr = "Element? e; void v(Element x) { if (e != null) return; if (x.widget.runtimeType.toString().startsWith('MaterialApp')) { e = x; } else { x.visitChildren(v); } } WidgetsBinding.instance.rootElement!.visitChildren(v); final c = ProviderScope.containerOf(e!, listen: false);"

function Invoke-Abort { $null = Invoke-MEval 'features/gaia/host/gaia_host.dart' 'Future(() => GaiaHost.instance.onHotkey(GaiaHotkey.abort))' }

function Invoke-Rearm {
  $null = Invoke-CEval 'Future(() => GAIA.rearm())'
  Wait-Until { (Invoke-CEval 'GAIA.aborted') -eq 'false' -and -not (Test-Path -LiteralPath $flagFile) } 10
}

function Get-Statuses { Invoke-CEval "GAIA.messages.map((m) => m.status.name).join(',')" }

function Get-CliChildren([int]$CompanionId) {
  @(Get-Descendants $CompanionId | Where-Object { $_.Name -match '^(claude|node|cmd)\.exe$' })
}

$script:results = [System.Collections.Generic.List[string]]::new()
function Report([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $line = if ($Ok) { "PASS  $Name" } else { "FAIL  $Name" }
  if ($Detail) { $line += "  ($Detail)" }
  $script:results.Add($line)
  $line
}
function Skip([string]$Name, [string]$Why) {
  $line = "SKIP  $Name  ($Why)"
  $script:results.Add($line)
  $line
}
function Check([string]$Name, [scriptblock]$Body) {
  if ($Only -and $Name -notlike "*$Only*") { return }
  try { & $Body } catch { Report $Name $false "$_" }
}

function Invoke-Checks {
  if (-not (Get-Main)) { 'starting the profile...'; Start-Main }
  $companionId = Connect-Companion
  # Checks that relaunch the companion leave its new PID here.
  $script:companionId = $companionId

  Check 'the companion launches and connects' {
    $pipe = Get-GaiaPipe
    $version = Invoke-CEval 'GAIA.cliVersions[''claude_code''].toString()'
    Report 'the companion launches and connects' ($companionId -ne 0 -and $pipe -and (Invoke-CEval 'GAIA.cliChecked') -eq 'true') "PID $companionId, pipe $pipe, Claude Code $version"
  }

  Check 'the companion is excluded from capture' {
    $hwnd = [GaiaQaWin]::FindGaia($companionId)
    Report 'the companion is excluded from capture' ($hwnd -ne [IntPtr]::Zero -and [GaiaQaWin]::Affinity($hwnd) -eq 0x11) ('affinity 0x{0:x}' -f [GaiaQaWin]::Affinity($hwnd))
  }

  if ($NoWindows) { Skip 'window modes and the Gaia window frame' '-NoWindows' } else {
    Check 'window modes (§3.3)' {
      $hwnd = [GaiaQaWin]::FindGaia($companionId)
      $scale = [GaiaQaWin]::Dpi($hwnd) / 96.0
      $modes = @(
        @{ Key = 'small'; Width = 560; Floater = $true },
        @{ Key = 'large'; Width = 980; Floater = $true },
        @{ Key = 'window'; Width = 1200; Floater = $false }
      )
      $problems = @()
      foreach ($mode in $modes) {
        $null = Invoke-CEval "Future(() => GAIA.onHotkey('$($mode.Key)'))"
        $shown = Wait-Until { [GaiaQaWin]::OnScreen($hwnd) -and (Invoke-CEval 'GAIA.layout.name') -eq $mode.Key } 10
        $width = [GaiaQaWin]::Frame($hwnd)[2] / $scale
        if (-not $shown) { $problems += "$($mode.Key) not shown" }
        elseif ($mode.Floater -and [math]::Abs($width - $mode.Width) -gt 24) { $problems += "$($mode.Key) is $([int]$width) wide" }
        elseif ([GaiaQaWin]::ToolWindow($hwnd) -ne $mode.Floater -or [GaiaQaWin]::Topmost($hwnd) -ne $mode.Floater) { $problems += "$($mode.Key) has the wrong window styles" }
        elseif ($mode.Floater -and -not [GaiaQaWin]::OnCursorMonitor($hwnd)) { $problems += "$($mode.Key) isn't on the cursor's monitor" }
      }
      Report 'window modes (§3.3)' ($problems.Count -eq 0) ($(if ($problems) { $problems -join '; ' } else { "small, large and window at DPI scale $scale; floaters topmost tool windows on the cursor's monitor" }))
    }

    Check 'the Gaia window keeps its frame' {
      $hwnd = [GaiaQaWin]::FindGaia($companionId)
      $null = Invoke-CEval 'Future(() => GAIA.openWindow())'
      $null = Wait-Until { [GaiaQaWin]::OnScreen($hwnd) } 10
      $f = [GaiaQaWin]::Frame($hwnd)
      $want = @(($f[0] + 40), ($f[1] + 30), ($f[2] - 120), ($f[3] - 80))
      [GaiaQaWin]::Move($hwnd, $want[0], $want[1], $want[2], $want[3])
      Start-Sleep -Milliseconds 300
      $null = Invoke-CEval 'Future(() => GAIA.dismiss())'
      $hidden = Wait-Until { -not [GaiaQaWin]::OnScreen($hwnd) } 10
      $null = Invoke-CEval 'Future(() => GAIA.openWindow())'
      $null = Wait-Until { [GaiaQaWin]::OnScreen($hwnd) } 10
      $got = [GaiaQaWin]::Frame($hwnd)
      $same = $true
      for ($i = 0; $i -lt 4; $i++) { if ([math]::Abs($got[$i] - $want[$i]) -gt 2) { $same = $false } }
      $null = Invoke-CEval 'Future(() => GAIA.dismiss())'
      $null = Wait-Until { -not [GaiaQaWin]::OnScreen($hwnd) } 10
      Report 'the Gaia window keeps its frame' ($hidden -and $same) "moved to $($want -join ','), reopened at $($got -join ',')"
    }
  }

  Check "the companion follows Voyager's accent" {
    $lib = 'app/voyager_app.dart'
    $original = Invoke-MEval $lib "(() { $containerExpr return c.read(settingsProvider).value!.accentColor; })()"
    $read = "(() { $containerExpr return c.read(settingsProvider).value!.accentColor; })()"
    $green = '4283220874'
    # Each save in an event of its own: an evaluate can run in the middle of a
    # frame's build, where Riverpod throws after taking the new state and
    # before notifying anyone or writing it (BUG-319).
    $null = Invoke-MEval $lib "Future(() { $containerExpr return c.read(settingsProvider.notifier).saveSettings(c.read(settingsProvider).value!.copyWith(accentColor: $green)); })"
    $saved = Wait-Until { (Invoke-MEval $lib $read) -eq $green } 15
    $followed = Wait-Until { (Invoke-CEval 'GAIA.accent.value') -eq $green } 15
    $null = Invoke-MEval $lib "Future(() { $containerExpr return c.read(settingsProvider.notifier).saveSettings(c.read(settingsProvider).value!.copyWith(accentColor: $original)); })"
    $putBack = Wait-Until { (Invoke-MEval $lib $read) -eq $original } 15
    $restored = Wait-Until { (Invoke-CEval 'GAIA.accent.value') -eq $original } 15
    Report "the companion follows Voyager's accent" ($saved -and $followed -and $putBack -and $restored) "saved: $saved, followed: $followed; put back to $($original): $putBack, followed: $restored"
  }

  Check 'a second companion is refused by the mutex' {
    $main = Get-Main
    $vars = @{ VOYAGER_GAIA_PARENT = "$($main.Id)"; VOYAGER_PROFILE = $Profile; FLUTTER_ENGINE_SWITCHES = $null; FLUTTER_ENGINE_SWITCH_1 = $null; FLUTTER_ENGINE_SWITCH_2 = $null; VOYAGER_QA_COMPANION_VM_PORT = $null }
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try { $second = Start-Process -FilePath $main.Path -ArgumentList '--companion' -PassThru }
    finally { foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $exited = $second.WaitForExit(8000)
    if (-not $exited) { $second | Stop-Process -Force }
    Report 'a second companion is refused by the mutex' ($exited -and (Get-CompanionId) -eq $companionId) "it exited with code $(if ($exited) { $second.ExitCode } else { 'none: still running after 8 s' })"
  }

  Check 'a killed companion is relaunched; a rogue client is refused' {
    $old = $companionId
    Stop-CompanionAttach
    Stop-Process -Id $old -Force
    # The main instance relaunches it 2 s later. Its new pipe is there before
    # the new companion connects (it takes a second or more to start): a
    # rogue client that gets in first is accepted by the OS and must be
    # dropped by the PID check.
    $null = Wait-Until { -not (Get-GaiaPipe) } 5
    $verdict = 'never saw the new pipe'
    if (Wait-Until { Get-GaiaPipe } 15) {
      $client = [IO.Pipes.NamedPipeClientStream]::new('.', (Get-GaiaPipe), [IO.Pipes.PipeDirection]::InOut)
      try {
        $client.Connect(200)
        $read = $client.ReadAsync((New-Object byte[] 4), 0, 4)
        $verdict = if (-not $read.Wait(3000)) { 'kept open' } elseif ($read.Result -eq 0) { 'dropped' } else { 'sent data' }
      } catch [TimeoutException] {
        $verdict = 'lost the race'
      } catch {
        $verdict = 'dropped'
      } finally { $client.Dispose() }
    }
    if ($verdict -eq 'lost the race') { Skip 'a rogue client is refused' 'the real companion connected first' }
    else { Report 'a rogue client is refused' ($verdict -eq 'dropped') $verdict }
    $script:companionId = Connect-Companion
    Report 'a killed companion is relaunched and connects' ($script:companionId -ne $old -and (Invoke-CEval 'GAIA.cliChecked') -eq 'true') "PID $old, then $($script:companionId)"
  }
  $companionId = $script:companionId

  if (-not $WithCli) { Skip 'chat round trip, Stop, Abort mid-run' 'needs -WithCli' } else {
    Check 'a chat runs through Claude Code and is saved by the main instance' {
      $null = Invoke-CEval 'GAIA.newChat()'
      $null = Invoke-CEval "Future(() => GAIA.send('Reply with exactly these words and nothing else: gaia live ok'))"
      $done = Wait-Until { (Get-Statuses) -eq 'complete,complete' } 120
      $text = Invoke-CEval "GAIA.messages.last.parts.whereType<GaiaTextPart>().map((p) => p.text).join().toLowerCase()"
      # The main instance's store is behind a future, out of a synchronous
      # eval's reach: its database is what it saved.
      $chatId = Invoke-CEval 'GAIA.currentChatId'
      $sql = "select group_concat(status) from (select status from gaia_messages_table where chat_id = '$chatId' order by seq) having group_concat(status) = 'complete,complete'"
      $saved = python (Join-Path $PSScriptRoot 'wait_row.py') (Join-Path $inst.DataDir 'voyager.sqlite') $sql 15
      Report 'a chat runs through Claude Code and is saved by the main instance' ($done -and $text -match 'gaia live ok' -and $saved -like 'WAIT_ROW OK*') "reply '$text', main instance: $saved"
    }

    Check 'Stop ends a reply mid-stream as cancelled and kills the CLI' {
      $null = Invoke-CEval 'GAIA.newChat()'
      $null = Invoke-CEval "Future(() => GAIA.send('Count from 1 to 300, one number per line, nothing else.'))"
      $streaming = Wait-Until { (Get-Statuses) -eq 'complete,streaming' -and (Invoke-CEval "GAIA.messages.last.parts.isNotEmpty") -eq 'true' } 90
      # Each chat keeps its own CLI, idle for up to 10 minutes: Stop kills
      # only this one's.
      $clis = @(Get-CliChildren $companionId | Where-Object { $_.Name -eq 'claude.exe' }).Count
      $null = Invoke-CEval 'Future(() => GAIA.stop(GAIA.currentChatId!))'
      $cancelled = Wait-Until { (Get-Statuses) -eq 'complete,cancelled' } 15
      $gone = Wait-Until { @(Get-CliChildren $companionId | Where-Object { $_.Name -eq 'claude.exe' }).Count -eq $clis - 1 } 10
      Report 'Stop ends a reply mid-stream as cancelled and kills the CLI' ($streaming -and $cancelled -and $gone) "streaming seen: $streaming; statuses $(Get-Statuses); Claude Code processes $clis, then $(@(Get-CliChildren $companionId | Where-Object { $_.Name -eq 'claude.exe' }).Count)"
    }
  }

  Check 'Abort (§15.7): the companion confirms, every run stops' {
    if ($WithCli) {
      $null = Invoke-CEval 'GAIA.newChat()'
      $null = Invoke-CEval "Future(() => GAIA.send('Count from 1 to 300, one number per line, nothing else.'))"
      $null = Wait-Until { (Get-Statuses) -eq 'complete,streaming' } 90
    }
    Invoke-Abort
    $aborted = Wait-Until { (Invoke-CEval 'GAIA.aborted') -eq 'true' -and (Test-Path -LiteralPath $flagFile) } 10
    Start-Sleep -Seconds 2
    $alive = (Get-CompanionId) -eq $companionId
    $runs = if ($WithCli) { (Get-Statuses) -eq 'complete,aborted' -and (Get-CliChildren $companionId).Count -eq 0 } else { $true }
    Report 'Abort (§15.7): the companion confirms, every run stops' ($aborted -and $alive -and $runs) "flag saved, companion not killed$(if ($WithCli) { ', run saved as ' + (Get-Statuses) })"
  }

  Check 'Abort holds across a Voyager restart' {
    Stop-CompanionAttach
    & (Join-Path $PSScriptRoot 'stop.ps1') -Profile $Profile | Out-Null
    $exited = Wait-Until { -not (Get-Process -Id $companionId -ErrorAction SilentlyContinue) } 10
    Report 'the companion exits when the main instance goes' $exited "PID $companionId"
    Start-Main
    $script:companionId = Connect-Companion
    $held = (Invoke-CEval 'GAIA.aborted') -eq 'true'
    $rearmed = Invoke-Rearm
    Report 'Abort holds across a Voyager restart, until Re-arm' ($held -and $rearmed) "aborted after restart: $held; Re-arm cleared it: $rearmed"
  }
  $companionId = $script:companionId

  Check 'Abort kills a companion that does not confirm' {
    $proc = Get-Process -Id $companionId
    Stop-CompanionAttach
    [GaiaQaWin]::Suspend($proc.Handle)
    Invoke-Abort
    $killed = Wait-Until { -not (Get-Process -Id $companionId -ErrorAction SilentlyContinue) } 8
    if (-not $killed) { [GaiaQaWin]::Resume($proc.Handle) }
    Report 'Abort kills a companion that does not confirm within a second' $killed "PID $companionId, suspended"
    if ($killed) {
      $script:companionId = Connect-Companion
      $held = (Invoke-CEval 'GAIA.aborted') -eq 'true'
      $rearmed = Invoke-Rearm
      Report 'the relaunched companion starts aborted' ($held -and $rearmed) "PID $($script:companionId); Re-arm cleared it: $rearmed"
    }
  }

  $monitors = @([System.Windows.Forms.Screen]::AllScreens).Count
  ''
  "monitors: $monitors$(if ($monitors -gt 1) { ' (floaters were checked on the cursor''s monitor only)' })"
  $failed = @($script:results | Where-Object { $_ -like 'FAIL*' }).Count
  "$($script:results.Count) checks: $failed failed"
  if (-not $Keep) { Stop-Gaia }
  if ($failed) { exit 1 }
}

Add-Type -AssemblyName System.Windows.Forms
[GaiaQaWin]::Aware()
switch ($Command) {
  'checks' { Invoke-Checks }
  'start' { Start-Main; "companion PID: $(Connect-Companion)" }
  'attach' { "companion PID: $(Connect-Companion)" }
  'status' {
    $main = Get-Main
    "main:      $(if ($main) { "PID $($main.Id)" } else { 'not running' })"
    "companion: $(@(Get-Companion | ForEach-Object { "PID $($_.ProcessId)" }) -join ', ')"
    "pipe:      $(Get-GaiaPipe)"
    "vm port:   $(if (Test-Path -LiteralPath $portFile) { Get-CompanionPort })"
    "aborted:   $(Test-Path -LiteralPath $flagFile)"
  }
  'ceval' { Invoke-CEval ($Rest -join ' ') }
  'meval' { Invoke-MEval $Rest[0] (@($Rest | Select-Object -Skip 1) -join ' ') }
  'stop' { Stop-Gaia; "stopped $Profile and its companion" }
  default { Get-Content -LiteralPath $PSCommandPath -TotalCount 28 | Select-Object -Skip 3 | ForEach-Object { $_ -replace '^# ?', '' } }
}
