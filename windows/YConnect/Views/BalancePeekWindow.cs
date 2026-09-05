using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using YConnect.Core;
using YConnect.Native;

namespace YConnect.Views
{
    public sealed class BalancePeekWindow : Window
    {
        private readonly AppController controller;
        private readonly Border shell;
        private readonly Motion motion;
        private bool closing;
        public BalancePeekWindow(AppController controller)
        {
            this.controller = controller;
            Title = "YConnect · 余额速览"; Width = 260; SizeToContent = SizeToContent.Height; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
            AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true; ShowActivated = false; ShowInTaskbar = false;
            shell = Ui.Card(new Border(), 16); shell.CornerRadius = new CornerRadius(17); shell.Margin = new Thickness(10);
            shell.Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = .16, Color = Colors.Black };
            Content = shell; motion = new Motion(shell);
            SourceInitialized += (s, e) => WindowsDesktop.NonActivating(this);
            Closing += (s, e) => { if (!controller.Quitting) { e.Cancel = true; Hide(); } };
            Render();
        }
        public void Render()
        {
            var store = controller.Store; var balance = BalancePresentation.From(store, store.Preferences.PeekPercentageOnly);
            var title = Ui.Between(Ui.Row(Ui.Logo(21), new Border { Width = 8 }, Ui.Text("YConnect", 12, "Ink", true)), Ui.Text(store.Environment.Demo ? "演示" : balance.Stale ? "待同步" : "●", 10, balance.Stale ? "Muted" : "Green"));
            var open = Ui.Button("", "peek-open-widget", controller.ShowWidget, "Quiet"); open.Padding = new Thickness(0); open.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            open.Content = Ui.Between(Ui.Stack(Ui.Text(balance.Label, 10, "Muted"), Ui.Gap(3), Ui.Id(Ui.Text(balance.Value, store.Authenticated ? 27 : 20, "Ink", true), "peek-balance-value")), Ui.Glyph("\uE76C", 13));
            open.ToolTip = "打开连接面板";
            shell.Child = Ui.Stack(title, Ui.Gap(12), open, Ui.Gap(10), Ui.QuotaBar(balance.Percent, 3), Ui.Gap(8), Ui.Text(balance.Stale ? "上次同步的额度 · 打开后刷新" : "轻点打开 · 移开即收起", 9, "Muted"));
        }
        public void Reveal()
        {
            if (IsVisible && !closing) return;
            closing = false; Render(); Show(); UpdateLayout(); Position(); motion.Show(5);
        }
        public void Position()
        {
            var screen = controller.ActiveScreen; var scale = WindowsDesktop.Scale(screen);
            var edge = WindowsDesktop.EdgeBounds(screen.WorkingArea, scale, controller.Store.Preferences.OnLeft, controller.Store.Preferences.YPercent);
            var target = WindowsDesktop.WidgetBounds(screen.WorkingArea, edge, scale, controller.Store.Preferences.OnLeft, ActualWidth, ActualHeight);
            WindowsDesktop.Move(this, target.X, target.Y);
        }
        public new void Hide() { if (IsVisible && !closing) { closing = true; motion.Hide(() => { base.Hide(); closing = false; }); } }
        public void HideImmediately() { closing = false; motion.Cancel(); base.Hide(); }
    }
}
