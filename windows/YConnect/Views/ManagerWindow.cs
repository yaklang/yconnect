using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;
using Newtonsoft.Json.Linq;
using YConnect.Core;

namespace YConnect.Views
{
    public sealed class ManagerWindow : Window
    {
        private readonly AppController controller;
        private readonly Grid layout = new Grid();
        private readonly StackPanel navigation = Ui.Stack();
        private readonly ScrollViewer body = new ScrollViewer();
        private readonly StackPanel top = Ui.Stack();
        private string section = "overview";
        private string search = "", protocolFilter = "all";
        private bool rendering;
        public string Section => section;
        public ManagerWindow(AppController controller)
        {
            this.controller = controller; Title = "YConnect · 连接管理中心"; Width = Math.Min(1150, SystemParameters.WorkArea.Width - 50); Height = Math.Min(800, SystemParameters.WorkArea.Height - 50); MinWidth = 820; MinHeight = 610; WindowStartupLocation = WindowStartupLocation.CenterScreen; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanResize;
            SetResourceReference(BackgroundProperty, "Page");
            layout.SetResourceReference(Panel.BackgroundProperty, "Page");
            WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 0, ResizeBorderThickness = new Thickness(6), CornerRadius = new CornerRadius(12), GlassFrameThickness = new Thickness(0) });
            layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(205) }); layout.ColumnDefinitions.Add(new ColumnDefinition());
            var rail = new Border { Background = new SolidColorBrush(Color.FromRgb(36, 47, 41)), Child = navigation, Padding = new Thickness(18, 25, 16, 22) }; layout.Children.Add(rail);
            var right = new DockPanel(); Grid.SetColumn(right, 1); layout.Children.Add(right); Content = layout;
            var chrome = Ui.Between(Ui.Text("YConnect  /  Windows 原生版", 10, "Muted"), Ui.Row(Ui.IconButton("\uE921", "最小化", "window-minimize", () => WindowState = WindowState.Minimized), Ui.IconButton("\uE922", "最大化", "window-maximize", () => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized), Ui.IconButton("\uE8BB", "关闭管理中心", "window-close", Hide)));
            chrome.Margin = new Thickness(30, 10, 12, 0); chrome.MouseLeftButtonDown += (s, e) => { if (e.ClickCount == 2) WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; else if (e.OriginalSource is TextBlock) DragMove(); }; DockPanel.SetDock(chrome, Dock.Top); right.Children.Add(chrome);
            top.Margin = new Thickness(32, 20, 32, 16); DockPanel.SetDock(top, Dock.Top); right.Children.Add(top); body.Margin = new Thickness(32, 0, 25, 25); body.Padding = new Thickness(0, 0, 7, 0); right.Children.Add(body);
            Closing += (s, e) => { if (!controller.Quitting) { e.Cancel = true; Hide(); } };
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape) Hide(); }; Render();
        }
        public void Navigate(string value) { section = value; search = ""; Render(); body.ScrollToTop(); }
        public void Render()
        {
            rendering = true; var store = controller.Store; navigation.Children.Clear(); top.Children.Clear();
            var title = Ui.Text("YConnect", 19, "Ink", true); title.Foreground = Brushes.White; var caption = Ui.Text("CONNECT YOUR FLOW", 9, "Muted"); caption.Foreground = new SolidColorBrush(Color.FromRgb(155, 172, 160));
            navigation.Children.Add(Ui.Row(Ui.Logo(38), new Border { Width = 10 }, Ui.Stack(title, caption))); navigation.Children.Add(Ui.Gap(43));
            var navs = new[] { ("overview", "概览", "\uE80F"), ("keys", "API Key", "\uE8D7"), ("clients", "客户端接入", "\uE8A5"), ("models", "模型目录", "\uE7F4"), ("checks", "连接测试", "\uE9D9"), ("settings", "偏好设置", "\uE713") };
            foreach (var item in navs)
            {
                var destination = item.Item1; var b = Ui.Button("", "nav-" + destination, () => Navigate(destination), "Quiet"); b.HorizontalContentAlignment = HorizontalAlignment.Left; b.Padding = new Thickness(13, 12, 13, 12); b.Margin = new Thickness(0, 0, 0, 5);
                var glyph = Ui.Glyph(item.Item3, 16); glyph.Foreground = destination == section ? Brushes.White : new SolidColorBrush(Color.FromRgb(158, 175, 162));
                var text = Ui.Text(item.Item2, 12); text.Foreground = glyph.Foreground;
                b.Content = Ui.Row(glyph, new Border { Width = 12 }, text); b.Background = destination == section ? new SolidColorBrush(Color.FromRgb(59, 75, 63)) : Brushes.Transparent; navigation.Children.Add(b);
            }
            navigation.Children.Add(Ui.Gap(35));
            var note = Ui.Text("始终在你手边", 12, "Muted", true); note.Foreground = new SolidColorBrush(Color.FromRgb(207, 217, 207)); navigation.Children.Add(note); navigation.Children.Add(Ui.Gap(9));
            var detail = Ui.Text("从屏幕边缘，\n开始下一次连接。", 11, "Muted"); detail.Foreground = new SolidColorBrush(Color.FromRgb(146, 164, 151)); navigation.Children.Add(detail); navigation.Children.Add(Ui.Gap(18));
            var show = Ui.Button("打开桌面小组件  ↗", "manager-open-widget", controller.ShowWidget); show.Background = new SolidColorBrush(Color.FromRgb(55, 69, 59)); show.Foreground = Brushes.White; show.BorderThickness = new Thickness(0); show.FontSize = 11; navigation.Children.Add(show);
            navigation.Children.Add(Ui.Gap(45)); var version = Ui.Text("v0.2.0  ·  WPF / C#", 10, "Muted"); version.Foreground = new SolidColorBrush(Color.FromRgb(126, 148, 132)); navigation.Children.Add(version);
            var names = new System.Collections.Generic.Dictionary<string, (string, string)> { ["overview"] = ("一切连接，井然有序。", "账户、模型与编程工具，在这里轻松衔接。"), ["keys"] = ("管理你的 API Key", "为不同用途分配独立密钥，清晰掌握每一次接入。"), ["clients"] = ("让工具，即刻就绪。", "选择客户端和兼容模型，预览后安全应用配置。"), ["models"] = ("找到合适的模型", "按当前 Key 的真实权限和协议选择模型。"), ["checks"] = ("每一步连接，都有答案。", "分层检查服务、凭证和模型，让问题更容易定位。"), ["settings"] = ("按你的方式，保持连接。", "调整小组件的位置、外观和 Windows 启动行为。") };
            var name = names.ContainsKey(section) ? names[section] : names["overview"];
            top.Children.Add(Ui.Between(Ui.Stack(Ui.Text(name.Item1, 25, "Ink", true), Ui.Gap(8), Ui.Text(name.Item2, 12, "Muted")), Ui.Badge(store.Authenticated ? "● " + store.DisplayName : "○ 尚未连接", store.Authenticated ? "Green" : "Muted", store.Authenticated ? "GreenSoft" : "SurfaceAlt")));
            if (store.Environment.Demo) { top.Children.Add(Ui.Gap(12)); top.Children.Add(Ui.Notice("演示模式 · 以下为示例数据，配置操作仅写入隔离目录。")); }
            if (store.Busy) { top.Children.Add(Ui.Gap(10)); top.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 }); }
            if (Ui.HasFeedback(store)) { top.Children.Add(Ui.Gap(10)); top.Children.Add(Ui.Feedback(store)); }
            FrameworkElement page = section == "keys" ? KeysPage() : section == "clients" ? ClientsPage() : section == "models" ? ModelsPage() : section == "checks" ? ChecksPage() : section == "settings" ? SettingsPage() : OverviewPage();
            body.Content = page; rendering = false;
        }
        private FrameworkElement OverviewPage()
        {
            var store = controller.Store;
            if (!store.Authenticated)
            {
                var content = Ui.Stack(Ui.Text("把 YakCool 带到你的桌面", 22, "Ink", true), Ui.Gap(10), Ui.Text("登录后即可查看余额、管理 Key，连接你的 AI 编程客户端。", 13, "Muted"), Ui.Gap(25), Ui.AsyncButton("微信扫码登录  →", "overview-login-account", controller.LoginAccount, "Primary"), Ui.Gap(12), Ui.Button("使用 API Key 连接", "overview-login-key", () => { controller.Widget.KeyLoginMode = true; controller.Widget.Render(); controller.ShowWidget(); }));
                return Ui.Card(content, 32);
            }
            var balance = Ui.Stack(Ui.Text("账户可用余额", 12, "Muted"), Ui.Gap(15), Ui.Text(store.Remaining.HasValue ? "¥ " + store.Remaining.Value.ToString("F2") : store.KeyInfo?["quota"].Text("display", "—"), 37, "Ink", true), Ui.Gap(12), Ui.Text(store.Mode == "account" ? "余额由 YakCool 实时同步" : "当前 Key 的独立或共享额度", 11, "Muted"));
            var totals = Ui.Columns(2, Metric("API KEY", store.Mode == "account" ? store.Keys.Count.ToString() : "1", "当前可用凭证"), Metric("可用模型", store.Models.Count.ToString(), "按 Key 权限同步"));
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition()); var hero = Ui.Card(balance, 23, "AccentSoft"); hero.Margin = new Thickness(0, 0, 14, 0); row.Children.Add(hero); Grid.SetColumn(totals, 1); row.Children.Add(totals);
            var refresh = Ui.AsyncButton("刷新账户", "overview-refresh", async () => await store.Run(store.Refresh)); refresh.IsEnabled = !store.Busy;
            var page = Ui.Stack(row, Ui.Gap(27), Ui.Between(Ui.Stack(Ui.Text("你的编程工具", 17, "Ink", true), Ui.Gap(5), Ui.Text("一个 Key，连接你的整个工作流。", 11, "Muted")), refresh), Ui.Gap(18));
            page.Children.Add(Ui.Columns(2, ClientRegistry.All.Where(c => !c.Bridge).Select(c => (UIElement)ClientCard(c)).ToArray()));
            page.Children.Add(Ui.Card(Ui.Between(Ui.Stack(Ui.Text("连接状态，一眼可见", 14, "Ink", true), Ui.Gap(6), Ui.Text("基础测试不调用付费模型。", 11, "Muted")), Ui.Button("检查连接  →", "overview-checks", () => Navigate("checks"))), 19)); return page;
        }
        private Border Metric(string label, string value, string note) => Ui.Card(Ui.Stack(Ui.Text(label, 10, "Muted", true), Ui.Gap(18), Ui.Text(value, 34, "Ink", true), Ui.Gap(12), Ui.Text(note, 10, "Muted")), 20);
        private Button ClientCard(ClientDescriptor descriptor)
        {
            var store = controller.Store; var status = store.Clients.Inspect(descriptor.Id);
            var b = Ui.Button("", "overview-client-" + descriptor.Id, () => { store.SelectClient(descriptor.Id); Navigate("clients"); }); b.HorizontalContentAlignment = HorizontalAlignment.Stretch; b.Padding = new Thickness(17, 15, 17, 15);
            b.Content = Ui.Between(Ui.Row(Ui.AppMark(descriptor), new Border { Width = 12 }, Ui.Stack(Ui.Text(descriptor.Name, 13, "Ink", true), Ui.Gap(4), Ui.Text(descriptor.Description, 10, "Muted"))), Ui.Text(Ui.Status(status) + "  ↗", 10, status.State == "configured" ? "Green" : "Muted")); return b;
        }
        private FrameworkElement KeysPage()
        {
            var store = controller.Store;
            if (store.Mode != "account") return Ui.Card(Ui.Stack(Ui.Text("账户登录后管理 Key", 20, "Ink", true), Ui.Gap(10), Ui.Text("API Key 模式仅能查看当前 Key 的额度和模型。创建、删除和兑换需要账户权限。", 13, "Muted"), Ui.Gap(22), Ui.AsyncButton("登录 YakCool 账户", "keys-account-login", controller.LoginAccount, "Primary")), 28);
            var page = Ui.Stack(Ui.Between(Ui.Text(store.Keys.Count + " / " + store.Dashboard.Number("api_key_limit", 20) + " 个 API Key", 13, "Muted"), Ui.AsyncButton("＋ 创建 Key", "keys-create", CreateKey, "Primary")), Ui.Gap(17));
            foreach (var key in store.Keys)
            {
                var id = (long)key["id"]; var selected = store.Preferences.SelectedKey == id; var active = key.Flag("active");
                var use = Ui.AsyncButton(selected ? "✓ 当前使用" : "设为当前", "key-use-" + id, async () => await store.Run(() => store.SelectKey(id))); use.IsEnabled = active && !selected && !store.Busy;
                var copy = Ui.AsyncButton("复制", "key-copy-" + id, async () => { if (await store.Run(() => store.SelectKey(id))) controller.CopyKey(); }); copy.IsEnabled = active && !store.Busy; copy.Margin = new Thickness(8, 0, 0, 0);
                var remove = Ui.AsyncButton("删除", "key-delete-" + id, async () => { if (controller.Confirm("删除 API Key？", "删除“" + key.Text("label") + "”后，使用此 Key 的客户端将无法继续请求。", "删除 Key", true)) await store.Run(() => store.DeleteKey(id)); }); remove.Foreground = Ui.Brush("Danger"); remove.Margin = new Thickness(8, 0, 0, 0);
                var details = Ui.Stack(Ui.Row(Ui.Text(key.Text("label"), 16, "Ink", true), new Border { Width = 12 }, Ui.Badge(active ? "有效" : "已停用", active ? "Green" : "Muted", active ? "GreenSoft" : "SurfaceAlt")), Ui.Gap(12), Ui.Text("••••  ••••  ••••  " + key.Text("last4"), 15, "Muted"), Ui.Gap(9), Ui.Text((key.Flag("token_limit_enable") ? "独立额度" : "跟随主余额") + "   ·   " + key.Number("usage_count").ToString("0") + " 次调用", 11, "Muted"));
                var card = Ui.Card(Ui.Stack(details, Ui.Gap(17), Ui.Row(use, copy, remove)), 22, selected ? "AccentSoft" : "Surface"); card.Margin = new Thickness(0, 0, 0, 14); page.Children.Add(card);
            }
            var code = Ui.Id(new TextBox { MaxLength = 80 }, "redeem-code"); var redeem = Ui.AsyncButton("兑换额度", "redeem-submit", async () => { var value = code.Text; await store.Run(() => store.Redeem(value)); }, "Primary"); redeem.Margin = new Thickness(12, 0, 0, 0);
            page.Children.Add(Ui.Gap(8)); page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("兑换额度", 16, "Ink", true), Ui.Gap(9), Ui.Text("输入 YakCool 兑换码，额度将进入当前账户。", 11, "Muted"), Ui.Gap(14), Ui.Between(code, redeem)), 22)); return page;
        }
        private async Task CreateKey()
        {
            var input = Ui.Id(new TextBox { MaxLength = 40 }, "new-key-label"); var dialog = new DialogWindow(this, "创建 API Key", Ui.Stack(Ui.Text("给 Key 起一个便于区分用途的名字。", 12, "Muted"), Ui.Gap(13), input), "创建 Key");
            if (controller.ShowDialog(dialog) == true) { var label = input.Text; await controller.Store.Run(() => controller.Store.CreateKey(label)); }
        }
        private FrameworkElement ClientsPage()
        {
            var store = controller.Store; var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(185) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
            var list = Ui.Stack();
            foreach (var d in ClientRegistry.All)
            {
                var id = d.Id; var b = Ui.Button("", "client-select-" + id, () => store.SelectClient(id), "Quiet"); b.HorizontalContentAlignment = HorizontalAlignment.Left; b.Padding = new Thickness(11, 10, 11, 10); b.Margin = new Thickness(0, 0, 12, 4); b.Background = id == store.Preferences.SelectedClient ? Ui.Brush("AccentSoft") : Brushes.Transparent; b.Content = Ui.Row(Ui.AppMark(d, 27), new Border { Width = 10 }, Ui.Stack(Ui.Text(d.Name, 11, "Ink", true), Ui.Text(d.Bridge ? "需协议桥" : Ui.Status(store.Clients.Inspect(id)), 9, "Muted"))); list.Children.Add(b);
            }
            grid.Children.Add(list); var selected = store.Clients.Get(store.Preferences.SelectedClient); var status = store.Clients.Inspect(selected.Id); var compatible = selected.Compatible(store.Models).ToArray();
            var detail = Ui.Stack(Ui.Between(Ui.Row(Ui.AppMark(selected, 43), new Border { Width = 13 }, Ui.Stack(Ui.Text(selected.Name, 21, "Ink", true), Ui.Text(selected.Description, 11, "Muted"))), Ui.Badge(selected.Bridge ? "需协议桥" : Ui.Status(status), status.State == "configured" ? "Green" : "Muted", status.State == "configured" ? "GreenSoft" : "SurfaceAlt")), Ui.Gap(24));
            if (selected.Bridge) detail.Children.Add(Ui.Notice("Gemini CLI 使用原生 generateContent 协议。当前网关尚无该协议桥，因此这里不会生成不兼容的配置。"));
            else
            {
                detail.Children.Add(Ui.Text("原生协议", 11, "Muted", true)); detail.Children.Add(Ui.Gap(8)); detail.Children.Add(Ui.Text(string.Join("  /  ", selected.Protocols.Select(Ui.Protocol)), 12)); detail.Children.Add(Ui.Gap(22));
                detail.Children.Add(Ui.Text("配置位置", 11, "Muted", true)); detail.Children.Add(Ui.Gap(8)); foreach (var file in store.Clients.Paths(selected.Id)) { var text = Ui.Text(file, 11, "Muted"); text.FontFamily = new FontFamily("Cascadia Mono, Consolas"); detail.Children.Add(Ui.Card(text, 11, "SurfaceAlt")); detail.Children.Add(Ui.Gap(7)); }
                detail.Children.Add(Ui.Gap(14)); detail.Children.Add(Ui.Text("选择模型", 11, "Muted", true)); detail.Children.Add(Ui.Gap(8));
                var combo = Ui.Id(new ComboBox { ItemsSource = compatible, SelectedItem = compatible.FirstOrDefault(m => m.Id == store.SelectedModel) }, "client-model"); combo.SelectionChanged += (s, e) => { if (!rendering && combo.SelectedItem is AvailableModel model) store.SelectModel(model.Id); }; detail.Children.Add(combo); detail.Children.Add(Ui.Gap(10));
                detail.Children.Add(Ui.Text(compatible.Length > 0 ? compatible.Length + " 个模型支持此客户端所需的协议" : "当前没有兼容模型，请先连接有效 Key 并刷新。", 11, "Muted")); detail.Children.Add(Ui.Gap(21));
                var preview = Ui.AsyncButton("预览并应用配置  →", "client-preview", PreviewConfiguration, "Primary"); preview.IsEnabled = !store.Busy && compatible.Length > 0 && !string.IsNullOrEmpty(store.CurrentKey); detail.Children.Add(preview); detail.Children.Add(Ui.Gap(10));
                var restore = Ui.AsyncButton("恢复最近备份", "client-restore", async () => { if (controller.Confirm("恢复最近备份？", "将恢复“" + selected.Name + "”应用 YakCool 之前的配置。检测到外部修改时会停止恢复。", "恢复配置")) await store.Run(() => store.RestoreConfiguration(selected.Id)); }); restore.IsEnabled = status.HasBackup && !store.Busy; detail.Children.Add(restore);
                detail.Children.Add(Ui.Gap(21)); detail.Children.Add(Ui.Notice("写入前保存加密备份；凭证由专用文件和 Windows 权限保护。应用后请重启目标客户端。"));
                if (store.Environment.Development) { detail.Children.Add(Ui.Gap(10)); detail.Children.Add(Ui.Notice("当前为开发隔离目录，操作不会写入正式客户端配置。")); }
            }
            var box = Ui.Card(detail, 24); Grid.SetColumn(box, 1); grid.Children.Add(box); return grid;
        }
        private async Task PreviewConfiguration()
        {
            var store = controller.Store; ConfigurationPlan plan = null;
            if (!await store.Run(async () => { plan = await store.PreviewConfiguration(); })) return;
            var content = Ui.Stack(Ui.Text("检查以下文件变更，确认后将自动备份并应用。", 12, "Muted"), Ui.Gap(15));
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
            renderResults(); return Ui.Stack(Ui.Text("搜索名称或模型 ID", 11, "Muted"), Ui.Gap(8), input, Ui.Gap(13), filters, Ui.Gap(12), results);
        }
        private FrameworkElement ChecksPage()
        {
            var store = controller.Store; var start = Ui.AsyncButton("开始基础检查", "checks-start", async () => await store.Run(store.CheckConnection), "Primary"); start.IsEnabled = !store.Busy;
            var page = Ui.Stack(Ui.Card(Ui.Between(Ui.Stack(Ui.Text("基础连接检查", 18, "Ink", true), Ui.Gap(7), Ui.Text("健康状态 → Key 权限 → 模型协议，不产生模型调用费用。", 12, "Muted")), start), 22), Ui.Gap(16));
            var checks = store.Checks.Count > 0 ? store.Checks : new System.Collections.Generic.List<ServiceCheck> { new ServiceCheck { Title = "YakCool 服务" }, new ServiceCheck { Title = "Key 权限" }, new ServiceCheck { Title = "模型与协议" } };
            foreach (var check in checks)
            {
                var mark = check.State == "passed" ? "✓" : check.State == "failed" ? "!" : check.State == "running" ? "…" : "○"; var color = check.State == "passed" ? "Green" : check.State == "failed" ? "Danger" : "Muted";
                var item = Ui.Card(Ui.Between(Ui.Row(Ui.Text(mark, 24, color, true), new Border { Width = 16 }, Ui.Stack(Ui.Text(check.Title, 14, "Ink", true), Ui.Gap(6), Ui.Text(check.Detail ?? (check.State == "running" ? "检查中…" : "等待检查"), 11, "Muted"))), Ui.Text(check.State == "passed" ? check.Milliseconds + " ms" : "", 11, "Muted")), 20); item.Margin = new Thickness(0, 0, 0, 10); page.Children.Add(item);
            }
            page.Children.Add(Ui.Gap(18)); var model = Ui.Id(new ComboBox { ItemsSource = store.Models, SelectedIndex = store.Models.Count > 0 ? 0 : -1 }, "probe-model");
            var protocol = Ui.Id(new ComboBox(), "probe-protocol"); Action update = () => { var m = model.SelectedItem as AvailableModel; protocol.ItemsSource = m?.Protocols.Where(YakCoolApi.Protocols.Contains).ToArray(); protocol.SelectedIndex = 0; }; model.SelectionChanged += (s, e) => update(); update();
            var probe = Ui.AsyncButton("发送最小测试", "probe-submit", async () => { var m = model.SelectedItem as AvailableModel; var p = protocol.SelectedItem as string; if (m != null && p != null && controller.Confirm("发送真实模型请求？", "将使用当前 Key 调用“" + m.Name + "”，可能消耗额度。只发送固定文本：Reply exactly with OK.，输出上限为 8 tokens。", "发送测试")) await store.Run(() => store.Probe(m.Id, p, true)); }); probe.IsEnabled = store.Models.Count > 0 && !store.Busy;
            page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("真实模型调用", 17, "Ink", true), Ui.Gap(8), Ui.Text("可选 · 发送前会再次确认，可能消耗少量额度。", 11, "Muted"), Ui.Gap(16), model, Ui.Gap(10), protocol, Ui.Gap(14), probe), 23)); return page;
        }
        private FrameworkElement SettingsPage()
        {
            var store = controller.Store;
            var visible = Ui.Id(new CheckBox { Content = "显示屏幕边缘入口", IsChecked = store.Preferences.EdgeEnabled }, "setting-edge"); visible.Click += (s, e) => { store.Preferences.EdgeEnabled = visible.IsChecked == true; store.SavePreferences(); controller.PositionAll(); };
            var pinned = Ui.Id(new CheckBox { Content = "固定小组件，失去焦点时保持显示", IsChecked = store.Preferences.Pinned }, "setting-pin"); pinned.Click += (s, e) => { store.Preferences.Pinned = pinned.IsChecked == true; store.SavePreferences(); };
            var left = Ui.Button("左侧", "setting-side-left", () => { store.Preferences.OnLeft = true; store.SavePreferences(); controller.PositionAll(); }, store.Preferences.OnLeft ? "Primary" : null);
            var right = Ui.Button("右侧", "setting-side-right", () => { store.Preferences.OnLeft = false; store.SavePreferences(); controller.PositionAll(); }, store.Preferences.OnLeft ? null : "Primary"); right.Margin = new Thickness(10, 0, 0, 0);
            var reset = Ui.Button("恢复默认位置", "setting-reset-position", () => { store.Preferences.OnLeft = false; store.Preferences.YPercent = 58; store.SavePreferences(); controller.PositionAll(); }); reset.Margin = new Thickness(10, 0, 0, 0);
            var startup = Ui.Id(new CheckBox { Content = "登录 Windows 时启动 YConnect", IsChecked = controller.StartupEnabled, IsEnabled = !store.Environment.Development }, "setting-startup"); startup.Click += (s, e) => { try { controller.SetStartup(startup.IsChecked == true); } catch (Exception error) { store.SetError(error.Message); } };
            var page = Ui.Stack(Ui.Card(Ui.Stack(Ui.Text("桌面小组件", 17, "Ink", true), Ui.Gap(16), visible, pinned, Ui.Gap(14), Ui.Text("贴边位置", 11, "Muted"), Ui.Gap(10), Ui.Row(left, right, reset), Ui.Gap(13), Ui.Text("拖动屏幕边缘的把手可调整垂直位置，右键可切换左右侧。", 11, "Muted")), 23), Ui.Gap(14));
            var light = Ui.Button("浅色", "setting-theme-light", () => { store.Preferences.Theme = "light"; Ui.SetTheme("light"); store.SavePreferences(); }, store.Preferences.Theme == "light" ? "Primary" : null);
            var dark = Ui.Button("深色", "setting-theme-dark", () => { store.Preferences.Theme = "dark"; Ui.SetTheme("dark"); store.SavePreferences(); }, store.Preferences.Theme == "dark" ? "Primary" : null); dark.Margin = new Thickness(10, 0, 0, 0);
            page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("外观", 17, "Ink", true), Ui.Gap(14), Ui.Row(light, dark)), 23)); page.Children.Add(Ui.Gap(14));
            var direct = Ui.Id(new CheckBox { Content = "直连网络，不使用代理（重启后生效）", IsChecked = store.Preferences.BypassProxy }, "setting-direct-network"); direct.Click += (s, e) => { store.Preferences.BypassProxy = direct.IsChecked == true; store.SavePreferences(); store.SetMessage("网络设置已保存，请退出并重新打开 YConnect 生效。系统代理未修改。"); };
            page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("网络", 17, "Ink", true), Ui.Gap(12), direct, Ui.Gap(7), Ui.Text("仅影响 YConnect 的 API 请求和独立扫码窗口，不修改系统代理。", 11, "Muted")), 23)); page.Children.Add(Ui.Gap(14));
            page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("启动与存储", 17, "Ink", true), Ui.Gap(14), startup, Ui.Gap(10), Ui.Text(store.Environment.Development ? "开发与演示模式不修改正式启动项。" : "登录系统后常驻托盘和屏幕边缘。", 11, "Muted"), Ui.Gap(18), Ui.Text("本地数据", 11, "Muted", true), Ui.Gap(6), Ui.Text(store.Environment.DataRoot, 11, "Muted"), Ui.Gap(14), Ui.Button("打开数据目录", "setting-open-data", controller.OpenData)), 23)); page.Children.Add(Ui.Gap(14));
            var logout = Ui.AsyncButton("退出当前账户 / Key", "setting-signout", async () => { if (controller.Confirm("退出登录？", "退出当前 YakCool 连接。已应用的客户端配置可以在“客户端接入”中单独恢复。", "退出登录")) await store.Run(store.SignOut); }); logout.IsEnabled = store.Authenticated;
            page.Children.Add(Ui.Card(Ui.Stack(Ui.Text("账户与安全", 17, "Ink", true), Ui.Gap(10), Ui.Text("会话使用 Windows DPAPI 加密。应用配置前加密备份，最近 20 份可恢复。", 11, "Muted"), Ui.Gap(16), logout), 23)); return page;
        }
    }
}
