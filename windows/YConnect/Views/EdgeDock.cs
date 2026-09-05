using System;
using System.Windows;
using System.Windows.Controls;
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
        private readonly DropShadowEffect glow;
        private readonly DispatcherTimer proximity = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        private DateTime? nearSince, outsideSince;
        private bool dragging, near, previousBusy;
        private int downY, startingTop;
        public BalancePeekWindow Peek { get; }
        public bool IsDragging => dragging;
        public EdgeDock(AppController controller)
        {
            this.controller = controller; Title = "YConnect · 屏幕边缘入口"; Width = 30; Height = 112; AllowsTransparency = true; Background = Brushes.Transparent; WindowStyle = WindowStyle.None; ShowInTaskbar = false; Topmost = true; ShowActivated = false; ResizeMode = ResizeMode.NoResize;
            Peek = new BalancePeekWindow(controller);
            var grid = new Grid { Background = Brushes.Transparent }; Content = grid;
            dots = Ui.Glyph("\uE712", 14, "Accent"); dots.HorizontalAlignment = HorizontalAlignment.Center; dots.Opacity = 0;
            glow = new DropShadowEffect { Color = Color.FromRgb(199, 106, 85), BlurRadius = 12, ShadowDepth = 0, Opacity = .18 };
            tab = new Border { Width = 6, Height = 68, CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Child = dots, Background = Ui.Brush("Accent"), Effect = glow, Margin = new Thickness(2) }; grid.Children.Add(tab);
            SourceInitialized += (s, e) => { WindowsDesktop.NonActivating(this); controller.PositionAll(); };
            grid.MouseEnter += (s, e) => SetNear(true);
            grid.MouseLeftButtonDown += (s, e) => { dragging = false; downY = Forms.Cursor.Position.Y; startingTop = WindowsDesktop.Bounds(this).Top; Mouse.Capture(grid); e.Handled = true; };
            grid.MouseMove += (s, e) =>
            {
                if (!grid.IsMouseCaptured || e.LeftButton != MouseButtonState.Pressed) return;
                var delta = Forms.Cursor.Position.Y - downY;
                if (Math.Abs(delta) <= SystemParameters.MinimumVerticalDragDistance && !dragging) return;
                dragging = true; Peek.HideImmediately();
                controller.ActiveScreen = Forms.Screen.FromPoint(Forms.Cursor.Position);
                var screen = controller.ActiveScreen; var scale = WindowsDesktop.Scale(screen);
                var height = (int)Math.Round(Height * scale);
                var y = (int)WindowsDesktop.Clamp(startingTop + delta, screen.WorkingArea.Top + 4, screen.WorkingArea.Bottom - height - 4);
                controller.Store.Preferences.YPercent = (y + height / 2.0 - screen.WorkingArea.Top) / screen.WorkingArea.Height * 100;
                var bounds = WindowsDesktop.EdgeBounds(screen.WorkingArea, scale, controller.Store.Preferences.OnLeft, controller.Store.Preferences.YPercent);
                WindowsDesktop.Move(this, bounds.X, y);
                if (controller.Widget.IsVisible) controller.PositionWidget();
            };
            grid.MouseLeftButtonUp += (s, e) =>
            {
                var moved = dragging; dragging = false; grid.ReleaseMouseCapture(); e.Handled = true;
                if (moved) { controller.Store.SavePreferences(); controller.PositionAll(); }
                else { CloseQuick(); controller.ToggleWidget(); }
            };
            grid.LostMouseCapture += (s, e) => { if (dragging) { dragging = false; controller.Store.SavePreferences(); } };
            grid.MouseRightButtonUp += (s, e) =>
            {
                CloseQuick(); var menu = new ContextMenu();
                foreach (var left in new[] { true, false })
                {
                    var side = left; var item = new MenuItem { Header = left ? "贴屏幕左侧" : "贴屏幕右侧", IsCheckable = true, IsChecked = controller.Store.Preferences.OnLeft == left };
                    item.Click += (a, b) => { controller.Store.Preferences.OnLeft = side; controller.Store.SavePreferences(); controller.PositionAll(); }; menu.Items.Add(item);
                }
                menu.Items.Add(new Separator());
                var open = new MenuItem { Header = "打开管理中心" }; open.Click += (a, b) => controller.ShowManager("overview"); menu.Items.Add(open);
                var hide = new MenuItem { Header = "隐藏边缘入口" }; hide.Click += (a, b) => { controller.Store.Preferences.EdgeEnabled = false; controller.Store.SavePreferences(); controller.PositionAll(); }; menu.Items.Add(hide);
                menu.IsOpen = true; e.Handled = true;
            };
            proximity.Tick += (s, e) => SampleProximity(Forms.Cursor.Position, DateTime.UtcNow);
            IsVisibleChanged += (s, e) => { if (IsVisible) proximity.Start(); else { proximity.Stop(); CloseQuick(); } };
            Closing += (s, e) => { if (!controller.Quitting) { e.Cancel = true; Hide(); } else proximity.Stop(); };
        }
        public void SampleProximity(System.Drawing.Point point, DateTime now)
        {
            if (!IsVisible || dragging || controller.Widget.IsVisible || !controller.Store.Preferences.BalancePeekEnabled || WindowsDesktop.FullScreenOtherApp(controller.ActiveScreen)) { CloseQuick(); SetNear(false); return; }
            var scale = WindowsDesktop.Scale(controller.ActiveScreen);
            var distance = WindowsDesktop.Distance(WindowsDesktop.Bounds(this), point);
            var insidePeek = Peek.IsVisible && WindowsDesktop.Distance(WindowsDesktop.Bounds(Peek), point) < 20 * scale;
            if (distance < 88 * scale || insidePeek)
            {
                outsideSince = null; if (!nearSince.HasValue) nearSince = now; SetNear(true);
                if (now - nearSince.Value >= TimeSpan.FromMilliseconds(200)) Peek.Reveal();
            }
            else if (distance > 130 * scale)
            {
                nearSince = null; if (!outsideSince.HasValue) outsideSince = now;
                if (now - outsideSince.Value > TimeSpan.FromMilliseconds(300)) { Peek.Hide(); SetNear(false); }
            }
        }
        private void SetNear(bool value)
        {
            if (near == value) return; near = value;
            if (Motion.Allowed)
            {
                tab.BeginAnimation(WidthProperty, new DoubleAnimation(value ? 18 : 6, TimeSpan.FromMilliseconds(180)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
                dots.BeginAnimation(OpacityProperty, new DoubleAnimation(value ? 1 : 0, TimeSpan.FromMilliseconds(140)));
                if (value) Pulse();
            }
            else { tab.BeginAnimation(WidthProperty, null); dots.BeginAnimation(OpacityProperty, null); tab.Width = value ? 18 : 6; dots.Opacity = value ? 1 : 0; }
            tab.Background = Ui.Brush(value ? "AccentSoft" : "Accent");
        }
        private void Pulse()
        {
            if (!Motion.Allowed) return;
            glow.BeginAnimation(DropShadowEffect.OpacityProperty, new DoubleAnimation(.16, .6, TimeSpan.FromMilliseconds(800)) { AutoReverse = true, RepeatBehavior = new RepeatBehavior(2), EasingFunction = new SineEase() });
        }
        public void Refresh()
        {
            if (Peek.IsVisible) Peek.Render();
            if (previousBusy && !controller.Store.Busy) Pulse(); previousBusy = controller.Store.Busy;
            if (!Motion.Allowed) { glow.BeginAnimation(DropShadowEffect.OpacityProperty, null); tab.BeginAnimation(WidthProperty, null); dots.BeginAnimation(OpacityProperty, null); tab.Width = near ? 18 : 6; dots.Opacity = near ? 1 : 0; }
            tab.Background = Ui.Brush(near ? "AccentSoft" : "Accent");
        }
        public void AlignSide() { tab.HorizontalAlignment = controller.Store.Preferences.OnLeft ? HorizontalAlignment.Left : HorizontalAlignment.Right; if (Peek.IsVisible) Peek.Position(); }
        public void CloseQuick() { Peek.HideImmediately(); nearSince = null; outsideSince = null; }
        public void Stop() { proximity.Stop(); Peek.HideImmediately(); }
    }
}
