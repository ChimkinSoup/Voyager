// "Another app" for the QA harness: a small WinForms window owned by the probe
// process (never a real app). Compiled together with Probe.cs by voy.ps1.
// Input here is guarded the other way round: clicks only land when the window
// under the cursor is this form, and typing only when this form is foreground.
// Must stay C# 5 (no => members, no $"").
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class Other
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] static extern short VkKeyScan(char c);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    static Form form;
    static TextBox box;
    static IntPtr handle = IntPtr.Zero;
    public static int HotkeyHits = 0;

    class HotkeyForm : Form
    {
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) HotkeyHits++;
            base.WndProc(ref m);
        }
    }

    public static void Open(int x, int y, int w, int h, bool topmost)
    {
        if (form != null) return;
        var ready = new ManualResetEvent(false);
        var t = new Thread(() =>
        {
            form = new HotkeyForm();
            form.Text = "VoyagerQA Other App";
            form.StartPosition = FormStartPosition.Manual;
            form.Bounds = new Rectangle(x, y, w, h);
            form.TopMost = topmost;
            form.ShowInTaskbar = true;
            box = new TextBox();
            box.Multiline = true;
            box.Dock = DockStyle.Fill;
            box.Font = new Font("Consolas", 14);
            form.Controls.Add(box);
            form.Shown += (s, e) => { handle = form.Handle; ready.Set(); };
            Application.Run(form);
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        ready.WaitOne(5000);
        Thread.Sleep(300);
    }

    static void Invoke(Action a) { if (form != null) form.Invoke(a); }

    public static void SetTopmost(bool on) { Invoke(() => { form.TopMost = on; }); }

    public static void Close() { if (form != null) { Invoke(() => form.Close()); form = null; handle = IntPtr.Zero; } }

    public static string Text()
    {
        string s = "";
        if (form != null) Invoke(() => { s = box.Text; });
        return s;
    }

    public static bool IsForeground() { return handle != IntPtr.Zero && GetForegroundWindow() == handle; }

    /// Real left click at the form's centre (or at an offset from its top-left),
    /// only if the top-level window under that point is this form.
    public static void Click(int dx, int dy)
    {
        if (form == null) throw new InvalidOperationException("other window not open");
        Rectangle b = Rectangle.Empty;
        Invoke(() => { b = form.Bounds; });
        var p = new POINT { X = dx >= 0 ? b.X + dx : b.X + b.Width / 2, Y = dy >= 0 ? b.Y + dy : b.Y + b.Height / 2 };
        var under = GetAncestor(WindowFromPoint(p), 2 /* GA_ROOT */);
        if (under != handle) throw new InvalidOperationException("GUARD: the window under (" + p.X + "," + p.Y + ") is not the QA other-app form (" + Describe(under) + ")");
        SetCursorPos(p.X, p.Y);
        Thread.Sleep(60);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(40);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(120);
    }

    public static void Type(string text)
    {
        foreach (char c in text)
        {
            if (!IsForeground()) throw new InvalidOperationException("GUARD: the QA other-app form is not foreground; refusing to type");
            short r = VkKeyScan(c);
            byte vk = (byte)(r & 0xFF);
            bool shift = (r & 0x100) != 0;
            if (shift) keybd_event(0x10, (byte)MapVirtualKey(0x10, 0), 0, UIntPtr.Zero);
            keybd_event(vk, (byte)MapVirtualKey(vk, 0), 0, UIntPtr.Zero);
            keybd_event(vk, (byte)MapVirtualKey(vk, 0), 2, UIntPtr.Zero);
            if (shift) keybd_event(0x10, (byte)MapVirtualKey(0x10, 0), 2, UIntPtr.Zero);
            Thread.Sleep(25);
        }
    }

    /// Registers a global hotkey to this form (so another process owns it).
    public static bool Grab(uint mods, uint vk, int id)
    {
        bool ok = false;
        Invoke(() => { ok = RegisterHotKey(handle, id, mods, vk); });
        return ok;
    }

    public static string Describe(IntPtr h)
    {
        if (h == IntPtr.Zero) return "none";
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        uint pid; GetWindowThreadProcessId(h, out pid);
        string name = "?";
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch { }
        return name + ":" + sb.ToString() + (h == handle ? "(QA-other)" : "");
    }

    public static string Status()
    {
        return "fg=" + Describe(GetForegroundWindow()) + " otherOpen=" + (form != null) + " otherFg=" + IsForeground() + " hotkeyHits=" + HotkeyHits + " text='" + Text().Replace("\r\n", "\\n") + "'";
    }

    /// Whether a popup menu (class #32768) is showing, and whose it is.
    public static string Menu()
    {
        var h = FindWindow("#32768", null);
        return "menu=" + (h != IntPtr.Zero && IsWindowVisible(h) ? Describe(h) : "none");
    }

    public static void MinimizeVoyager() { ShowWindow(Voy.MainWindow(), 6); }

    public static IntPtr Handle { get { return handle; } }
}

// FV-7: a second probe-owned "other app" window, so Voyager can sit under two.
public static class OtherB
{
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Other.POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, int data, UIntPtr extra);

    static Form form;
    static IntPtr handle = IntPtr.Zero;
    public static IntPtr Handle { get { return handle; } }

    public static void Open(int x, int y, int w, int h)
    {
        if (form != null) return;
        var ready = new ManualResetEvent(false);
        var t = new Thread(() =>
        {
            form = new Form();
            form.Text = "VoyagerQA Other App B";
            form.StartPosition = FormStartPosition.Manual;
            form.Bounds = new Rectangle(x, y, w, h);
            form.TopMost = true;
            form.ShowInTaskbar = true;
            form.BackColor = Color.DarkOliveGreen;
            form.Shown += (s, e) => { handle = form.Handle; ready.Set(); };
            Application.Run(form);
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        ready.WaitOne(5000);
        Thread.Sleep(300);
    }

    public static void SetTopmost(bool on) { if (form != null) form.Invoke((Action)(() => { form.TopMost = on; })); }

    public static void Close() { if (form != null) { form.Invoke((Action)(() => form.Close())); form = null; handle = IntPtr.Zero; } }

    public static void Click(int dx, int dy)
    {
        if (form == null) throw new InvalidOperationException("other window B not open");
        Rectangle b = Rectangle.Empty;
        form.Invoke((Action)(() => { b = form.Bounds; }));
        var p = new Other.POINT { X = dx >= 0 ? b.X + dx : b.X + b.Width / 2, Y = dy >= 0 ? b.Y + dy : b.Y + b.Height / 2 };
        var under = GetAncestor(WindowFromPoint(p), 2);
        if (under != handle) throw new InvalidOperationException("GUARD: the window under (" + p.X + "," + p.Y + ") is not the QA other-app form B (" + Other.Describe(under) + ")");
        SetCursorPos(p.X, p.Y);
        Thread.Sleep(60);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(40);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(120);
    }
}

// FV-7: the top-to-bottom order of Voyager's main window and the two probe forms.
public static class ZOrder
{
    [DllImport("user32.dll")] static extern IntPtr GetTopWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    public static string Of()
    {
        var main = Voy.MainWindow();
        var parts = new System.Collections.Generic.List<string>();
        for (var h = GetTopWindow(IntPtr.Zero); h != IntPtr.Zero; h = GetWindow(h, 2))
        {
            if (h == Other.Handle) parts.Add("A");
            else if (h == OtherB.Handle) parts.Add("B");
            else if (h == main)
            {
                RECT r; GetWindowRect(h, out r);
                parts.Add("Voyager[" + (IsWindowVisible(h) ? "" : "hidden ") + (r.R - r.L) + "x" + (r.B - r.T) + "]");
            }
        }
        return "z: " + string.Join(" > ", parts.ToArray());
    }
}
