using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using YConnect.Core;

namespace YConnect.Views
{
    public sealed class WidgetWindow : Window
    {
        private readonly AppController controller;
        private readonly ScrollViewer scroll = new ScrollViewer();
        private readonly Border shell;
        public bool KeyLoginMode { get; set; }
        private bool endpointsExpanded;
        public WidgetWindow(AppController controller)
        {
            this.controller = controller; Title = "YConnect · 桌面小组件"; Width = 408; WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ResizeMode = ResizeMode.NoResize; SizeToContent = SizeToContent.Height;
            shell = Ui.Card(scroll, 22); shell.CornerRadius = new CornerRadius(20); shell.Margin = new Thickness(9); shell.Effect = new DropShadowEffect { Color = Colors.Black, BlurRadius = 16, ShadowDepth = 3, Opacity = .14 }; Content = shell;
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape) { Hide(); e.Handled = true; } };
            SizeChanged += (s, e) => controller.PositionWidget();
            Deactivated += (s, e) => Dispatcher.BeginInvoke(new Action(() => { if (!controller.Store.Preferences.Pinned && !controller.ModalOpen && !IsActive) Hide(); }), System.Windows.Threading.DispatcherPriority.Background);
            Closing += (s, e) => { if (!controller.Quitting) { e.Cancel = true; Hide(); } };
            Render();
        }
        public void SetMaximumHeight(double height) { scroll.MaxHeight = Math.Max(220, height - 64); }
        public void Render()
        {
            var store = controller.Store;
            var brand = Ui.Row(Ui.Logo(32), new Border { Width = 10 }, Ui.Stack(Ui.Text("YConnect", 17, "Ink", true), Ui.Text("你的 AI 连接中心", 10, "Muted")));
            var pin = Ui.IconButton("\uE718", store.Preferences.Pinned ? "取消固定" : "固定小组件", "widget-pin", () => { store.Preferences.Pinned = !store.Preferences.Pinned; store.SavePreferences(); });
            pin.Background = store.Preferences.Pinned ? Ui.Brush("AccentSoft") : Brushes.Transparent;
            var header = Ui.Between(brand, Ui.Row(pin, Ui.IconButton("\uE711", "收起小组件", "widget-close", Hide)));
            var content = Ui.Stack(header, Ui.Gap(16));
            if (store.Environment.Demo) { content.Children.Add(Ui.Badge("演示数据 · 配置写入隔离目录", "Accent", "AccentSoft")); content.Children.Add(Ui.Gap(12)); }
            if (store.Mode == "restoring") content.Children.Add(Ui.Notice("正在恢复安全会话…"));
            else if (!store.Authenticated) content.Children.Add(LoginContent());
            else
            {
                content.Children.Add(BalanceCard()); content.Children.Add(Ui.Gap(13));
                content.Children.Add(Ui.Between(Ui.Text("快速接入", 12, "Muted", true), SectionLink("全部客户端  ↗", "widget-all-clients", "clients"))); content.Children.Add(Ui.Gap(7));
                var preferred = store.Preferences.RecentClients.Concat(new[] { "opencode", "codex", "claude-code", "pi" }).Distinct().Take(4).Select(id => store.Clients.Get(id));
                content.Children.Add(Ui.Columns(2, preferred.Select(d => (UIElement)QuickClient(d)).ToArray()));
                var section = Ui.Between(Ui.Text("常用模型", 12, "Muted", true), SectionLink("查看全部  ↗", "widget-models", "models")); content.Children.Add(section);
                foreach (var model in store.Models.Take(3))
                {
                    var b = Ui.Button("", "widget-model-" + model.Id, () => controller.CopyAccess(model.Id), "Quiet"); b.HorizontalContentAlignment = HorizontalAlignment.Stretch; b.Padding = new Thickness(0, 8, 0, 8);
                    b.Content = Ui.Between(Ui.Row(Ui.Badge(model.Name.Substring(0, 1), "Muted", "SurfaceAlt"), new Border { Width = 9 }, Ui.Text(model.Name, 12)), Ui.Glyph("\uE8C8", 13)); b.ToolTip = "复制此模型的接入信息"; content.Children.Add(b);
                }
                if (store.Models.Count == 0) content.Children.Add(Ui.Notice("暂未加载到当前 Key 的模型，点击刷新重试。"));
                var endpoints = new Expander { Header = Ui.Text("协议接入地址", 12, "Muted"), IsExpanded = endpointsExpanded, Margin = new Thickness(0, 10, 0, 6) };
                var rows = Ui.Stack(); foreach (var p in YakCoolApi.Protocols)
                {
                    var name = p; var b = Ui.Button(Ui.Protocol(p) + "  ⧉", "endpoint-" + p, () => controller.CopyEndpoint(name), "Quiet"); b.HorizontalContentAlignment = HorizontalAlignment.Left; rows.Children.Add(b);
                }
                endpoints.Content = rows; endpoints.Expanded += (s, e) => endpointsExpanded = true; endpoints.Collapsed += (s, e) => endpointsExpanded = false; content.Children.Add(endpoints);
            }
            if (Ui.HasFeedback(store)) { content.Children.Add(Ui.Gap(10)); content.Children.Add(Ui.Feedback(store)); }
            content.Children.Add(Ui.Gap(8));
            var line = new Border { Height = 1 }; line.SetResourceReference(BackgroundProperty, "Line"); content.Children.Add(line); content.Children.Add(Ui.Gap(12));
            var refresh = Ui.AsyncButton(store.Busy ? "正在更新…" : store.LastRefresh.HasValue ? store.LastRefresh.Value.ToString("HH:mm") + " 已同步" : "刷新连接", "widget-refresh", async () => await store.Run(store.Refresh), "Quiet"); refresh.FontSize = 11; refresh.Padding = new Thickness(0, 2, 0, 2); refresh.MinHeight = 26; refresh.IsEnabled = !store.Busy && store.Authenticated;
            refresh.HorizontalContentAlignment = HorizontalAlignment.Left;
            content.Children.Add(Ui.Between(refresh, Ui.Row(Ui.IconButton("\uE713", "偏好设置", "widget-settings", () => controller.ShowManager("settings")), Ui.IconButton("\uE8A7", "管理中心", "widget-manager", () => controller.ShowManager("overview")))));
            scroll.Content = content;
        }
        private Button SectionLink(string text, string id, string page) { var b = Ui.Button(text, id, () => controller.ShowManager(page), "Quiet"); b.FontSize = 10; b.Padding = new Thickness(0); b.MinHeight = 24; return b; }
        public FrameworkElement BalanceCard()
        {
            var store = controller.Store; var account = store.Mode == "account"; var quota = store.KeyInfo?["quota"];
            var title = account ? "账户可用余额" : quota.Flag("follows_account") ? "共享额度剩余" : "Key 独立额度";
            string value;
            if (account) value = store.Remaining?.ToString("F2") ?? "—";
            else if (quota.Flag("follows_account")) value = "约 " + quota.Number("remaining_percent_approx", 100 - quota.Number("used_percent_approx")).ToString("0") + "%";
            else value = quota.Text("remaining_rmb", "—");
            var label = Ui.Between(Ui.Text(title, 11, "Muted"), Ui.Badge("● 已连接"));
            var amount = Ui.Row(Ui.Text(account || !quota.Flag("follows_account") ? "¥ " : "", 23, "Ink", true), Ui.Text(value, 40, "Ink", true)); amount.Margin = new Thickness(0, 8, 0, 0);
            var accountRow = Ui.Between(Ui.Text(store.DisplayName, 11, "Muted"), Ui.Text(store.CurrentKey != null ? "•••• " + store.CurrentKey.Substring(Math.Max(0, store.CurrentKey.Length - 4)) : "未选择 Key", 11, "Muted"));
            var bar = new ProgressBar { Minimum = 0, Maximum = 100, Value = account ? Math.Max(0, Math.Min(100, (store.Remaining ?? 0) / Math.Max(1, store.Dashboard?["ai_service_credit"].Number("token_limit", 1) / 10000000 ?? 1) * 100)) : quota.Number("remaining_percent_approx", 80), Height = 4, Margin = new Thickness(0, 13, 0, 13), BorderThickness = new Thickness(0) }; bar.SetResourceReference(ForegroundProperty, "Accent"); bar.SetResourceReference(BackgroundProperty, "Line");
            var copy = Ui.Button("复制 Key", "widget-copy-key", controller.CopyKey); copy.FontSize = 11; copy.Padding = new Thickness(10, 6, 10, 6); copy.MinHeight = 30; copy.IsEnabled = store.CurrentKey != null;
            return Ui.Card(Ui.Stack(label, amount, bar, Ui.Between(accountRow, copy)), 17, "SurfaceAlt");
        }
        private Button QuickClient(ClientDescriptor d)
        {
            var store = controller.Store; var b = Ui.Button("", "widget-client-" + d.Id, () => { store.SelectClient(d.Id); controller.ShowManager("clients"); }); b.Padding = new Thickness(10, 10, 10, 10); b.HorizontalContentAlignment = HorizontalAlignment.Left;
            var installed = store.Clients.Installed(d.Id); b.Content = Ui.Row(Ui.AppMark(d, 27), new Border { Width = 8 }, Ui.Stack(Ui.Text(d.Name, 11, "Ink", true), Ui.Text(installed ? "配置与切换" : "添加接入", 9, "Muted"))); return b;
        }
        public FrameworkElement LoginContent()
        {
            var store = controller.Store;
            var account = Ui.Button("YakCool 账户", "login-tab-account", () => { KeyLoginMode = false; Render(); }, KeyLoginMode ? null : "Primary");
            var api = Ui.Button("API Key", "login-tab-key", () => { KeyLoginMode = true; Render(); }, KeyLoginMode ? "Primary" : null);
            var content = Ui.Stack(Ui.Columns(2, account, api), Ui.Gap(8), Ui.Text("连接，刚刚好。", 26, "Ink", true), Ui.Gap(9), Ui.Text(KeyLoginMode ? "使用业务 API Key 连接，查看额度与模型，一键配置你的编程工具。" : "连接 YakCool，让模型、额度和编程工具在一个地方井然有序。", 12, "Muted"), Ui.Gap(24));
            if (KeyLoginMode)
            {
                content.Children.Add(Ui.Text("业务 API Key", 11, "Muted", true)); content.Children.Add(Ui.Gap(8));
                var input = Ui.Id(new PasswordBox { MaxLength = 512 }, "login-key-input"); content.Children.Add(input); content.Children.Add(Ui.Gap(12));
                var connect = Ui.AsyncButton("验证并连接  →", "login-key-connect", async () => { var value = input.Password; input.Clear(); await store.Run(() => store.LoginKey(value)); }, "Primary"); connect.IsEnabled = !store.Busy; content.Children.Add(connect);
                input.KeyDown += async (s, e) => { if (e.Key == Key.Enter && !store.Busy) { var value = input.Password; input.Clear(); await store.Run(() => store.LoginKey(value)); e.Handled = true; } };
                content.Children.Add(Ui.Gap(12)); content.Children.Add(Ui.Text("仅访问当前 Key 的权限与额度。", 10, "Muted"));
            }
            else
            {
                var connect = Ui.AsyncButton("微信扫码登录  →", "login-account-connect", controller.LoginAccount, "Primary"); connect.IsEnabled = !store.Busy; content.Children.Add(connect); content.Children.Add(Ui.Gap(12));
                content.Children.Add(Ui.Text("在 YakCool 官方页面完成扫码，凭证由 Windows 加密保存。", 10, "Muted"));
            }
            if (store.CanRetrySession) { content.Children.Add(Ui.Gap(12)); content.Children.Add(Ui.AsyncButton("重试已保存的登录", "login-retry-session", async () => await store.Run(store.RestoreSession))); }
            return content;
        }
    }
}
