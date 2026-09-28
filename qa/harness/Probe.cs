// Win32 driver for the QA harness. Loaded by voy.ps1 via Add-Type.
// Every input path is guarded: it only fires when the foreground window
// belongs to a voyager.exe process, so a stray keystroke can never reach
// another app. Captures are of Voyager's own window only.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class Voy
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] static extern short VkKeyScan(char c);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    const int GWL_EXSTYLE = -20;
    const int WS_EX_TOPMOST = 0x8;
    const uint KEYUP = 0x2, EXTENDED = 0x1;

    static Voy() { SetProcessDPIAware(); }

    // ---- window discovery ------------------------------------------------

    static bool IsVoyagerPid(uint pid)
    {
        try { return Process.GetProcessById((int)pid).ProcessName.Equals("voyager", StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    /// The runner's top-level window (FLUTTER_RUNNER_WIN32_WINDOW), visible or not.
    public static IntPtr MainWindow()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            if (sb.ToString() != "FLUTTER_RUNNER_WIN32_WINDOW") return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (!IsVoyagerPid(pid)) return true;
            found = h; return false;
        }, IntPtr.Zero);
        return found;
    }


    public static bool VoyagerIsForeground()
    {
        var fg = GetForegroundWindow();
        if (fg == IntPtr.Zero) return false; // locked session
        uint pid; GetWindowThreadProcessId(fg, out pid);
        return IsVoyagerPid(pid);
    }

    public static bool SessionLocked() { return GetForegroundWindow() == IntPtr.Zero; }

    public static string Status()
    {
        var h = MainWindow();
        if (h == IntPtr.Zero) return "no-window";
        RECT r; GetWindowRect(h, out r);
        RECT c; GetClientRect(h, out c);
        var t = new StringBuilder(256); GetWindowText(h, t, 256);
        var fg = GetForegroundWindow();
        return string.Format(
            "hwnd=0x{0:X} title='{1}' visible={2} iconic={3} zoomed={4} topmost={5} fg={6} locked={7} rect={8},{9} {10}x{11} client={12}x{13}",
            h.ToInt64(), t, IsWindowVisible(h), IsIconic(h), IsZoomed(h),
            (GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0,
            fg == h, fg == IntPtr.Zero, r.L, r.T, r.R - r.L, r.B - r.T, c.R, c.B);
    }

    // ---- focus -------------------------------------------------------------

    /// Brings Voyager's visible main window to the foreground. Returns whether it worked.
    public static bool Activate()
    {
        var h = MainWindow();
        if (h == IntPtr.Zero || !IsWindowVisible(h) || SessionLocked()) return false;
        if (IsIconic(h)) ShowWindow(h, 9 /* SW_RESTORE */);
        var fg = GetForegroundWindow();
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint me = GetCurrentThreadId();
        AttachThreadInput(me, fgThread, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        AttachThreadInput(me, fgThread, false);
        Thread.Sleep(150);
        if (VoyagerIsForeground()) return true;
        // Foreground lock refused it; these two usually get through.
        SwitchToThisWindow(h, true);
        Thread.Sleep(250);
        if (VoyagerIsForeground()) return true;
        bool zoomed = IsZoomed(h);
        ShowWindow(h, 6 /* SW_MINIMIZE */);
        Thread.Sleep(250);
        ShowWindow(h, zoomed ? 3 : 9);
        Thread.Sleep(400);
        return VoyagerIsForeground();
    }

    static void Guard()
    {
        if (!VoyagerIsForeground())
            throw new InvalidOperationException("GUARD: Voyager is not the foreground window; refusing to send input.");
    }

    // ---- keyboard ------------------------------------------------------------

    static bool IsExtended(byte vk)
    {
        return vk == 0x21 || vk == 0x22 || vk == 0x23 || vk == 0x24 || // PgUp PgDn End Home
            (vk >= 0x25 && vk <= 0x28) || vk == 0x2D || vk == 0x2E; // arrows Ins Del
    }

    static void Down(byte vk)
    {
        byte sc = (byte)MapVirtualKey(vk, 0);
        keybd_event(vk, sc, IsExtended(vk) ? EXTENDED : 0, UIntPtr.Zero);
    }

    static void Up(byte vk)
    {
        byte sc = (byte)MapVirtualKey(vk, 0);
        keybd_event(vk, sc, KEYUP | (IsExtended(vk) ? EXTENDED : 0), UIntPtr.Zero);
    }

    public static byte VkFor(string name)
    {
        switch (name.ToLowerInvariant())
        {
            case "ctrl": case "control": return 0x11;
            case "shift": return 0x10;
            case "alt": return 0x12;
            case "win": return 0x5B;
            case "enter": case "return": return 0x0D;
            case "esc": case "escape": return 0x1B;
            case "tab": return 0x09;
            case "space": return 0x20;
            case "backspace": case "bs": return 0x08;
            case "delete": case "del": return 0x2E;
            case "insert": return 0x2D;
            case "home": return 0x24;
            case "end": return 0x23;
            case "pgup": case "pageup": return 0x21;
            case "pgdn": case "pagedown": return 0x22;
            case "left": return 0x25;
            case "up": return 0x26;
            case "right": return 0x27;
            case "down": return 0x28;
            case "capslock": return 0x14;
            case "slash": return 0xBF;
            case "backslash": return 0xDC;
            case "comma": return 0xBC;
            case "period": case "dot": return 0xBE;
            case "minus": return 0xBD;
            case "equals": case "plus": return 0xBB;
            case "semicolon": return 0xBA;
            case "quote": return 0xDE;
            case "backtick": return 0xC0;
            case "lbracket": return 0xDB;
            case "rbracket": return 0xDD;
        }
        if (name.Length > 1 && (name[0] == 'f' || name[0] == 'F'))
        {
            int n;
            if (int.TryParse(name.Substring(1), out n) && n >= 1 && n <= 24) return (byte)(0x6F + n);
        }
        if (name.Length == 1)
        {
            char ch = char.ToUpperInvariant(name[0]);
            if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) return (byte)ch;
        }
        throw new ArgumentException("Unknown key: " + name);
    }

    /// A chord such as "ctrl+shift+tab" or "esc".
    public static void Chord(string chord, int holdMs = 30)
    {
        Guard();
        var parts = chord.Split('+');
        var vks = new byte[parts.Length];
        for (int i = 0; i < parts.Length; i++) vks[i] = VkFor(parts[i].Trim());
        foreach (var vk in vks) { Down(vk); Thread.Sleep(10); }
        Thread.Sleep(holdMs);
        for (int i = vks.Length - 1; i >= 0; i--) { Up(vks[i]); Thread.Sleep(10); }
    }

    /// Types text with real virtual-key presses (never Unicode packets, which
    /// bypass Vim's key handling). Shift is pressed for characters that need it.
    public static void Type(string text, int perKeyMs = 25)
    {
        foreach (char c in text)
        {
            Guard();
            if (c == '\n') { Down(0x0D); Up(0x0D); Thread.Sleep(perKeyMs); continue; }
            short r = VkKeyScan(c);
            if (r == -1) throw new ArgumentException("Cannot type character: U+" + ((int)c).ToString("X4"));
            byte vk = (byte)(r & 0xFF);
            bool shift = (r & 0x100) != 0;
            if (shift) Down(0x10);
            Down(vk); Up(vk);
            if (shift) Up(0x10);
            Thread.Sleep(perKeyMs);
        }
    }

    // ---- global hotkeys ------------------------------------------------------------

    /// True when some process already owns this global hotkey (so pressing it
    /// is swallowed by that owner, not delivered to the foreground app).
    public static bool HotkeyTaken(uint mods, uint vk)
    {
        if (RegisterHotKey(IntPtr.Zero, 0xBEEF, mods, vk)) { UnregisterHotKey(IntPtr.Zero, 0xBEEF); return false; }
        return true;
    }

    /// Presses a Ctrl+Alt+<key> global hotkey for real, but only if it is
    /// registered (so it can't leak into whatever app is in front).
    public static void GlobalHotkey(string chord)
    {
        var parts = chord.Split('+');
        uint mods = 0;
        byte key = 0;
        foreach (var p in parts)
        {
            var s = p.Trim().ToLowerInvariant();
            if (s == "ctrl") mods |= 2; else if (s == "alt") mods |= 1; else if (s == "shift") mods |= 4; else if (s == "win") mods |= 8;
            else key = VkFor(s);
        }
        if (!HotkeyTaken(mods, key)) throw new InvalidOperationException("GUARD: " + chord + " is not registered by anyone; refusing to send it.");
        var vks = new System.Collections.Generic.List<byte>();
        if ((mods & 2) != 0) vks.Add(0x11);
        if ((mods & 1) != 0) vks.Add(0x12);
        if ((mods & 4) != 0) vks.Add(0x10);
        vks.Add(key);
        foreach (var vk in vks) { Down(vk); Thread.Sleep(10); }
        Thread.Sleep(30);
        for (int i = vks.Count - 1; i >= 0; i--) { Up(vks[i]); Thread.Sleep(10); }
    }

    // ---- mouse (coordinates are physical client pixels, same as screenshots) ----

    static POINT ToScreen(int x, int y)
    {
        var p = new POINT { X = x, Y = y };
        ClientToScreen(MainWindow(), ref p);
        return p;
    }

    public static void Click(int x, int y, bool right = false, int count = 1)
    {
        Guard();
        var p = ToScreen(x, y);
        SetCursorPos(p.X, p.Y);
        Thread.Sleep(60);
        for (int i = 0; i < count; i++)
        {
            Guard();
            mouse_event(right ? 0x0008u : 0x0002u, 0, 0, 0, UIntPtr.Zero);
            Thread.Sleep(40);
            mouse_event(right ? 0x0010u : 0x0004u, 0, 0, 0, UIntPtr.Zero);
            Thread.Sleep(70);
        }
    }

    public static void Move(int x, int y)
    {
        Guard();
        var p = ToScreen(x, y);
        SetCursorPos(p.X, p.Y);
    }

    public static void Drag(int x1, int y1, int x2, int y2, int steps = 20)
    {
        Guard();
        var a = ToScreen(x1, y1); var b = ToScreen(x2, y2);
        SetCursorPos(a.X, a.Y); Thread.Sleep(60);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        for (int i = 1; i <= steps; i++)
        {
            SetCursorPos(a.X + (b.X - a.X) * i / steps, a.Y + (b.Y - a.Y) * i / steps);
            Thread.Sleep(15);
        }
        Thread.Sleep(60);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static void Wheel(int x, int y, int notches)
    {
        Guard();
        var p = ToScreen(x, y);
        SetCursorPos(p.X, p.Y); Thread.Sleep(40);
        mouse_event(0x0800, 0, 0, notches * 120, UIntPtr.Zero);
    }

    // ---- window control -------------------------------------------------------

    public static void Restore() { ShowWindow(MainWindow(), 9); }
    public static void Maximize() { ShowWindow(MainWindow(), 3); }

    /// Outer window size in physical pixels, at (x, y).
    public static void Place(int x, int y, int w, int h)
    {
        var m = MainWindow();
        if (IsZoomed(m)) { ShowWindow(m, 9); Thread.Sleep(200); }
        SetWindowPos(m, IntPtr.Zero, x, y, w, h, 0x0004 /* NOZORDER */ | 0x0010 /* NOACTIVATE */);
    }

    /// WM_CLOSE: the app hides to the tray rather than quitting.
    public static void Close() { PostMessage(MainWindow(), 0x0010, IntPtr.Zero, IntPtr.Zero); }

    /// tray_manager's callback. leftClick=true -> "Open Voyager"; false opens the context menu.
    public static void Tray(bool leftClick)
    {
        PostMessage(MainWindow(), 0x0400 + 1, IntPtr.Zero, (IntPtr)(leftClick ? 0x0202 : 0x0205));
    }

    /// Picks the last tray-menu item (Quit) once the menu is open.
    public static void TrayQuit()
    {
        var m = MainWindow();
        Tray(false);
        Thread.Sleep(600);
        PostMessage(m, 0x0100, (IntPtr)0x26, IntPtr.Zero); PostMessage(m, 0x0101, (IntPtr)0x26, IntPtr.Zero);
        Thread.Sleep(150);
        PostMessage(m, 0x0100, (IntPtr)0x0D, IntPtr.Zero); PostMessage(m, 0x0101, (IntPtr)0x0D, IntPtr.Zero);
    }

    // ---- capture ----------------------------------------------------------

    /// Saves Voyager's client area to a PNG via PrintWindow(PW_CLIENTONLY |
    /// PW_RENDERFULLCONTENT). Works when the window is covered; returns false
    /// (and writes nothing) if the window is hidden, minimized or the session locked.
    public static bool Shot(string path)
    {
        var h = MainWindow();
        if (h == IntPtr.Zero || !IsWindowVisible(h) || IsIconic(h) || SessionLocked()) return false;
        RECT c; GetClientRect(h, out c);
        int w = c.R, hh = c.B;
        if (w <= 0 || hh <= 0) return false;
        using (var bmp = new Bitmap(w, hh, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                var hdc = g.GetHdc();
                bool ok = PrintWindow(h, hdc, 3);
                g.ReleaseHdc(hdc);
                if (!ok) return false;
            }
            bmp.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
