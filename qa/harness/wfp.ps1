# Phase 7: which process owns the window at a few screen points (no capture).
# Reports only process names, never pixels.  usage: wfp.ps1 [x,y ...]
param([string[]]$Points = @('5,5', '80,60', '1440,40', '1440,900', '2870,1790', '2800,1700'))
Add-Type @'
using System; using System.Runtime.InteropServices;
public class Wfp {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
[Wfp]::SetProcessDPIAware() | Out-Null
foreach ($s in $Points) {
  $xy = $s -split ','
  $p = New-Object Wfp+POINT; $p.X = [int]$xy[0]; $p.Y = [int]$xy[1]
  $h = [Wfp]::WindowFromPoint($p)
  $root = [Wfp]::GetAncestor($h, 2)
  $procId = 0; [Wfp]::GetWindowThreadProcessId($root, [ref]$procId) | Out-Null
  $name = try { (Get-Process -Id $procId).ProcessName } catch { '?' }
  $lp = [IntPtr](($p.Y -shl 16) -bor ($p.X -band 0xFFFF))
  $hit = [Wfp]::SendMessage($root, 0x84, [IntPtr]::Zero, $lp)
  "($s) -> $name hittest=$hit"
}
