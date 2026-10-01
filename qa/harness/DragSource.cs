// Phase 7: probe-owned drag source. Opens a small WinForms window, presses the
// left button on it, starts a real OLE drag (DoDragDrop) of one or more files
// (CF_HDROP, as Explorer does), glides the cursor to a point in Voyager's
// client area and releases there. The release only happens if the window under
// the target point belongs to voyager.exe; otherwise the drag is carried back
// to the form and released there (cancelled). C# 5 only (Add-Type).
using System;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public static class DragSource
{
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mi; }
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;

    static void Button(uint flag)
    {
        var i = new INPUT[1];
        i[0].type = 0; i[0].mi.dwFlags = flag;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    static string OwnerAt(int x, int y)
    {
        var p = new POINT(); p.X = x; p.Y = y;
        var root = GetAncestor(WindowFromPoint(p), 2);
        uint pid; GetWindowThreadProcessId(root, out pid);
        try { return Process.GetProcessById((int)pid).ProcessName; } catch { return "?"; }
    }

    static void Glide(int x0, int y0, int x1, int y1, int steps)
    {
        for (int s = 1; s <= steps; s++)
        {
            SetCursorPos(x0 + (x1 - x0) * s / steps, y0 + (y1 - y0) * s / steps);
            Thread.Sleep(15);
        }
    }

    /// Drags [files] from a form at (fx,fy) to screen point (tx,ty).
    /// Returns a log line: the effect DoDragDrop reported and who owned the target.
    public static string Run(string[] files, int fx, int fy, int tx, int ty, int hoverMs)
    {
        SetProcessDPIAware();
        string log = "";
        var form = new Form();
        form.Text = "QA drag source";
        form.StartPosition = FormStartPosition.Manual;
        form.Location = new Point(fx, fy);
        form.Size = new Size(420, 260);
        form.TopMost = true;
        form.BackColor = Color.LightSteelBlue;
        var label = new Label(); label.Dock = DockStyle.Fill; label.Text = "QA drag source\n" + string.Join("\n", files);
        form.Controls.Add(label);
        int sx = fx + 200, sy = fy + 150;
        Thread worker = null;
        bool started = false;
        label.MouseDown += delegate
        {
            if (started) return;
            started = true;
            var data = new DataObject();
            var sc = new StringCollection(); sc.AddRange(files);
            data.SetFileDropList(sc);
            var effect = label.DoDragDrop(data, DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link);
            if (worker != null) worker.Join(8000);
            log += "effect=" + effect;
            form.Close();
        };
        var safety = new System.Windows.Forms.Timer(); safety.Interval = 12000;
        safety.Tick += delegate { safety.Stop(); log += "TIMEOUT(mousedown=" + started + ") "; form.Close(); };
        safety.Start();
        form.Shown += delegate
        {
            form.Activate();
            log += "shown@" + form.Location + " ";
            var t = new System.Windows.Forms.Timer(); t.Interval = 400;
            t.Tick += delegate
            {
                t.Stop();
                SetCursorPos(sx, sy);
                worker = new Thread(delegate ()
                {
                    Thread.Sleep(150);
                    Button(LEFTDOWN);
                    Thread.Sleep(300);
                    Glide(sx, sy, sx - 40, sy - 40, 5);
                    Glide(sx - 40, sy - 40, tx, ty, 40);
                    Thread.Sleep(hoverMs);
                    string owner = OwnerAt(tx, ty);
                    log += "owner@target=" + owner + " ";
                    if (owner != "voyager")
                    {
                        Glide(tx, ty, sx, sy, 20);
                        log += "(cancelled over own form) ";
                    }
                    Button(LEFTUP);
                    Thread.Sleep(200);
                });
                worker.IsBackground = true;
                worker.Start();
            };
            t.Start();
        };
        Application.Run(form);
        return log;
    }
}
