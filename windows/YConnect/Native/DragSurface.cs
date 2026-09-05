using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace YConnect.Native
{
    public static class DragSurface
    {
        public static bool IsInteractive(DependencyObject source)
        {
            for (var node = source; node != null; node = node is Visual ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
                if (node is ButtonBase || node is TextBoxBase || node is PasswordBox || node is Selector || node is Thumb || node is ScrollBar || node is Hyperlink) return true;
            return false;
        }
        public static void Attach(Window window, UIElement surface, Action starting = null, Action finished = null)
        {
            Point? down = null;
            surface.PreviewMouseLeftButtonDown += (s, e) =>
            {
                if (IsInteractive(e.OriginalSource as DependencyObject)) return;
                down = e.GetPosition(window);
                if (e.ClickCount == 2 && window.ResizeMode == ResizeMode.CanResize) { down = null; window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; e.Handled = true; }
            };
            surface.PreviewMouseLeftButtonUp += (s, e) => down = null;
            surface.PreviewMouseMove += (s, e) =>
            {
                if (!down.HasValue || e.LeftButton != MouseButtonState.Pressed) { down = null; return; }
                var delta = e.GetPosition(window) - down.Value;
                if (Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance) return;
                down = null; starting?.Invoke();
                try { window.DragMove(); } catch (InvalidOperationException) { } finally { finished?.Invoke(); }
            };
        }
    }
}
