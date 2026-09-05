using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace YConnect.Native
{
    public static class WindowsDesktop
    {
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
