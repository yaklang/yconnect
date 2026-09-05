using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Animation;
using Newtonsoft.Json.Linq;
using YConnect.Core;
using YConnect.Native;

namespace YConnect.Views
{
    public sealed class WidgetWindow : Window
    {
        private readonly AppController controller;
        private readonly ScrollViewer scroll = new ScrollViewer();
        private readonly Border shell;
        private readonly Motion motion;
        private bool closing;
        private readonly ConnectionPanel connection;
        public bool KeyLoginMode { get; set; }
        public bool IsDragging { get; set; }
        public string ExpandedSection => connection.ExpandedSection;
        public WidgetWindow(AppController controller)
        {
            this.controller = controller; Title = "YConnect · 桌面连接"; Width = 400; WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ResizeMode = ResizeMode.NoResize; SizeToContent = SizeToContent.Height;
            shell = Ui.Card(scroll, 14); shell.CornerRadius = new CornerRadius(20); shell.Margin = new Thickness(10); shell.Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 18, ShadowDepth = 4, Opacity = .16 }; Content = shell; motion = new Motion(shell);
            DragSurface.Attach(this, shell, () => { IsDragging = true; controller.Edge.CloseQuick(); }, controller.CommitWidgetDrag);
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape) { Hide(); e.Handled = true; } };
            SizeChanged += (s, e) => { if (!IsDragging) controller.PositionWidget(); };
            Deactivated += (s, e) => Dispatcher.BeginInvoke(new Action(() => { if (!controller.Store.Preferences.Pinned && !controller.ModalOpen && !IsActive && !IsDragging) Hide(); }), System.Windows.Threading.DispatcherPriority.Background);
            Closing += (s, e) => { if (!controller.Quitting) { e.Cancel = true; Hide(); } };
            connection = new ConnectionPanel(controller, "widget", AnimateConnectionChange);
            Render();
        }
        public void Reveal() { var wasClosing = closing; closing = false; var wasVisible = IsVisible; Show(); if (!wasVisible || wasClosing) motion.Show(); }
        public new void Hide() { if (!IsVisible || closing) return; closing = true; motion.Hide(() => { base.Hide(); closing = false; }); }
        public void SetMaximumHeight(double height) { scroll.MaxHeight = Math.Max(200, height - 58); }
        public void Render()
        {
            var store = controller.Store;
            var subtitle = store.Authenticated ? store.DisplayName + (store.Mode == "account" ? " · YakCool 账户" : " · API Key") : "让每一次连接，都刚刚好";
            var identity = Ui.Text(subtitle, 10, "Muted"); identity.MaxWidth = 175; identity.TextWrapping = TextWrapping.NoWrap; identity.TextTrimming = TextTrimming.CharacterEllipsis; identity.ToolTip = subtitle;
            var brand = Ui.Row(Ui.Logo(30), new Border { Width = 9 }, Ui.Stack(Ui.Text("YConnect", 17, "Ink", true), identity));
            var refresh = Ui.IconButton("\uE72C", "刷新连接", "widget-refresh", async () => await store.Run(store.Refresh)); refresh.IsEnabled = store.Authenticated && !store.Busy;
            var pin = Ui.IconButton("\uE718", store.Preferences.Pinned ? "取消固定" : "固定在桌面", "widget-pin", () => { store.Preferences.Pinned = !store.Preferences.Pinned; store.SavePreferences(); });
            pin.Background = store.Preferences.Pinned ? Ui.Brush("AccentSoft") : Brushes.Transparent;
            var content = Ui.Stack(Ui.Between(brand, Ui.Row(refresh, pin, Ui.IconButton("\uE711", "收起", "widget-close", Hide))), Ui.Gap(8));
            if (store.Environment.Demo) { content.Children.Add(Ui.Between(Ui.Text("体验预览", 10, "Accent", true), Ui.Text("演示数据 · 不修改真实配置", 9, "Muted"))); content.Children.Add(Ui.Gap(8)); }
            if (store.Mode == "restoring") content.Children.Add(Ui.Notice("正在安全恢复你的连接…"));
            else if (!store.Authenticated) content.Children.Add(LoginContent());
            else
            {
                content.Children.Add(BalanceCard()); content.Children.Add(Ui.Gap(8)); content.Children.Add(connection.Render()); content.Children.Add(Ui.Gap(10));
                content.Children.Add(Ui.Between(Ui.Text("已安装客户端", 11, "Muted", true), Ui.SmallButton("管理  ↗", "widget-all-clients", () => controller.ShowManager("clients"))));
                var installed = store.Clients.InstalledClients(store.Preferences.RecentClients);
                var visible = installed.Take(installed.Length > 4 ? 3 : 4).Select(d => (UIElement)QuickClient(d)).ToList();
                if (installed.Length > 4) visible.Add(Ui.Button("更多  ·  " + (installed.Length - 3), "widget-more-clients", () => controller.ShowManager("clients")));
                if (visible.Count == 0) content.Children.Add(Ui.Button("尚未发现客户端 · 打开管理中心检测", "widget-no-clients", () => controller.ShowManager("clients"), "Quiet"));
                else content.Children.Add(Ui.Columns(2, visible.ToArray()));
            }
            if (Ui.HasFeedback(store)) { content.Children.Add(Ui.Gap(8)); content.Children.Add(Ui.Feedback(store)); }
            content.Children.Add(Ui.Divider());
            var manage = Ui.Button("全部配置管理  →", "widget-manager", () => controller.ShowManager("overview"), "Quiet"); manage.HorizontalContentAlignment = HorizontalAlignment.Left; manage.Padding = new Thickness(0, 6, 0, 6);
            var logout = Ui.AsyncButton("登出", "widget-signout", controller.SignOut, "Quiet"); logout.FontSize = 11; logout.IsEnabled = store.Authenticated && !store.Busy;
            content.Children.Add(Ui.Between(manage, Ui.Row(Ui.IconButton("\uE713", "设置", "widget-settings", () => controller.ShowManager("settings")), logout)));
            content.Children.Add(Ui.Gap(4)); scroll.Content = content;
        }
        public FrameworkElement BalanceCard()
        {
            var store = controller.Store; var balance = BalancePresentation.From(store);
            var value = Ui.Id(Ui.Text(balance.Value, 24, "Ink", true), "widget-balance-value");
            var status = Ui.Stack(Ui.Text(store.Mode == "account" ? "● 账户已安全连接" : "● Key 已安全连接", 11, "Green", true), Ui.Gap(5), Ui.Text(balance.Label + (balance.Stale ? " · 待同步" : ""), 10, "Muted"));
            return Ui.Card(Ui.Stack(Ui.Between(status, value), Ui.Gap(10), Ui.QuotaBar(balance.Percent, 3)), 10, "SurfaceAlt");
        }
        private int expansionRevision;
        private void AnimateConnectionChange()
        {
            var before = scroll.ActualHeight; var revision = ++expansionRevision;
            scroll.BeginAnimation(HeightProperty, null); scroll.Height = double.NaN;
            Render();
            if (!Motion.Allowed || before <= 0) return;
            var body = (FrameworkElement)scroll.Content;
            body.Measure(new Size(Math.Max(1, scroll.ActualWidth), double.PositiveInfinity));
            var after = Math.Min(body.DesiredSize.Height, scroll.MaxHeight);
            scroll.Height = after;
            var animation = new DoubleAnimation(before, after, TimeSpan.FromMilliseconds(210)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            animation.Completed += (s, e) => { if (revision == expansionRevision) { scroll.BeginAnimation(HeightProperty, null); scroll.Height = double.NaN; } };
            scroll.BeginAnimation(HeightProperty, animation);
            Motion.Page(body);
        }
        private Button QuickClient(ClientDescriptor d)
        {
            var button = Ui.Button("", "widget-client-" + d.Id, () => { controller.Store.SelectClient(d.Id); controller.ShowManager("clients"); }); button.Padding = new Thickness(8, 5, 8, 5); button.MinHeight = 32; button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            button.Content = Ui.IconLabel(Ui.AppMark(d, 24), Ui.Label(d.Name, 12, "Ink", true), 24, 8); return button;
        }
        public FrameworkElement LoginContent()
        {
            var store = controller.Store;
            var account = Ui.Button("YAKCOOL 账户", "login-tab-account", () => { KeyLoginMode = false; Render(); }, KeyLoginMode ? "Quiet" : null);
            var api = Ui.Button("API Key", "login-tab-key", () => { KeyLoginMode = true; Render(); }, KeyLoginMode ? null : "Quiet");
            var content = Ui.Stack(Ui.Card(Ui.Columns(2, account, api), 4, "SurfaceAlt"), Ui.Gap(16), Ui.Text("连接你的无限可能。", 24, "Ink", true), Ui.Gap(10), Ui.Text(KeyLoginMode ? "用一把业务 Key，把模型带进你的工作流。" : "额度、模型与编程工具，从此触手可及。", 12, "Muted"), Ui.Gap(16));
            if (KeyLoginMode)
            {
                var input = Ui.Id(new PasswordBox { MaxLength = 512, MinHeight = 40 }, "login-key-input");
                var paste = Ui.SmallButton("粘贴", "login-key-paste", () => { try { if (Clipboard.ContainsText()) input.Password = Clipboard.GetText(); input.Focus(); } catch { store.SetError("暂时无法读取剪贴板，请手动粘贴"); } }); paste.MinHeight = 40; paste.Margin = new Thickness(8, 0, 0, 0);
                content.Children.Add(Ui.Text("业务 API Key", 11, "Muted", true)); content.Children.Add(Ui.Gap(8)); content.Children.Add(Ui.Between(input, paste)); content.Children.Add(Ui.Gap(8));
                Func<System.Threading.Tasks.Task> connect = async () => { var value = input.Password; input.Clear(); await store.Run(() => store.LoginKey(value)); };
                var button = Ui.AsyncButton("验证并连接  →", "login-key-connect", connect, "Primary"); button.IsEnabled = !store.Busy; content.Children.Add(button);
                input.KeyDown += async (s, e) => { if (e.Key == Key.Enter && !store.Busy) { await connect(); e.Handled = true; } };
                content.Children.Add(Ui.Gap(8)); content.Children.Add(Ui.Text("仅查询这把 Key 的额度与模型，不授予账户管理权限。", 10, "Muted"));
            }
            else
            {
                var button = Ui.AsyncButton("在 YConnect 内扫码  →", "login-account-connect", controller.LoginAccount, "Primary"); button.IsEnabled = !store.Busy; content.Children.Add(button); content.Children.Add(Ui.Gap(8));
                content.Children.Add(Ui.Text("YakCool 官方微信登录 · 凭证由 Windows 加密保护", 10, "Muted"));
            }
            if (store.CanRetrySession) { content.Children.Add(Ui.Gap(8)); content.Children.Add(Ui.AsyncButton("重试已保存的登录", "login-retry-session", async () => await store.Run(store.RestoreSession))); }
            content.Children.Add(Ui.Gap(8)); return content;
        }
    }
}
