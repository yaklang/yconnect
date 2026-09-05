using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using YConnect.Native;
using Forms = System.Windows.Forms;

namespace YConnect.Validation
{
    // Test-only pointer input is restricted to this demo process's visible HWND.
    // Never accepts an arbitrary external window or a production application.
    internal static class NativeInput
    {
        [StructLayout(LayoutKind.Sequential)] private struct PointNative { public int X, Y; }
        [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(PointNative point);
        [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
        private static void Check(Window window, int x, int y)
        {
            if (!((App)Application.Current).Controller.Store.Environment.Demo) throw new InvalidOperationException("Pointer validation requires demo isolation");
            var handle = new WindowInteropHelper(window).Handle;
            GetWindowThreadProcessId(handle, out var process);
            if (process != Process.GetCurrentProcess().Id || !window.IsVisible || !WindowsDesktop.Bounds(window).Contains(x, y)) throw new InvalidOperationException("Pointer target is outside this test window");
            if (GetAncestor(WindowFromPoint(new PointNative { X = x, Y = y }), 2) != handle) throw new InvalidOperationException("Pointer target is occluded; native interaction was not attempted");
        }
        internal static async Task Drag(Window window, FrameworkElement source, int dx, int dy)
        {
            var point = source.PointToScreen(new Point(Math.Max(1, source.ActualWidth / 2), Math.Max(1, source.ActualHeight / 2)));
            var x = (int)point.X; var y = (int)point.Y; Check(window, x, y);
            var original = Forms.Cursor.Position;
            try
            {
                SetCursorPos(x, y); await Task.Delay(80); Check(window, x, y);
                await Task.Run(() =>
                {
                    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
                    try
                    {
                        Thread.Sleep(90);
                        for (var i = 1; i <= 20; i++) { SetCursorPos(x + dx * i / 20, y + dy * i / 20); Thread.Sleep(16); }
                        Thread.Sleep(60);
                    }
                    finally { mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); }
                });
                await Task.Delay(350);
            }
            finally
            {
                var current = Forms.Cursor.Position;
                if (Math.Abs(current.X - (x + dx)) < 3 && Math.Abs(current.Y - (y + dy)) < 3) SetCursorPos(original.X, original.Y);
            }
        }
        internal static async Task Click(Window window, FrameworkElement source)
        {
            var point = source.PointToScreen(new Point(source.ActualWidth / 2, source.ActualHeight / 2));
            var x = (int)point.X; var y = (int)point.Y; Check(window, x, y);
            SetCursorPos(x, y); await Task.Delay(60); Check(window, x, y);
            mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
            try { await Task.Delay(40); } finally { mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); }
        }
    }
}
