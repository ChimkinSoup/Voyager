// Background input for voy.ps1 (`mode bg`, the default). Posts mouse and key
// messages straight to Voyager's FLUTTERVIEW child window, so nothing needs the
// foreground and nothing can reach another app. Verified 2026-10-12 with
// Voyager covered and parked off-screen while Juno used other apps.
//
// - Modifiers: Flutter reads Ctrl/Shift/Alt from the thread's key state, not
//   from the posted messages. Chords therefore attach to Voyager's input thread
//   and set its key state around the posted keys (Voyager's thread only; the
//   foreground app's state is untouched). The state is held until Voyager's
//   thread has pumped through the keys (WM_NULL round trips), not for a fixed
//   time: with the thread busy, a 120 ms hold dropped Ctrl in 17 of 40 Ctrl+A
//   presses (2026-10-12). The runner's TranslateMessage turns
//   the posted WM_KEYDOWNs into WM_CHAR, so Shift also gives capitals/symbols.
// - Mouse: once Voyager sees a posted move while the real cursor is elsewhere,
//   Windows soon sends WM_MOUSELEAVE, which cancels a pointer that is still
//   down. Clicks and drags are therefore posted as one burst. Gestures that
//   need real timing (long-press, slow drags) and hover need `mode fg`.
// - Wheel: not here. The embedder places WM_MOUSEWHEEL at the real cursor
//   position, so voy.ps1 sends bg wheels as in-app events (vm.ps1 scroll).
// Coordinates are physical client px, the same as screenshots. Must stay C# 5.
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class Bg
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char c);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Voy.RECT r);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Voy.RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] s);
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeoutMs, out IntPtr result);

    const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;

    static Bg() { SetProcessDPIAware(); }

    static IntPtr View()
    {
        var v = FindWindowEx(Voy.MainWindow(), IntPtr.Zero, "FLUTTERVIEW", null);
        if (v == IntPtr.Zero) throw new InvalidOperationException("no Voyager FLUTTERVIEW window");
        return v;
    }

    /// Resets the system sleep timer (the display may still turn off). Called on every bg run.
    public static void KeepAwake() { SetThreadExecutionState(0x1 /* ES_SYSTEM_REQUIRED */); }

    // ---- mouse ----------------------------------------------------------------

    static IntPtr XY(IntPtr v, int x, int y)
    {
        Voy.RECT c; GetClientRect(v, out c);
        if (x < 0 || y < 0 || x >= c.R || y >= c.B)
            throw new InvalidOperationException("(" + x + "," + y + ") is outside Voyager's client area " + c.R + "x" + c.B);
        return (IntPtr)((y << 16) | (x & 0xFFFF));
    }

    public static void Click(int x, int y, bool right = false, int count = 1)
    {
        var v = View(); var p = XY(v, x, y);
        uint down = right ? 0x0204u : 0x0201u, up = right ? 0x0205u : 0x0202u;
        var btn = (IntPtr)(right ? 2 : 1);
        for (int i = 0; i < count; i++)
        {
            // Gap between clicks: Flutter ignores a second tap under 40 ms (kDoubleTapMinTime).
            if (i > 0) Thread.Sleep(60);
            PostMessage(v, 0x0200, IntPtr.Zero, p);
            PostMessage(v, down, btn, p);
            PostMessage(v, up, IntPtr.Zero, p);
        }
        Thread.Sleep(80);
    }

    /// Moves the pointer for one instant. Hover does not persist (see header).
    public static void Move(int x, int y) { var v = View(); PostMessage(v, 0x0200, IntPtr.Zero, XY(v, x, y)); }

    public static void Drag(int x1, int y1, int x2, int y2, int steps = 20)
    {
        var v = View();
        XY(v, x2, y2);
        PostMessage(v, 0x0200, IntPtr.Zero, XY(v, x1, y1));
        PostMessage(v, 0x0201, (IntPtr)1, XY(v, x1, y1));
        for (int i = 1; i <= steps; i++)
            PostMessage(v, 0x0200, (IntPtr)1, XY(v, x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps));
        PostMessage(v, 0x0202, IntPtr.Zero, XY(v, x2, y2));
        Thread.Sleep(80);
    }

    // ---- keyboard ---------------------------------------------------------------

    static IntPtr KeyL(byte vk, bool up, bool alt)
    {
        long l = 1 | ((long)MapVirtualKey(vk, 0) << 16);
        if ((vk >= 0x21 && vk <= 0x28) || vk == 0x2D || vk == 0x2E) l |= 1L << 24; // extended
        if (alt) l |= 1L << 29;
        if (up) l |= 0xC0000000L;
        return (IntPtr)unchecked((int)l);
    }

    /// Posts key down/up for `keys` (modifiers first) with the modifiers held in
    /// Voyager's thread key state while the app processes them.
    static void Press(IntPtr v, byte[] mods, byte key)
    {
        bool alt = Array.IndexOf(mods, (byte)0x12) >= 0;
        uint downMsg = alt ? 0x0104u : 0x0100u, upMsg = alt ? 0x0105u : 0x0101u;
        if (mods.Length == 0)
        {
            PostMessage(v, 0x0100, (IntPtr)key, KeyL(key, false, false));
            PostMessage(v, 0x0101, (IntPtr)key, KeyL(key, true, false));
            return;
        }
        uint pid; uint vt = GetWindowThreadProcessId(v, out pid); uint me = GetCurrentThreadId();
        if (!AttachThreadInput(me, vt, true)) throw new InvalidOperationException("AttachThreadInput to Voyager failed");
        var st = new byte[256];
        try
        {
            // Flutter reads the modifiers when it handles each key, which can be
            // well after posting when Voyager's thread is busy (a long frame, startup):
            // a fixed hold let Ctrl+A arrive as a plain "a". So post only once the
            // thread is pumping, and release only after it has pumped through them.
            Pump(v);
            GetKeyboardState(st);
            foreach (var m in mods) Hold(st, m, true);
            SetKeyboardState(st);
            foreach (var m in mods) PostMessage(v, downMsg, (IntPtr)m, KeyL(m, false, alt));
            PostMessage(v, downMsg, (IntPtr)key, KeyL(key, false, alt));
            PostMessage(v, upMsg, (IntPtr)key, KeyL(key, true, alt));
            for (int i = mods.Length - 1; i >= 0; i--) PostMessage(v, upMsg, (IntPtr)mods[i], KeyL(mods[i], true, alt));
            // Each round trip returns once the thread has called GetMessage again,
            // so one per posted message (plus the WM_CHAR TranslateMessage adds).
            for (int i = 0; i < 2 * mods.Length + 3; i++) Pump(v);
            Thread.Sleep(30);
        }
        finally
        {
            foreach (var m in mods) Hold(st, m, false);
            SetKeyboardState(st);
            AttachThreadInput(me, vt, false);
        }
    }

    /// Returns once Voyager's thread next pumps its message queue (a WM_NULL
    /// round trip), or after 10 s if it's hung.
    static void Pump(IntPtr v)
    {
        IntPtr r;
        SendMessageTimeout(v, 0x0000 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero, 0x2 /* SMTO_ABORTIFHUNG */, 10000, out r);
    }

    static void Hold(byte[] st, byte vk, bool on)
    {
        byte side = vk == 0x11 ? (byte)0xA2 : vk == 0x10 ? (byte)0xA0 : vk == 0x12 ? (byte)0xA4 : vk;
        if (on) { st[vk] |= 0x80; st[side] |= 0x80; } else { st[vk] &= 0x7F; st[side] &= 0x7F; }
    }

    static bool IsMod(byte vk) { return vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0x5B; }

    /// A chord such as "ctrl+shift+tab" or "esc".
    public static void Chord(string chord)
    {
        var parts = chord.Split('+');
        var mods = new byte[parts.Length - 1];
        for (int i = 0; i < mods.Length; i++) mods[i] = Voy.VkFor(parts[i].Trim());
        Press(View(), mods, Voy.VkFor(parts[parts.Length - 1].Trim()));
        Thread.Sleep(40);
    }

    /// Types text as real key presses (so Vim sees key events); \n = Enter.
    public static void Type(string text, int perKeyMs = 25)
    {
        var v = View();
        foreach (char c in text)
        {
            if (c == '\n') { Press(v, new byte[0], 0x0D); Thread.Sleep(perKeyMs); continue; }
            short r = VkKeyScanW(c);
            if (r == -1) throw new ArgumentException("Cannot type character: U+" + ((int)c).ToString("X4"));
            byte vk = (byte)(r & 0xFF);
            if (IsMod(vk)) throw new ArgumentException("Cannot type character: U+" + ((int)c).ToString("X4"));
            Press(v, (r & 0x100) != 0 ? new byte[] { 0x10 } : new byte[0], vk);
            Thread.Sleep(perKeyMs);
        }
    }

    // ---- window -----------------------------------------------------------------

    /// Moves the window off-screen without activating it, sized so the client
    /// area is 2880x1800 (the maximized coordinates the step files use).
    public static void Park()
    {
        var m = Voy.MainWindow();
        if (IsZoomed(m) || IsIconic(m)) { ShowWindow(m, 4 /* SW_SHOWNOACTIVATE */); Thread.Sleep(200); }
        Voy.RECT r, c; GetWindowRect(m, out r); GetClientRect(m, out c);
        int fw = (r.R - r.L) - c.R, fh = (r.B - r.T) - c.B;
        SetWindowPos(m, IntPtr.Zero, -6000, 0, 2880 + fw, 1800 + fh, SWP_NOZORDER | SWP_NOACTIVATE);
        Thread.Sleep(200);
        // Windows clamps to the max track size (smaller monitor, DPI change); step coords would be off.
        GetClientRect(m, out c);
        if (c.R != 2880 || c.B != 1800) throw new InvalidOperationException("park: client is " + c.R + "x" + c.B + ", not 2880x1800");
    }

    /// Brings a parked window back on-screen at (0,0), still without activating it.
    public static void Unpark()
    {
        SetWindowPos(Voy.MainWindow(), IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}
