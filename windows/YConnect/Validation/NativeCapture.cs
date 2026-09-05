using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using YConnect.Native;
using Drawing = System.Drawing;

namespace YConnect.Validation
{
    public static class NativeCapture
    {
        [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out Rect rectangle);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
        // Captures only this application's HWND, over a controlled opaque WPF
        // backdrop. It validates DWM/layered-window alpha, not just a visual tree.
        public static async Task Save(Window window, string path, bool darkBackdrop = false)
        {
            window.Show(); window.UpdateLayout(); var handle = new WindowInteropHelper(window).Handle;
            if (!GetWindowRect(handle, out var bounds)) throw new InvalidOperationException("Native window bounds unavailable");
            var scale = VisualTreeHelper.GetDpi(window).DpiScaleX;
            var backdrop = new Window { Title = "YConnect render validation backdrop", Width = (bounds.Right - bounds.Left + 32) / scale, Height = (bounds.Bottom - bounds.Top + 32) / scale, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, ShowActivated = false, Topmost = false, Background = new SolidColorBrush(darkBackdrop ? Color.FromRgb(28, 38, 48) : Color.FromRgb(217, 229, 236)) };
            var oldTopmost = window.Topmost;
            try
            {
                backdrop.Show(); WindowsDesktop.Move(backdrop, bounds.Left - 16, bounds.Top - 16); window.Topmost = true;
                SetWindowPos(handle, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10); window.Activate(); await Task.Delay(350);
                using (var bitmap = new Drawing.Bitmap(bounds.Right - bounds.Left, bounds.Bottom - bounds.Top))
                using (var graphics = Drawing.Graphics.FromImage(bitmap))
                {
                    graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bitmap.Size, Drawing.CopyPixelOperation.SourceCopy);
                    var samples = new[] { bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 4).ToArgb(), bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2).ToArgb(), bitmap.GetPixel(bitmap.Width / 2, bitmap.Height * 3 / 4).ToArgb(), bitmap.GetPixel(bitmap.Width / 4, bitmap.Height / 2).ToArgb() };
                    if (System.Linq.Enumerable.Distinct(samples).Count() == 1) throw new InvalidOperationException("Native capture was occluded or empty; retry on the unlocked desktop");
                    bitmap.Save(path, Drawing.Imaging.ImageFormat.Png);
                }
            }
            finally { backdrop.Close(); window.Topmost = oldTopmost; }
        }
    }
}
