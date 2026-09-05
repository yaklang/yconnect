using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shell;
using Newtonsoft.Json.Linq;
using YConnect.Core;
using YConnect.Native;

namespace YConnect.Views
{
    public sealed class ManagerWindow : Window
    {
        private readonly AppController controller;
        private readonly Grid layout = new Grid();
        private readonly StackPanel navigation = Ui.Stack(), sidebarBrand = Ui.Stack(), sidebarFooter = Ui.Stack();
        private readonly Border rail = new Border();
        private readonly ScrollViewer body = new ScrollViewer();
        private readonly StackPanel top = Ui.Stack();
        private readonly StackPanel statusBar = Ui.Row();
        private readonly ConnectionPanel overviewConnection;
        private string section = "overview", search = "", protocolFilter = "all";
        private bool rendering;
        public string Section => section;
        public bool SidebarCollapsed => controller.Store.Preferences.SidebarCollapsed;
        public ManagerWindow(AppController controller)
        {
            this.controller = controller; controller.Store.Preferences.SidebarCollapsed = false;
            overviewConnection = new ConnectionPanel(controller, "overview", Render, true, CreateKeyFromOverview); Title = "YConnect · 管理中心"; Width = Math.Min(1080, SystemParameters.WorkArea.Width - 48); Height = Math.Min(760, SystemParameters.WorkArea.Height - 48); MinWidth = 850; MinHeight = 640;
            WindowStartupLocation = WindowStartupLocation.CenterScreen; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanResize;
            SetResourceReference(BackgroundProperty, "Page"); layout.SetResourceReference(Panel.BackgroundProperty, "Page");
            WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 0, ResizeBorderThickness = new Thickness(6), CornerRadius = new CornerRadius(12), GlassFrameThickness = new Thickness(0) });
            layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); layout.ColumnDefinitions.Add(new ColumnDefinition());
            var sidebar = new Grid(); sidebar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); sidebar.RowDefinitions.Add(new RowDefinition()); sidebar.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            sidebar.Children.Add(sidebarBrand); var navScroll = new ScrollViewer { Content = navigation }; Grid.SetRow(navScroll, 1); sidebar.Children.Add(navScroll); Grid.SetRow(sidebarFooter, 2); sidebar.Children.Add(sidebarFooter);
            rail.Child = sidebar; rail.Padding = new Thickness(14, 18, 14, 16); rail.BorderThickness = new Thickness(0, 0, 1, 0); rail.SetResourceReference(Border.BackgroundProperty, "Sidebar"); rail.SetResourceReference(Border.BorderBrushProperty, "WindowFrame"); layout.Children.Add(rail);
            var right = new DockPanel(); Grid.SetColumn(right, 1); layout.Children.Add(right); var frame = Ui.Id(new Border { Child = layout, BorderThickness = new Thickness(1) }, "manager-window-frame"); frame.SetResourceReference(Border.BorderBrushProperty, "WindowFrame"); Content = frame;
            var chrome = Ui.Between(statusBar, Ui.Row(Ui.IconButton("\uE921", "最小化", "window-minimize", () => WindowState = WindowState.Minimized), Ui.IconButton("\uE922", "最大化", "window-maximize", () => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized), Ui.IconButton("\uE8BB", "关闭管理中心", "window-close", Hide)));
            chrome.Height = 32; chrome.Margin = new Thickness(24, 8, 12, 0); DockPanel.SetDock(chrome, Dock.Top); right.Children.Add(chrome);
            top.Margin = new Thickness(24, 8, 24, 14); DockPanel.SetDock(top, Dock.Top); right.Children.Add(top);
            body.Margin = new Thickness(24, 0, 17, 20); body.Padding = new Thickness(0, 0, 7, 0); right.Children.Add(body);
            DragSurface.Attach(this, layout);
            Closing += (s, e) => { if (!controller.Quitting) { e.Cancel = true; Hide(); } };
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape) Hide(); }; Render();
        }
        public void Navigate(string value)
        {
            var changed = section != value; section = value; search = ""; Render(); body.ScrollToTop(); if (changed && body.Content is FrameworkElement page) Motion.Page(page);
        }
        private void ToggleSidebar()
        {
            var from = rail.ActualWidth; controller.Store.Preferences.SidebarCollapsed = !SidebarCollapsed;
            var width = SidebarCollapsed ? 76d : 208d; rail.Width = width; RenderSidebar();
            if (Motion.Allowed) rail.BeginAnimation(WidthProperty, new DoubleAnimation(from, width, TimeSpan.FromMilliseconds(190)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop });
            controller.Store.SavePreferences();
        }
        private void RenderSidebar()
        {
            var store = controller.Store; var collapsed = SidebarCollapsed;
            if (!rail.HasAnimatedProperties) rail.Width = collapsed ? 76 : 208;
            navigation.Children.Clear(); sidebarBrand.Children.Clear(); sidebarFooter.Children.Clear();
            var toggle = Ui.IconButton("\uE700", collapsed ? "展开侧栏" : "收起侧栏", "sidebar-toggle", ToggleSidebar); toggle.Width = 30; toggle.Height = 30;
            if (collapsed) { sidebarBrand.Children.Add(Ui.Logo(32)); sidebarBrand.Children.Add(Ui.Gap(10)); sidebarBrand.Children.Add(toggle); }
            else sidebarBrand.Children.Add(Ui.Between(Ui.IconLabel(Ui.Logo(30), Ui.Stack(Ui.Label("YConnect", 17, "Ink", true), Ui.Gap(3), Ui.Label("桌面连接", 10, "Muted")), 30, 9), toggle));
            sidebarBrand.Children.Add(Ui.Gap(collapsed ? 12 : 24));
            var navs = new[] { ("overview", "账户概览", "\uE80F"), ("keys", "API Keys", "\uE8D7"), ("clients", "客户端适配", "\uE8A5"), ("models", "模型目录", "\uE7F4"), ("checks", "连接测试", "\uE9D9"), ("settings", "设置", "\uE713") };
            foreach (var item in navs)
            {
                var destination = item.Item1; var selected = destination == section;
                var button = Ui.Button("", "nav-" + destination, () => Navigate(destination), "Quiet"); button.ToolTip = item.Item2; button.Padding = new Thickness(collapsed ? 11 : 12, 9, 11, 9); button.Margin = new Thickness(0, 0, 0, 3); button.HorizontalContentAlignment = HorizontalAlignment.Left;
                var glyph = Ui.Glyph(item.Item3, 16, selected ? "Accent" : "Muted");
                button.Height = 36; button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Content = collapsed ? (UIElement)glyph : Ui.IconLabel(glyph, Ui.Label(item.Item2, 12, selected ? "Ink" : "Muted", selected), 18, 10); button.Background = selected ? Ui.Brush("NavSelected") : Brushes.Transparent; navigation.Children.Add(button);
            }
            sidebarFooter.Children.Add(Ui.SmallButton(collapsed ? "↗" : "打开桌面连接  ↗", "manager-open-widget", controller.ShowWidget)); sidebarFooter.Children.Add(Ui.Divider());
            var account = Ui.Button("", "sidebar-account", () => { if (store.Authenticated) Navigate("keys"); else controller.ShowWidget(); }, "Quiet"); account.Padding = new Thickness(0, 5, 0, 5); account.HorizontalContentAlignment = HorizontalAlignment.Left;
            var name = store.Authenticated ? store.DisplayName : "登录 YakCool"; var title = Ui.Text(name, 12, "Ink", true); title.TextWrapping = TextWrapping.NoWrap; title.TextTrimming = TextTrimming.CharacterEllipsis; title.MaxWidth = 133;
            account.ToolTip = name; account.Content = collapsed ? (UIElement)Ui.Avatar(name, 34) : Ui.Row(Ui.Avatar(name, 34), new Border { Width = 10 }, Ui.Stack(title, Ui.Gap(4), Ui.Text(store.Authenticated ? (store.Mode == "account" ? "● 账户已连接" : "● API Key 已连接") : "连接你的模型与额度", 10, store.Authenticated ? "Green" : "Muted")));
            sidebarFooter.Children.Add(account); sidebarFooter.Children.Add(Ui.Gap(14));
            if (!collapsed) { sidebarFooter.Children.Add(Ui.Text("Y A K C O O L", 12, "Accent", true)); sidebarFooter.Children.Add(Ui.Gap(5)); sidebarFooter.Children.Add(Ui.Text("模型服务 · 随手连接", 9, "Muted")); }
            else sidebarFooter.Children.Add(Ui.Text("YAK", 10, "Accent", true));
        }
        public void Render()
        {
            rendering = true; var store = controller.Store; RenderSidebar(); top.Children.Clear();
            var names = new System.Collections.Generic.Dictionary<string, (string, string)> {
                ["overview"] = ("账户概览", "你的额度、使用情况与常用连接，一目了然。"), ["keys"] = ("API Keys", "为不同用途分配 Key，让每一次接入清晰可控。"),
                ["clients"] = ("客户端适配", "选择已安装的工具，预览后安全接入 YakCool。"), ["models"] = ("模型目录", "找到适合当前任务的模型，按真实协议能力选择。"),
                ["checks"] = ("连接测试", "从服务到模型，轻松找到连接中的问题。"), ["settings"] = ("设置", "按照你的习惯，调整桌面连接体验。") };
            var name = names.ContainsKey(section) ? names[section] : names["overview"];
            statusBar.Children.Clear(); if (store.Environment.Demo) statusBar.Children.Add(Ui.Badge("演示数据", "Accent", "AccentSoft"));
            var sync = Ui.Text(store.Busy ? "正在同步…" : store.LastRefresh.HasValue ? "● 已同步 " + store.LastRefresh.Value.ToString("HH:mm") : "等待连接", 10, store.Authenticated ? "Green" : "Muted"); sync.Margin = new Thickness(12, 0, 0, 0); sync.VerticalAlignment = VerticalAlignment.Center; statusBar.Children.Add(sync);
            top.Children.Add(Ui.Stack(Ui.Id(Ui.Text(name.Item1, 24, "Ink", true), "manager-page-title"), Ui.Gap(6), Ui.Text(name.Item2, 12, "Muted")));

            if (Ui.HasFeedback(store)) { top.Children.Add(Ui.Gap(12)); top.Children.Add(Ui.Feedback(store)); }
            FrameworkElement page = section == "keys" ? KeysPage() : section == "clients" ? ClientsPage() : section == "models" ? ModelsPage() : section == "checks" ? ChecksPage() : section == "settings" ? SettingsPage() : OverviewPage();
            body.Content = page; rendering = false;
        }
        private FrameworkElement OverviewPage()
        {
            var store = controller.Store;
            if (!store.Authenticated) return OverviewLogin();
            var balance = BalancePresentation.From(store); var summary = store.Dashboard?["account_summary"];
            var balanceActions = Ui.Row(Ui.Badge("● 已连接"));
            var hero = Ui.Card(Ui.Stack(Ui.Between(Ui.Label(balance.Label, 12, "Muted"), balanceActions), Ui.Gap(6), Ui.FitText(balance.Value, 32), Ui.Gap(10), Ui.QuotaBar(balance.Percent, 3)), 14, "AccentSoft");
            var metrics = Ui.Columns(3, hero, Metric("API Keys", store.Mode == "account" ? store.Keys.Count + " / " + store.Dashboard.Number("api_key_limit", 20) : "1", "当前可用凭证"), Metric("可用模型", store.Models.Count.ToString(), "按当前 Key 同步"));
            foreach (var item in metrics.Children.OfType<FrameworkElement>()) item.Margin = new Thickness(item.Margin.Left, 0, item.Margin.Right, 0);
            metrics.RowDefinitions[0].Height = new GridLength(1, GridUnitType.Star);
            var page = Ui.Stack(metrics, Ui.Gap(12));
            var workspace = new Grid(); workspace.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.18, GridUnitType.Star) }); workspace.ColumnDefinitions.Add(new ColumnDefinition());
            var connection = overviewConnection.Render(); connection.Margin = new Thickness(0, 0, 12, 0); connection.VerticalAlignment = VerticalAlignment.Top; workspace.Children.Add(connection);
            var installed = store.Clients.InstalledClients(store.Preferences.RecentClients);
            var clients = Ui.Stack(Ui.Between(Ui.Label("已安装客户端", 13, "Ink", true), Ui.SmallButton("全部管理 ↗", "overview-clients", () => Navigate("clients"))), Ui.Gap(8));
            if (installed.Length == 0) clients.Children.Add(Ui.Button("重新检测客户端", "overview-detect", Render));
            else clients.Children.Add(Ui.AdaptiveColumns(2, 150, installed.Select(d => (UIElement)ClientCard(d)).ToArray()));
            var refresh = Ui.AsyncButton("刷新连接", "overview-refresh", async () => await store.Run(store.Refresh)); refresh.IsEnabled = !store.Busy;
            var check = Ui.AsyncButton("检查连接", "overview-checks", async () => await store.Run(store.CheckConnection)); check.IsEnabled = !store.Busy;
            var pin = Ui.Button(store.Preferences.Pinned ? "取消固定面板" : "固定桌面面板", "overview-pin", () => { store.Preferences.Pinned = !store.Preferences.Pinned; store.SavePreferences(); });
            var settings = Ui.Button("偏好设置", "overview-settings", () => Navigate("settings"));
            var logout = Ui.AsyncButton("登出连接", "overview-signout", controller.SignOut, "Quiet"); logout.FontSize = 11;
            var keyManagement = Ui.Button("管理 API Keys", "overview-keys", () => Navigate("keys"));
            var redeem = store.Mode == "account" ? Ui.AsyncButton("兑换额度", "overview-redeem", RedeemFromOverview) : null;
            var tools = Ui.Stack(Ui.Label("快捷操作", 13, "Ink", true), Ui.Gap(10), Ui.Columns(2, new UIElement[] { refresh, check, pin, settings, keyManagement, redeem }.Where(x => x != null).ToArray()), logout);
            var aside = Ui.Stack(Ui.Card(clients, 14), Ui.Gap(12), Ui.Card(tools, 14)); Grid.SetColumn(aside, 1); workspace.Children.Add(aside); page.Children.Add(workspace);
            if (store.Mode == "account")
            {
                page.Children.Add(Ui.Gap(12));
                page.Children.Add(Ui.Card(Ui.Columns(3, Usage("累计调用", summary.Number("usage_count").ToString("N0")), Usage("调用成功率", summary.Number("success_rate").ToString("0.0") + "%"), Usage("活跃天数", summary.Number("active_days").ToString("0") + " 天")), 12));
            }
            return page;
        }
        private FrameworkElement OverviewLogin()
        {
            var store = controller.Store;
            var input = Ui.Id(new PasswordBox { MinHeight = 38, MaxLength = 512 }, "overview-login-input");
            var paste = Ui.SmallButton("粘贴", "overview-login-paste", () => { try { if (Clipboard.ContainsText()) input.Password = Clipboard.GetText(); input.Focus(); } catch { store.SetError("暂时无法读取剪贴板"); } }); paste.MinHeight = 38;
            var key = Ui.AsyncButton("验证并连接", "overview-login-key", async () => { var value = input.Password; input.Clear(); await store.Run(() => store.LoginKey(value)); }, "Primary"); key.IsEnabled = !store.Busy;
            var account = Ui.Card(Ui.Stack(Ui.Logo(38), Ui.Gap(16), Ui.Text("连接 YakCool 账户", 21, "Ink", true), Ui.Gap(10), Ui.Text("同步额度与模型，管理你的全部 API Key。", 12, "Muted"), Ui.Gap(18), Ui.AsyncButton("在 YConnect 内扫码", "overview-login-account", controller.LoginAccount, "Primary")), 24);
            var api = Ui.Card(Ui.Stack(Ui.Text("使用 API Key", 21, "Ink", true), Ui.Gap(10), Ui.Text("连接一把业务 Key，查看其额度与可用模型。", 12, "Muted"), Ui.Gap(18), Ui.Between(input, paste), Ui.Gap(12), key), 24);
            return Ui.Columns(2, account, api);
        }
        private async void CreateKeyFromOverview() { try { await CreateKey(); } catch (Exception e) { controller.Store.SetError(e.Message); } }
        private async Task RedeemFromOverview()
        {
            var input = Ui.Id(new TextBox { MaxLength = 80 }, "overview-redeem-code");
            var dialog = new DialogWindow(this, "兑换账户额度", Ui.Stack(Ui.Text("输入兑换码，额度将进入当前账户。", 12, "Muted"), Ui.Gap(12), input), "兑换额度");
            dialog.ContentRendered += (s, e) => input.Focus();
            if (controller.ShowDialog(dialog) == true) await controller.Store.Run(() => controller.Store.Redeem(input.Text));
        }
        private FrameworkElement Usage(string label, string value) => Ui.Stack(Ui.Text(label, 10, "Muted"), Ui.Gap(6), Ui.FitText(value, 22));
        private Border Metric(string label, string value, string note) => Ui.Card(Ui.Stack(Ui.Text(label, 11, "Muted"), Ui.Gap(8), Ui.FitText(value, 26), Ui.Gap(8), Ui.Text(note, 10, "Muted")), 14);
        private Button ClientCard(ClientDescriptor descriptor)
        {
            var button = Ui.Button("", "overview-client-" + descriptor.Id, () => { controller.Store.SelectClient(descriptor.Id); Navigate("clients"); }); button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Height = 46; button.Padding = new Thickness(8, 6, 8, 6); button.ToolTip = descriptor.Name;
            button.Content = Ui.IconLabel(Ui.AppMark(descriptor, 26), Ui.Stack(Ui.Label(descriptor.Name, 12, "Ink", true), Ui.Gap(3), Ui.Label(Ui.Status(controller.Store.Clients.Inspect(descriptor.Id)), 10, "Muted")), 26, 8); return button;
        }
        private FrameworkElement KeysPage()
        {
            var store = controller.Store;
            if (store.Mode != "account") return Ui.Card(Ui.Stack(Ui.Text("账户登录后管理 Key", 20, "Ink", true), Ui.Gap(10), Ui.Text("API Key 模式仅能查看当前 Key 的额度和模型。创建、删除和兑换需要账户权限。", 13, "Muted"), Ui.Gap(14), Ui.AsyncButton("登录 YakCool 账户", "keys-account-login", controller.LoginAccount, "Primary")), 28);
            var page = Ui.Stack(Ui.Between(Ui.Text(store.Keys.Count + " / " + store.Dashboard.Number("api_key_limit", 20) + " 个 API Key", 13, "Muted"), Ui.AsyncButton("＋ 创建 Key", "keys-create", CreateKey, "Primary")), Ui.Gap(12));
            foreach (var key in store.Keys)
            {
                var id = (long)key["id"]; var selected = store.Preferences.SelectedKey == id; var active = key.Flag("active");
                var use = Ui.AsyncButton(selected ? "✓ 当前使用" : "设为当前", "key-use-" + id, async () => await store.Run(() => store.SelectKey(id))); use.IsEnabled = active && !selected && !store.Busy;
                var copy = Ui.AsyncButton("复制", "key-copy-" + id, async () => { if (await store.Run(() => store.SelectKey(id))) controller.CopyKey(); }); copy.IsEnabled = active && !store.Busy; copy.Margin = new Thickness(8, 0, 0, 0);
                var remove = Ui.AsyncButton("删除", "key-delete-" + id, async () => { if (controller.Confirm("删除 API Key？", "删除“" + key.Text("label") + "”后，使用此 Key 的客户端将无法继续请求。", "删除 Key", true)) await store.Run(() => store.DeleteKey(id)); }); remove.Foreground = Ui.Brush("Danger"); remove.Margin = new Thickness(8, 0, 0, 0);
                var label = Ui.Text(key.Text("label"), 14, "Ink", true); label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis; label.MaxWidth = 180; label.ToolTip = key.Text("label");
                var details = Ui.Stack(Ui.Row(label, new Border { Width = 10 }, Ui.Badge(active ? "有效" : "已停用", active ? "Green" : "Muted", active ? "GreenSoft" : "SurfaceAlt")), Ui.Gap(6), Ui.Text("•••• " + key.Text("last4") + "   ·   " + (key.Flag("token_limit_enable") ? "独立额度" : "跟随主余额") + "   ·   " + key.Number("usage_count").ToString("0") + " 次调用", 11, "Muted"));
                foreach (var action in new[] { use, copy, remove }) { action.FontSize = 11; action.Padding = new Thickness(10, 7, 10, 7); }
                var card = Ui.Card(Ui.Between(details, Ui.Row(use, copy, remove)), 16, selected ? "AccentSoft" : "Surface"); card.Margin = new Thickness(0, 0, 0, 8); page.Children.Add(card);
            }
            var code = Ui.Id(new TextBox { MaxLength = 80 }, "redeem-code"); var redeem = Ui.AsyncButton("兑换额度", "redeem-submit", async () => { var value = code.Text; await store.Run(() => store.Redeem(value)); }, "Primary"); redeem.Margin = new Thickness(12, 0, 0, 0);
            page.Children.Add(Ui.Gap(8)); page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("兑换额度", 16, "Ink", true), Ui.Gap(9), Ui.Text("输入 YakCool 兑换码，额度将进入当前账户。", 11, "Muted"), Ui.Gap(14), Ui.Between(code, redeem)), 16)); return page;
        }
        public async Task CreateKey()
        {
            var input = Ui.Id(new TextBox { MaxLength = 40, Text = controller.Store.SuggestedKeyName() }, "new-key-label"); var dialog = new DialogWindow(this, "创建 API Key", Ui.Stack(Ui.Text("给 Key 起一个便于区分用途的名字。", 12, "Muted"), Ui.Gap(10), input), "创建 Key");
            dialog.ContentRendered += (s, e) => { input.Focus(); input.SelectAll(); };
            if (controller.ShowDialog(dialog) == true) { var label = input.Text; await controller.Store.Run(() => controller.Store.CreateKey(label)); }
        }
        private FrameworkElement ClientsPage()
        {
            var store = controller.Store; var installed = store.Clients.InstalledClients(store.Preferences.RecentClients);
            if (installed.Length == 0) return Ui.Card(Ui.Stack(Ui.Glyph("\uE8A5", 32, "Accent"), Ui.Gap(14), Ui.Text("先准备一个编程客户端", 16, "Ink", true), Ui.Gap(10), Ui.Text("暂未在这台电脑找到支持的客户端。安装后，回到这里重新检测。已有配置文件不会被当成安装成功。", 13, "Muted"), Ui.Gap(14), Ui.Button("重新检测", "clients-rescan", Render, "Primary")), 32);
            if (!installed.Any(c => c.Id == store.Preferences.SelectedClient)) store.SelectClient(installed[0].Id);
            var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(196) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
            var list = Ui.Stack(Ui.Between(Ui.Label("已安装 · " + installed.Length, 11, "Muted", true), Ui.IconButton("\uE72C", "重新检测客户端", "clients-rescan", Render)), Ui.Gap(6));
            foreach (var d in installed)
            {
                var id = d.Id; var b = Ui.Button("", "client-select-" + id, () => store.SelectClient(id), "ActionRow"); b.Height = 48; b.Padding = new Thickness(8, 6, 8, 6); b.Margin = new Thickness(0, 0, 0, 4); b.ToolTip = d.Name;
                b.Background = id == store.Preferences.SelectedClient ? Ui.Brush("AccentSoft") : Brushes.Transparent;
                b.Content = Ui.IconLabel(Ui.AppMark(d, 28), Ui.Stack(Ui.Label(d.Name, 12, "Ink", true), Ui.Gap(3), Ui.Label(Ui.Status(store.Clients.Inspect(id)), 10, "Muted")), 28, 10); list.Children.Add(b);
            }
            var listCard = Ui.Card(list, 8, "SurfaceAlt"); listCard.Margin = new Thickness(0, 0, 12, 0); listCard.VerticalAlignment = VerticalAlignment.Top; grid.Children.Add(listCard);
            var selected = store.Clients.Get(store.Preferences.SelectedClient); var status = store.Clients.Inspect(selected.Id); var compatible = selected.Compatible(store.Models).ToArray();
            var detail = Ui.Stack(Ui.Between(Ui.IconLabel(Ui.AppMark(selected, 40), Ui.Stack(Ui.Label(selected.Name, 21, "Ink", true), Ui.Gap(4), Ui.Label(selected.Description, 11, "Muted")), 40, 12), Ui.Badge(selected.Bridge ? "需协议桥" : Ui.Status(status), status.State == "configured" ? "Green" : "Muted", status.State == "configured" ? "GreenSoft" : "SurfaceAlt")), Ui.Gap(16));
            if (selected.Bridge) detail.Children.Add(Ui.Notice("Gemini CLI 使用原生 generateContent 协议。当前网关尚无该协议桥，因此这里不会生成不兼容的配置。"));
            else
            {
                detail.Children.Add(Ui.Text("原生协议", 11, "Muted", true)); detail.Children.Add(Ui.Gap(8)); detail.Children.Add(Ui.Text(string.Join("  /  ", selected.Protocols.Select(Ui.Protocol)), 12)); detail.Children.Add(Ui.Gap(14));
                detail.Children.Add(Ui.Text("配置位置", 11, "Muted", true)); detail.Children.Add(Ui.Gap(8)); foreach (var file in store.Clients.Paths(selected.Id)) { var text = Ui.Selectable(file, 11); detail.Children.Add(Ui.Card(Ui.Between(text, Ui.SmallButton(controller.CopyLabel("path:" + file, "复制"), "client-copy-path-" + Array.IndexOf(store.Clients.Paths(selected.Id), file), () => controller.CopyText(file, "path:" + file))), 10, "SurfaceAlt")); detail.Children.Add(Ui.Gap(7)); }
                detail.Children.Add(Ui.Gap(14));
                FrameworkElement keySelection;
                if (store.Mode == "account")
                {
                    var choices = store.Keys.Where(k => k.Flag("active")).Select(k => new KeyChoice { Id = (long)k["id"], Label = k.Text("label") + " · •••• " + k.Text("last4") }).ToArray();
                    var keys = Ui.Id(new ComboBox { ItemsSource = choices, SelectedItem = choices.FirstOrDefault(k => k.Id == store.Preferences.SelectedKey), IsEnabled = !store.Busy }, "client-key");
                    keys.SelectionChanged += async (s, e) => { if (!rendering && keys.SelectedItem is KeyChoice key) await store.Run(() => store.SelectKey(key.Id)); }; keySelection = keys;
                }
                else keySelection = Ui.Card(Ui.Text(store.CurrentKey == null ? "请先连接" : store.DisplayName + " · •••• " + store.CurrentKey.Substring(Math.Max(0, store.CurrentKey.Length - 4)), 11), 10, "SurfaceAlt");
                var combo = Ui.Id(new ComboBox { ItemsSource = compatible, SelectedItem = compatible.FirstOrDefault(m => m.Id == store.SelectedModel) }, "client-model"); combo.SelectionChanged += (s, e) => { if (!rendering && combo.SelectedItem is AvailableModel model) store.SelectModel(model.Id); };
                detail.Children.Add(Ui.Columns(2, Ui.Stack(Ui.Text("使用的 API Key", 11, "Muted", true), Ui.Gap(8), keySelection), Ui.Stack(Ui.Text("默认模型", 11, "Muted", true), Ui.Gap(8), combo)));
                detail.Children.Add(Ui.Text(compatible.Length > 0 ? compatible.Length + " 个模型支持此客户端所需的协议" : "当前没有兼容模型，请先连接有效 Key 并刷新。", 11, "Muted")); detail.Children.Add(Ui.Gap(14));
                var preview = Ui.AsyncButton("预览并应用配置  →", "client-preview", PreviewConfiguration, "Primary"); preview.IsEnabled = !store.Busy && compatible.Length > 0 && !string.IsNullOrEmpty(store.CurrentKey); detail.Children.Add(preview); detail.Children.Add(Ui.Gap(10));
                var restore = Ui.AsyncButton("恢复最近备份", "client-restore", async () => { if (controller.Confirm("恢复最近备份？", "将恢复“" + selected.Name + "”应用 YakCool 之前的配置。检测到外部修改时会停止恢复。", "恢复配置")) await store.Run(() => store.RestoreConfiguration(selected.Id)); }); restore.IsEnabled = status.HasBackup && !store.Busy; detail.Children.Add(restore);
                detail.Children.Add(Ui.Gap(14)); detail.Children.Add(Ui.Notice("写入前保存加密备份；凭证由专用文件和 Windows 权限保护。应用后请重启目标客户端。"));
                if (store.Environment.Development) { detail.Children.Add(Ui.Gap(8)); detail.Children.Add(Ui.Text("体验预览 · 仅写入隔离目录", 10, "Muted")); }
            }
            var box = Ui.Card(detail, 16); box.VerticalAlignment = VerticalAlignment.Top; Grid.SetColumn(box, 1); grid.Children.Add(box); return grid;
        }
        private async Task PreviewConfiguration()
        {
            var store = controller.Store; ConfigurationPlan plan = null;
            if (!await store.Run(async () => { plan = await store.PreviewConfiguration(); })) return;
            var content = Ui.Stack(Ui.Text("检查以下文件变更，确认后将自动备份并应用。", 12, "Muted"), Ui.Gap(10));
            foreach (var file in plan.Changes)
            {
                content.Children.Add(Ui.Text(file.Action + "  ·  " + file.Path, 11, "Muted", true)); content.Children.Add(Ui.Gap(7));
                if (file.Role == "configuration")
                {
                    var preview = Ui.Id(new TextBox { Text = ConfigurationEditors.RedactPreview(System.Text.Encoding.UTF8.GetString(file.After)), IsReadOnly = true, FontFamily = new FontFamily("Consolas"), FontSize = 11, TextWrapping = TextWrapping.NoWrap, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 210 }, "preview-configuration"); content.Children.Add(preview);
                }
                else content.Children.Add(Ui.Notice(file.Role == "credential" ? "专用密钥文件 · 仅当前 Windows 用户和 SYSTEM 可读" : "C# 原生凭证读取程序 · 无脚本或 shell"));
                content.Children.Add(Ui.Gap(14));
            }
            var dialog = new DialogWindow(this, "应用 " + store.Clients.Get(plan.Client).Name + " 配置", content, "备份并应用") { Width = 690 };
            if (controller.ShowDialog(dialog) == true) await store.Run(() => store.ApplyConfiguration(plan));
        }
        private FrameworkElement ModelsPage()
        {
            var store = controller.Store; var input = Ui.Id(new TextBox { Text = search }, "model-search"); input.ToolTip = "搜索模型名称或 ID"; var results = Ui.Stack();
            Action renderResults = () =>
            {
                results.Children.Clear(); var filtered = store.Models.Where(m => (m.Name + " " + m.Id).IndexOf(search, StringComparison.OrdinalIgnoreCase) >= 0 && (protocolFilter == "all" || m.Protocols.Contains(protocolFilter))).ToArray();
                results.Children.Add(Ui.Text(filtered.Length + " 个模型", 11, "Muted")); results.Children.Add(Ui.Gap(12));
                foreach (var model in filtered)
                {
                    var m = model; var copy = Ui.Button("复制接入信息", "model-copy-" + m.Id, () => controller.CopyAccess(m.Id)); copy.FontSize = 11; copy.IsEnabled = !string.IsNullOrEmpty(store.CurrentKey);
                    var entry = Ui.Stack(Ui.Between(Ui.Stack(Ui.Text(m.Name, 16, "Ink", true), Ui.Gap(5), Ui.Text(m.Id, 11, "Muted")), copy), Ui.Gap(14), Ui.Text(string.Join("   ·   ", m.Protocols.Select(Ui.Protocol)), 11, "Accent")); var card = Ui.Card(entry, 19); card.Margin = new Thickness(0, 0, 0, 12); results.Children.Add(card);
                }
                if (filtered.Length == 0) results.Children.Add(Ui.Notice(store.Authenticated ? "没有匹配的模型。尝试其他关键词、协议或刷新当前 Key。" : "连接账户或 API Key 后查看可用模型。"));
            };
            input.TextChanged += (s, e) => { search = input.Text; renderResults(); };
            var filters = new WrapPanel(); foreach (var p in new[] { "all" }.Concat(YakCoolApi.Protocols))
            {
                var selected = p; var b = Ui.Button(p == "all" ? "全部协议" : Ui.Protocol(p), "model-filter-" + p, () => { protocolFilter = selected; Render(); }, protocolFilter == p ? "Primary" : null); b.Margin = new Thickness(0, 0, 8, 8); b.FontSize = 11; filters.Children.Add(b);
            }
            renderResults(); return Ui.Stack(Ui.Text("搜索名称或模型 ID", 11, "Muted"), Ui.Gap(8), input, Ui.Gap(10), filters, Ui.Gap(12), results);
        }
        private FrameworkElement ChecksPage()
        {
            var store = controller.Store; var start = Ui.AsyncButton("开始基础检查", "checks-start", async () => await store.Run(store.CheckConnection), "Primary"); start.IsEnabled = !store.Busy;
            var page = Ui.Stack(Ui.Card(Ui.Between(Ui.Stack(Ui.Text("基础连接检查", 18, "Ink", true), Ui.Gap(7), Ui.Text("健康状态 → Key 权限 → 模型协议，不产生模型调用费用。", 12, "Muted")), start), 16), Ui.Gap(12));
            var checks = store.Checks.Count > 0 ? store.Checks : new System.Collections.Generic.List<ServiceCheck> { new ServiceCheck { Title = "YakCool 服务" }, new ServiceCheck { Title = "Key 权限" }, new ServiceCheck { Title = "模型与协议" } };
            foreach (var check in checks)
            {
                var mark = check.State == "passed" ? "✓" : check.State == "failed" ? "!" : check.State == "running" ? "…" : "○"; var color = check.State == "passed" ? "Green" : check.State == "failed" ? "Danger" : "Muted";
                var item = Ui.Card(Ui.Between(Ui.Row(Ui.Text(mark, 24, color, true), new Border { Width = 16 }, Ui.Stack(Ui.Text(check.Title, 14, "Ink", true), Ui.Gap(6), Ui.Text(check.Detail ?? (check.State == "running" ? "检查中…" : "等待检查"), 11, "Muted"))), Ui.Text(check.State == "passed" ? check.Milliseconds + " ms" : "", 11, "Muted")), 20); item.Margin = new Thickness(0, 0, 0, 10); page.Children.Add(item);
            }
            page.Children.Add(Ui.Gap(12)); var model = Ui.Id(new ComboBox { ItemsSource = store.Models, SelectedIndex = store.Models.Count > 0 ? 0 : -1 }, "probe-model");
            var protocol = Ui.Id(new ComboBox(), "probe-protocol"); Action update = () => { var m = model.SelectedItem as AvailableModel; protocol.ItemsSource = m?.Protocols.Where(YakCoolApi.Protocols.Contains).ToArray(); protocol.SelectedIndex = 0; }; model.SelectionChanged += (s, e) => update(); update();
            var probe = Ui.AsyncButton("发送最小测试", "probe-submit", async () => { var m = model.SelectedItem as AvailableModel; var p = protocol.SelectedItem as string; if (m != null && p != null && controller.Confirm("发送真实模型请求？", "将使用当前 Key 调用“" + m.Name + "”，可能消耗额度。只发送固定文本：Reply exactly with OK.，输出上限为 8 tokens。", "发送测试")) await store.Run(() => store.Probe(m.Id, p, true)); }); probe.IsEnabled = store.Models.Count > 0 && !store.Busy;
            page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("真实模型调用", 17, "Ink", true), Ui.Gap(8), Ui.Text("可选 · 发送前会再次确认，可能消耗少量额度。", 11, "Muted"), Ui.Gap(12), model, Ui.Gap(10), protocol, Ui.Gap(14), probe), 16)); return page;
        }
        private FrameworkElement SettingsPage()
        {
            var store = controller.Store;
            var edge = SettingCheck("显示屏幕边缘入口", "setting-edge", store.Preferences.EdgeEnabled, value => { store.Preferences.EdgeEnabled = value; controller.PositionAll(); });
            var pin = SettingCheck("固定面板，切换应用时保持显示", "setting-pin", store.Preferences.Pinned, value => store.Preferences.Pinned = value);
            var peek = SettingCheck("靠近边缘时，轻盈显示余额", "setting-peek", store.Preferences.BalancePeekEnabled, value => { store.Preferences.BalancePeekEnabled = value; controller.Edge.CloseQuick(); });
            var privacy = SettingCheck("速览只显示剩余百分比", "setting-peek-privacy", store.Preferences.PeekPercentageOnly, value => store.Preferences.PeekPercentageOnly = value);
            var left = Ui.Button("左侧", "setting-side-left", () => { store.Preferences.OnLeft = true; store.SavePreferences(); controller.PositionAll(); }, store.Preferences.OnLeft ? "Primary" : null);
            var right = Ui.Button("右侧", "setting-side-right", () => { store.Preferences.OnLeft = false; store.SavePreferences(); controller.PositionAll(); }, store.Preferences.OnLeft ? null : "Primary"); right.Margin = new Thickness(8, 0, 0, 0);
            var reset = Ui.SmallButton("重置位置", "setting-reset-position", () => { store.Preferences.OnLeft = false; store.Preferences.YPercent = 58; store.SavePreferences(); controller.PositionAll(); }); reset.Margin = new Thickness(10, 0, 0, 0);
            var desktop = Ui.Card(Ui.Stack(Ui.Text("始终在你手边", 17, "Ink", true), Ui.Gap(14), edge, peek, privacy, pin, Ui.Gap(12), Ui.Row(left, right, reset), Ui.Gap(12), Ui.Text("拖动边缘把手可调整高度。面板的空白区域也能拖动，松手后柔和贴边。", 11, "Muted")), 16);
            var light = Ui.Button("浅色", "setting-theme-light", () => { store.Preferences.Theme = "light"; Ui.SetTheme("light"); store.SavePreferences(); }, store.Preferences.Theme == "light" ? "Primary" : null);
            var dark = Ui.Button("深色", "setting-theme-dark", () => { store.Preferences.Theme = "dark"; Ui.SetTheme("dark"); store.SavePreferences(); }, store.Preferences.Theme == "dark" ? "Primary" : null); dark.Margin = new Thickness(8, 0, 0, 0);
            var animation = SettingCheck("轻量动效与微光反馈", "setting-motion", store.Preferences.AnimationsEnabled, value => store.Preferences.AnimationsEnabled = value);
            var startup = Ui.Id(new CheckBox { Content = "登录 Windows 后自动准备好连接", IsChecked = controller.StartupEnabled, IsEnabled = !store.Environment.Development }, "setting-startup");
            startup.Click += (s, e) => { try { controller.SetStartup(startup.IsChecked == true); } catch (Exception error) { store.SetError(error.Message); } };
            var appearance = Ui.Card(Ui.Stack(Ui.Text("外观与启动", 17, "Ink", true), Ui.Gap(12), Ui.Row(light, dark), Ui.Gap(12), animation, Ui.Gap(5), Ui.Text("动效只在交互时出现，也会尊重 Windows 的减少动画设置。", 11, "Muted"), Ui.Divider(), startup, Ui.Gap(8), Ui.Text(store.Environment.Development ? "预览环境不会修改系统启动项。" : "首次使用默认开启，你随时可以关闭。", 11, "Muted")), 16);
            var page = Ui.Stack(Ui.Columns(2, desktop, appearance));
            var direct = SettingCheck("直连网络，不使用代理", "setting-direct-network", store.Preferences.BypassProxy, value => { store.Preferences.BypassProxy = value; store.SetMessage("网络偏好已保存，重启 YConnect 后生效。系统代理未修改。"); });
            page.Children.Add(Ui.Card(Ui.Between(Ui.Stack(Ui.Text("网络连接", 16, "Ink", true), Ui.Gap(9), Ui.Text("扫码或同步遇到问题时，可以尝试应用直连。", 11, "Muted")), direct), 16)); page.Children.Add(Ui.Gap(14));
            var logout = Ui.AsyncButton("登出当前连接", "setting-signout", controller.SignOut); logout.IsEnabled = store.Authenticated;
            page.Children.Add(Ui.Card(Ui.Between(Ui.Stack(Ui.Text("账户与隐私", 16, "Ink", true), Ui.Gap(9), Ui.Text("凭证加密保存在本机，配置前自动备份。登出不会删除下游客户端配置。", 11, "Muted")), logout), 16)); page.Children.Add(Ui.Gap(12));
            var detail = Ui.Stack(Ui.Text("YConnect 0.2.0 · Windows", 11, "Muted"), Ui.Gap(10), Ui.Text("本地数据", 11, "Muted", true), Ui.Gap(6), Ui.Selectable(store.Environment.DataRoot), Ui.Gap(12), Ui.Button("打开数据目录", "setting-open-data", controller.OpenData), Ui.Gap(12), Ui.Text(store.Environment.Development ? "当前为隔离预览，所有测试配置都写入专用目录，不接触真实客户端。会话使用 DPAPI，备份保留最近 20 份。" : "会话与备份使用 Windows DPAPI。下游凭证文件使用仅当前用户与 SYSTEM 可读的私有权限。最近 20 份备份可恢复。", 11, "Muted"));
            page.Children.Add(new Expander { Header = Ui.Text("版本、存储与安全详情", 11, "Muted"), Content = new Border { Child = detail, Padding = new Thickness(0, 16, 0, 0) } }); return page;
        }
        private CheckBox SettingCheck(string label, string id, bool value, Action<bool> changed)
        {
            var check = Ui.Id(new CheckBox { Content = label, IsChecked = value, FontSize = 12, Margin = new Thickness(0, 4, 0, 4) }, id);
            check.Click += (s, e) => { changed(check.IsChecked == true); controller.Store.SavePreferences(); }; return check;
        }
        private sealed class KeyChoice { public long Id; public string Label; public override string ToString() => Label; }
    }
}
