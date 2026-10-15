# MD-13: answer the Windows "Open" file dialog of one profile's Voyager without global input.
#   md13-filedlg.ps1 -Profile qa|qb -Path <full path> [-TimeoutS 15] [-Cancel]
# Finds a #32770 dialog owned by that profile's PID (qa/logs/pid_<profile>.txt), sets the
# file-name box (ComboBoxEx32 id 1148 -> its Edit) by WM_SETTEXT and BM_CLICKs Open (id 1),
# or Cancel (id 2) with -Cancel.
param([Parameter(Mandatory)][string]$Profile, [string]$Path, [int]$TimeoutS = 15, [switch]$Cancel)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FDlg {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static IntPtr Find(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      StringBuilder c = new StringBuilder(64); GetClassName(h, c, 64);
      if (c.ToString() == "#32770") { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
$pidLine = (Get-Content "C:\Users\Juno\Code\Voyager\qa\logs\pid_$Profile.txt" -Raw).Trim().Split(' ')[0]
$procId = [uint32]$pidLine
if ((Get-Process -Id $procId).ProcessName -ne 'voyager') { throw "pid $procId is not voyager" }
$dlg = [IntPtr]::Zero
$end = (Get-Date).AddSeconds($TimeoutS)
while ($dlg -eq [IntPtr]::Zero -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 250; $dlg = [FDlg]::Find($procId) }
if ($dlg -eq [IntPtr]::Zero) { throw "no file dialog for profile $Profile (pid $procId)" }
$t = New-Object System.Text.StringBuilder 128; [void][FDlg]::GetWindowText($dlg, $t, 128)
"dialog: '$t' pid=$procId"
if ($Cancel) { [void][FDlg]::SendMessage([FDlg]::GetDlgItem($dlg, 2), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); 'cancelled'; return }
$combo = [FDlg]::GetDlgItem($dlg, 1148)
$edit = [FDlg]::FindWindowEx($combo, [IntPtr]::Zero, 'ComboBox', $null)
if ($edit -ne [IntPtr]::Zero) { $edit = [FDlg]::FindWindowEx($edit, [IntPtr]::Zero, 'Edit', $null) } else { $edit = [FDlg]::FindWindowEx($combo, [IntPtr]::Zero, 'Edit', $null) }
if ($edit -eq [IntPtr]::Zero) { throw 'file-name box not found' }
[void][FDlg]::SendMessage($edit, 0x000C, [IntPtr]::Zero, $Path)
Start-Sleep -Milliseconds 300
[void][FDlg]::SendMessage([FDlg]::GetDlgItem($dlg, 1), 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
"opened: $Path"
