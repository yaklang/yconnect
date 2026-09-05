using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using YConnect.Native;
using Forms = System.Windows.Forms;

namespace YConnect.Views
{
    public sealed class EdgeDock : Window
    {
        private readonly AppController controller;
        private readonly Border tab;
        private readonly TextBlock dots;
        private readonly Popup quick;
        private readonly DispatcherTimer hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        private bool dragging;
        private int downY;
        private double startPercent;
        public EdgeDock(AppController controller)
        {
            this.controller = controller; Title = "YConnect · 屏幕边缘入口"; Width = 30; Height = 112; AllowsTransparency = true; Background = Brushes.Transparent; WindowStyle = WindowStyle.None; ShowInTaskbar = false; Topmost = true; ShowActivated = false; ResizeMode = ResizeMode.NoResize;
            var grid = new Grid { Background = Brushes.Transparent }; Content = grid;
            dots = Ui.Text("•\n•\n•", 11); dots.Foreground = Brushes.White; dots.TextAlignment = TextAlignment.Center; dots.VerticalAlignment = VerticalAlignment.Center; dots.Opacity = 0;
            tab = new Border { Width = 9, Height = 76, CornerRadius = new CornerRadius(5), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Child = dots, Background = Ui.Brush("Accent"), Effect = new DropShadowEffect { Color = Color.FromRgb(185, 105, 83), BlurRadius = 7, ShadowDepth = 0, Opacity = .25 } }; grid.Children.Add(tab);
            var widget = Ui.Button("打开小组件", "edge-open-widget", () => { quick.IsOpen = false; controller.ShowWidget(); }); widget.FontSize = 11;
            var manager = Ui.Button("管理中心", "edge-open-manager", () => { quick.IsOpen = false; controller.ShowManager("overview"); }, "Quiet"); manager.FontSize = 11;
            var actions = Ui.Card(Ui.Stack(widget, manager), 7); actions.Width = 132;
            quick = new Popup { Child = actions, PlacementTarget = this, Placement = PlacementMode.Left, AllowsTransparency = true, StaysOpen = true, PopupAnimation = PopupAnimation.Fade };
            actions.MouseEnter += (s, e) => hideTimer.Stop(); actions.MouseLeave += (s, e) => hideTimer.Start(); hideTimer.Tick += (s, e) => { quick.IsOpen = false; hideTimer.Stop(); };
            SourceInitialized += (s, e) => { WindowsDesktop.NonActivating(this); controller.PositionAll(); };
            grid.MouseEnter += (s, e) => { if (dragging) return; hideTimer.Stop(); tab.BeginAnimation(WidthProperty, new DoubleAnimation(20, TimeSpan.FromMilliseconds(130))); dots.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(120))); if (!controller.Widget.IsVisible) { quick.Placement = controller.Store.Preferences.OnLeft ? PlacementMode.Right : PlacementMode.Left; quick.IsOpen = true; } };
            grid.MouseLeave += (s, e) => { if (dragging) return; tab.BeginAnimation(WidthProperty, new DoubleAnimation(9, TimeSpan.FromMilliseconds(150))); dots.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(100))); hideTimer.Start(); };
            grid.MouseLeftButtonDown += (s, e) => { dragging = false; downY = Forms.Cursor.Position.Y; startPercent = controller.Store.Preferences.YPercent; Mouse.Capture(grid); e.Handled = true; };
            grid.MouseMove += (s, e) =>
            {
                if (!grid.IsMouseCaptured || e.LeftButton != MouseButtonState.Pressed) return; var delta = Forms.Cursor.Position.Y - downY; if (Math.Abs(delta) > 4) dragging = true;
                if (!dragging) return; quick.IsOpen = false; controller.ActiveScreen = Forms.Screen.FromPoint(Forms.Cursor.Position);
                controller.Store.Preferences.YPercent = WindowsDesktop.Clamp(startPercent + delta / (double)controller.ActiveScreen.WorkingArea.Height * 100, 2, 98); controller.PositionAll();
            };
            grid.MouseLeftButtonUp += (s, e) =>
            {
                var moved = dragging; dragging = false; grid.ReleaseMouseCapture(); e.Handled = true;
                if (moved) { controller.Store.SavePreferences(); }
                else Dispatcher.BeginInvoke(new Action(() => { quick.IsOpen = false; controller.ToggleWidget(); }), DispatcherPriority.ContextIdle);
            };
            grid.LostMouseCapture += (s, e) => { if (dragging) { dragging = false; controller.Store.SavePreferences(); } };
            grid.MouseRightButtonUp += (s, e) =>
            {
                var menu = new ContextMenu(); var left = new MenuItem { Header = "贴屏幕左侧", IsCheckable = true, IsChecked = controller.Store.Preferences.OnLeft }; var right = new MenuItem { Header = "贴屏幕右侧", IsCheckable = true, IsChecked = !controller.Store.Preferences.OnLeft };
                left.Click += (a, b) => Side(true); right.Click += (a, b) => Side(false); menu.Items.Add(left); menu.Items.Add(right); menu.Items.Add(new Separator());
                var move = new MenuItem { Header = "移至鼠标所在显示器" }; move.Click += (a, b) => { controller.ActiveScreen = Forms.Screen.FromPoint(Forms.Cursor.Position); controller.PositionAll(); }; menu.Items.Add(move);
                var hide = new MenuItem { Header = "隐藏边缘入口" }; hide.Click += (a, b) => { controller.Store.Preferences.EdgeEnabled = false; controller.Store.SavePreferences(); controller.PositionAll(); }; menu.Items.Add(hide); menu.IsOpen = true; e.Handled = true;
            };
            Closing += (s, e) => { if (!controller.Quitting) { e.Cancel = true; Hide(); } };
        }
        private void Side(bool left) { controller.Store.Preferences.OnLeft = left; controller.Store.SavePreferences(); controller.PositionAll(); }
        public void AlignSide() { tab.HorizontalAlignment = controller.Store.Preferences.OnLeft ? HorizontalAlignment.Left : HorizontalAlignment.Right; }
        public void CloseQuick() => quick.IsOpen = false;
    }
}
