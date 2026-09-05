using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Diagnostics;
using System.Text;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace YConnect.Native
{
    public static class WindowsDesktop
    {
        [StructLayout(LayoutKind.Sequential)] private struct RectNative { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out RectNative rectangle);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
        private static readonly int ownProcess = Process.GetCurrentProcess().Id;
        [StructLayout(LayoutKind.Sequential)] private struct PointNative { public int X, Y; }
        [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(PointNative point, uint flags);
        [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] private static extern int GetWindowLong(IntPtr handle, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] private static extern int SetWindowLong(IntPtr handle, int index, int value);
        public static double Scale(Forms.Screen screen)
        {
            var p = new PointNative { X = screen.Bounds.Left + screen.Bounds.Width / 2, Y = screen.Bounds.Top + screen.Bounds.Height / 2 };
            try { return GetDpiForMonitor(MonitorFromPoint(p, 2), 0, out var x, out var y) == 0 ? x / 96.0 : 1; } catch { return 1; }
        }
        public static void Move(Window window, int x, int y)
        {
            var handle = new WindowInteropHelper(window).Handle; if (handle != IntPtr.Zero) SetWindowPos(handle, IntPtr.Zero, x, y, 0, 0, 0x1 | 0x4 | 0x10 | 0x200);
        }
        public static void NonActivating(Window window)
        {
            var handle = new WindowInteropHelper(window).Handle; if (handle == IntPtr.Zero) return;
            var flags = GetWindowLong(handle, -20); SetWindowLong(handle, -20, flags | 0x08000000 | 0x00000080);
        }
        public static double Clamp(double value, double min, double max) => Math.Max(min, Math.Min(value, Math.Max(min, max)));
        public static System.Drawing.Rectangle Bounds(Window window)
        {
            if (!GetWindowRect(new WindowInteropHelper(window).Handle, out var r)) return System.Drawing.Rectangle.Empty;
            return System.Drawing.Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        }
        public static bool FullScreenOtherApp(Forms.Screen screen)
        {
            var handle = GetForegroundWindow(); GetWindowThreadProcessId(handle, out var process);
            if (process == ownProcess || !GetWindowRect(handle, out var r)) return false;
            var name = new StringBuilder(128); GetClassName(handle, name, name.Capacity);
            if (name.ToString() == "Progman" || name.ToString() == "WorkerW") return false;
            var bounds = screen.Bounds; return r.Left <= bounds.Left && r.Top <= bounds.Top && r.Right >= bounds.Right && r.Bottom >= bounds.Bottom;
        }
        public static double Distance(System.Drawing.Rectangle rectangle, System.Drawing.Point point)
        {
            var dx = Math.Max(0, Math.Max(rectangle.Left - point.X, point.X - rectangle.Right));
            var dy = Math.Max(0, Math.Max(rectangle.Top - point.Y, point.Y - rectangle.Bottom)); return Math.Sqrt(dx * dx + dy * dy);
        }
        public static void Glide(Window window, int x, int y, bool animated, Action complete)
        {
            if (!animated) { Move(window, x, y); complete(); return; }
            var start = Bounds(window); var watch = Stopwatch.StartNew();
            var timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(16) };
            timer.Tick += (s, e) => { var t = Math.Min(1, watch.Elapsed.TotalMilliseconds / 180); var eased = 1 - Math.Pow(1 - t, 3); Move(window, (int)Math.Round(start.X + (x - start.X) * eased), (int)Math.Round(start.Y + (y - start.Y) * eased)); if (t >= 1) { timer.Stop(); complete(); } }; timer.Start();
        }
        public static System.Drawing.Rectangle EdgeBounds(System.Drawing.Rectangle work, double scale, bool left, double percent)
        {
            var width = (int)Math.Round(30 * scale); var height = (int)Math.Round(112 * scale); var y = (int)Math.Round(Clamp(work.Top + work.Height * percent / 100 - height / 2.0, work.Top + 4, work.Bottom - height - 4));
            return new System.Drawing.Rectangle(left ? work.Left : work.Right - width, y, width, height);
        }
        public static System.Drawing.Rectangle WidgetBounds(System.Drawing.Rectangle work, System.Drawing.Rectangle edge, double scale, bool left, double width, double height)
        {
            var w = (int)Math.Round(Math.Min(width * scale, work.Width - 16)); var h = (int)Math.Round(Math.Min(height * scale, work.Height - 16));
            return new System.Drawing.Rectangle((int)Clamp(left ? edge.Right + 2 : edge.Left - w - 2, work.Left + 4, work.Right - w - 4), (int)Clamp(edge.Top + edge.Height / 2.0 - h / 2.0, work.Top + 8, work.Bottom - h - 8), w, h);
        }
    }
}
