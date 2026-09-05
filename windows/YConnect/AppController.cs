using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using YConnect.Core;
using YConnect.Native;
using YConnect.Views;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace YConnect
{
    public sealed class AppController : IDisposable
    {
        public YConnectStore Store { get; }
        public WidgetWindow Widget { get; }
        private ManagerWindow manager;
        public ManagerWindow Manager => manager ?? (manager = new ManagerWindow(this));
        public EdgeDock Edge { get; }
        public Forms.Screen ActiveScreen { get; set; } = Forms.Screen.PrimaryScreen;
        public bool Quitting { get; private set; }
        public bool ModalOpen { get; private set; }
        public Action<DialogWindow> DialogOpenedForValidation { get; set; }
        private readonly Forms.NotifyIcon tray;
        private readonly DispatcherTimer refresh = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        private readonly System.Threading.RegisteredWaitHandle activationWait;
        private WebLoginWindow login;
        private bool renderQueued;
        private readonly DispatcherTimer feedbackTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        private string feedbackMessage, copiedId;
        public sealed class Endpoint { public string Id, Label, Url; }
        public static readonly Endpoint[] Endpoints = {
            new Endpoint { Id="openai-base", Label="OpenAI 兼容基址", Url=YakCoolApi.Gateway+"/v1" },
            new Endpoint { Id="chat_completions", Label="Chat Completions", Url=YakCoolApi.Gateway+"/v1/chat/completions" },
            new Endpoint { Id="responses", Label="Responses API", Url=YakCoolApi.Gateway+"/v1/responses" },
            new Endpoint { Id="anthropic-base", Label="Anthropic 基址", Url=YakCoolApi.Gateway },
            new Endpoint { Id="anthropic_messages", Label="Anthropic Messages", Url=YakCoolApi.Gateway+"/v1/messages" }
        };
        private const string StartupKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        public AppController(YConnectStore store, System.Threading.EventWaitHandle activation = null)
        {
            Store = store; Ui.SetTheme(Store.Preferences.Theme);
            Widget = new WidgetWindow(this); Edge = new EdgeDock(this);
            tray = new Forms.NotifyIcon { Icon = CreateTrayIcon(), Text = "YConnect · 连接你的 YakCool", Visible = true };
            tray.MouseClick += (s, e) => { if (e.Button == Forms.MouseButtons.Left) ToggleWidget(); }; tray.DoubleClick += (s, e) => ShowManager("overview");
            Store.Changed += StoreChanged; UpdateTray();
            refresh.Tick += async (s, e) => { if (!Store.Busy && Store.Authenticated) await Store.Run(Store.Refresh); }; refresh.Start();
            if (activation != null) activationWait = System.Threading.ThreadPool.RegisterWaitForSingleObject(activation, (s, t) => Application.Current.Dispatcher.BeginInvoke(new Action(() => { if (!Quitting) ShowWidget(); })), null, System.Threading.Timeout.Infinite, false);
            SystemEvents.DisplaySettingsChanged += DisplayChanged;
            feedbackTimer.Tick += (s, e) => { feedbackTimer.Stop(); copiedId = null; Store.ClearMessage(feedbackMessage); Store.Notify(); };
            try { StartupPolicy.Initialize(Store.Environment.Development, Store.HadPreferencesFile && Store.LegacyStartupPreferences, Store.Preferences, () => StartupEnabled, WriteStartup, Store.SavePreferences); }
            catch (Exception e) { Store.SetError(e.Message); }
        }
        private void StoreChanged()
        {
            if (renderQueued) return; renderQueued = true;
            Application.Current.Dispatcher.BeginInvoke(new Action(() => { renderQueued = false; Widget.Render(); manager?.Render(); Edge.Refresh(); UpdateTray(); if (!string.IsNullOrEmpty(Store.Message) && feedbackMessage != Store.Message) { feedbackMessage = Store.Message; feedbackTimer.Stop(); feedbackTimer.Start(); } }), DispatcherPriority.Background);
        }
        private void DisplayChanged(object sender, EventArgs args) => Application.Current.Dispatcher.BeginInvoke(new Action(() => { ActiveScreen = Forms.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == ActiveScreen.DeviceName) ?? Forms.Screen.PrimaryScreen; PositionAll(); }));
        public void PositionAll()
        {
            if (Edge == null || Widget == null || ActiveScreen == null) return;
            Edge.AlignSide(); var scale = WindowsDesktop.Scale(ActiveScreen); var bounds = WindowsDesktop.EdgeBounds(ActiveScreen.WorkingArea, scale, Store.Preferences.OnLeft, Store.Preferences.YPercent);
            if (Store.Preferences.EdgeEnabled) { if (!Edge.IsVisible) Edge.Show(); WindowsDesktop.Move(Edge, bounds.X, bounds.Y); } else { Edge.CloseQuick(); Edge.Hide(); }
            PositionWidget();
        }
        public void PositionWidget()
        {
            if (Edge == null || Widget == null || ActiveScreen == null || Widget.IsDragging) return;
            var scale = WindowsDesktop.Scale(ActiveScreen); var work = ActiveScreen.WorkingArea;
            Widget.SetMaximumHeight(work.Height / scale - 16);
            var edge = WindowsDesktop.EdgeBounds(work, scale, Store.Preferences.OnLeft, Store.Preferences.YPercent);
            var rectangle = WindowsDesktop.WidgetBounds(work, edge, scale, Store.Preferences.OnLeft, Widget.ActualWidth > 0 ? Widget.ActualWidth : 408, Widget.ActualHeight > 0 ? Widget.ActualHeight : 620);
            WindowsDesktop.Move(Widget, rectangle.X, rectangle.Y);
        }
        public void ShowWidget() { Edge?.CloseQuick(); Widget.Render(); Widget.Reveal(); PositionAll(); Widget.Activate(); }
        public void ToggleWidget() { if (Widget.IsVisible) Widget.Hide(); else ShowWidget(); }
        public void ShowManager(string section) { Manager.Navigate(section); Manager.Show(); if (Manager.WindowState == WindowState.Minimized) Manager.WindowState = WindowState.Normal; Manager.Activate(); }
        public void CommitWidgetDrag()
        {
            var bounds = WindowsDesktop.Bounds(Widget); var center = new Drawing.Point(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
            ActiveScreen = Forms.Screen.FromPoint(center); var work = ActiveScreen.WorkingArea;
            Store.Preferences.OnLeft = center.X < work.Left + work.Width / 2;
            Store.Preferences.YPercent = WindowsDesktop.Clamp((center.Y - work.Top) / (double)work.Height * 100, 2, 98);
            PositionAll(); var scale = WindowsDesktop.Scale(ActiveScreen); var edge = WindowsDesktop.EdgeBounds(work, scale, Store.Preferences.OnLeft, Store.Preferences.YPercent);
            var target = WindowsDesktop.WidgetBounds(work, edge, scale, Store.Preferences.OnLeft, Widget.ActualWidth, Widget.ActualHeight);
            WindowsDesktop.Glide(Widget, target.X, target.Y, Motion.Allowed, () => { Widget.IsDragging = false; Store.SavePreferences(); PositionAll(); });
        }
        public async void NewKey() { try { ShowManager("keys"); await Manager.CreateKey(); } catch (Exception e) { Store.SetError(e.Message); } }
        public async Task SignOut() { if (Store.Authenticated && Confirm("登出 YConnect？", "清除本次登录。已应用的客户端配置会保留，可在客户端适配中单独恢复。", "登出")) await Store.Run(Store.SignOut); }
        public async Task LoginAccount()
        {
            if (Store.Environment.Demo) { await Store.Run(() => Store.LoginAccount("demo-public-session-only")); return; }
            if (login != null) { login.Activate(); return; }
            login = new WebLoginWindow(this); login.Closed += (s, e) => login = null; login.Show();
        }
        public bool? ShowDialog(DialogWindow dialog)
        {
            ModalOpen = true;
            try
            {
                if (DialogOpenedForValidation != null) dialog.ContentRendered += (s, e) => DialogOpenedForValidation(dialog);
                return dialog.ShowDialog();
            }
            finally { ModalOpen = false; }
        }
        public bool Confirm(string title, string description, string action, bool danger = false)
        {
            var owner = manager?.IsActive == true ? (Window)manager : Widget;
            return ShowDialog(new DialogWindow(owner, title, Ui.Text(description, 13, "Muted"), action, danger)) == true;
        }
        public bool StartupEnabled
        {
            get { if (Store.Environment.Development) return false; using (var key = Registry.CurrentUser.OpenSubKey(StartupKey)) return key?.GetValue("YConnect") is string value && value == StartupCommand; }
        }
        private string StartupCommand => "\"" + System.Reflection.Assembly.GetExecutingAssembly().Location + "\" --background";
        public void SetStartup(bool enabled)
        {
            if (Store.Environment.Development) throw new InvalidOperationException("请在正式版设置开机启动");
            if (!enabled && !Confirm("关闭开机启动？", "关闭后需要手动打开 YConnect，屏幕边缘入口不会在登录 Windows 时出现。", "关闭启动")) { Store.Notify(); return; }
            WriteStartup(enabled);
            if (StartupEnabled != enabled) throw new IOException("Windows 未保存启动项"); Store.Preferences.StartupChoice = enabled; Store.SavePreferences(); Store.SetMessage(enabled ? "已开启开机启动" : "已关闭开机启动");
        }
        private void WriteStartup(bool enabled) { using (var key = Registry.CurrentUser.CreateSubKey(StartupKey)) { if (enabled) key.SetValue("YConnect", StartupCommand, RegistryValueKind.String); else key.DeleteValue("YConnect", false); } }
        public void CopyKey()
        {
            try { CopyText(Store.RequireKey(), "key", true); } catch (Exception e) { Store.SetError(e.Message); }
        }
        public void CopyAccess(string model = null)
        {
            try
            {
                model = model ?? Store.Preferences.CurrentModel;
                if (!Store.Models.Any(m => m.Id == model)) model = Store.FrequentModels.FirstOrDefault()?.Id;
                var text = "以下接入信息由 YConnect 生成。\n你可以按照自己的工具和使用习惯，选择合适的协议接入 YakCool。\n\n";
                if (model != null && Store.Models.Any(m => m.Id == model)) text += "模型: " + model + "\n";
                text += string.Join("\n", Endpoints.Select(e => e.Label + ": " + e.Url)) + "\nAPI Key: " + Store.RequireKey();
                CopyText(text, "share", true);
            }
            catch (Exception e) { Store.SetError(e.Message); }
        }
        private static void CopySensitive(string value)
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) }; timer.Tick += (s, e) => { timer.Stop(); try { if (Clipboard.ContainsText() && Clipboard.GetText() == value) Clipboard.Clear(); } catch { } }; timer.Start();
        }
        public void CopyEndpoint(string protocol)
        {
            var endpoint = Endpoints.FirstOrDefault(e => e.Id == protocol); if (endpoint != null) CopyText(endpoint.Url, protocol);
        }
        public string CopyLabel(string id, string original) => copiedId == id ? "✓ 已复制" : original;
        public void CopyModelId(string id) { try { Store.RememberModel(id); CopyText(id, "model:" + id); } catch (Exception e) { Store.SetError(e.Message); } }
        private int copyRevision;
        public async void CopyText(string value, string id, bool sensitive = false)
        {
            var revision = ++copyRevision;
            for (var attempt = 0; attempt < 6; attempt++)
            {
                if (revision != copyRevision) return;
                try
                {
                    NativeClipboard.SetText(new System.Windows.Interop.WindowInteropHelper(Widget).EnsureHandle(), value);
                    if (sensitive) CopySensitive(value);
                    copiedId = id; feedbackTimer.Stop(); feedbackTimer.Start(); Store.Notify(); return;
                }
                catch (ExternalException) { if (attempt < 5) await Task.Delay(45); }
                catch { break; }
            }
            if (revision == copyRevision) Store.SetError("暂时无法写入剪贴板，请重试");
        }
        public void OpenData() { Directory.CreateDirectory(Store.Environment.DataRoot); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Store.Environment.DataRoot) { UseShellExecute = true }); }
        private void UpdateTray()
        {
            var status = BalancePresentation.From(Store, Store.Preferences.PeekPercentageOnly).Value; tray.Text = "YConnect · " + status;
            var old = tray.ContextMenuStrip; var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("打开小组件", null, (s, e) => ShowWidget()); menu.Items.Add("打开管理中心", null, (s, e) => ShowManager("overview"));
            var copy = menu.Items.Add("复制当前 API Key", null, (s, e) => CopyKey()); copy.Enabled = !string.IsNullOrEmpty(Store.CurrentKey); menu.Items.Add(new Forms.ToolStripSeparator());
            var visible = new Forms.ToolStripMenuItem("显示屏幕边缘入口") { Checked = Store.Preferences.EdgeEnabled }; visible.Click += (s, e) => { Store.Preferences.EdgeEnabled = !Store.Preferences.EdgeEnabled; Store.SavePreferences(); PositionAll(); }; menu.Items.Add(visible);
            var pin = new Forms.ToolStripMenuItem("固定小组件") { Checked = Store.Preferences.Pinned }; pin.Click += (s, e) => { Store.Preferences.Pinned = !Store.Preferences.Pinned; Store.SavePreferences(); }; menu.Items.Add(pin);
            menu.Items.Add("移至鼠标所在显示器", null, (s, e) => { ActiveScreen = Forms.Screen.FromPoint(Forms.Cursor.Position); PositionAll(); ShowWidget(); }); menu.Items.Add(new Forms.ToolStripSeparator()); menu.Items.Add("退出 YConnect", null, (s, e) => Quit()); tray.ContextMenuStrip = menu; old?.Dispose();
        }
        [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
        private static Drawing.Icon CreateTrayIcon()
        {
            using (var bitmap = new Drawing.Bitmap(64, 64))
            using (var graphics = Drawing.Graphics.FromImage(bitmap))
            using (var brush = new Drawing.SolidBrush(Drawing.Color.FromArgb(185, 105, 83)))
            using (var pen = new Drawing.Pen(Drawing.Color.White, 5) { StartCap = Drawing.Drawing2D.LineCap.Round, EndCap = Drawing.Drawing2D.LineCap.Round, LineJoin = Drawing.Drawing2D.LineJoin.Round })
            {
                graphics.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias; graphics.FillEllipse(brush, 2, 2, 60, 60); graphics.DrawLines(pen, new[] { new Drawing.Point(19, 19), new Drawing.Point(32, 35), new Drawing.Point(45, 19) }); graphics.DrawLine(pen, 32, 35, 32, 48);
                var handle = bitmap.GetHicon(); try { return (Drawing.Icon)Drawing.Icon.FromHandle(handle).Clone(); } finally { DestroyIcon(handle); }
            }
        }
        public void Quit() { Quitting = true; Dispose(); Application.Current.Shutdown(); }
        public void Dispose() { refresh.Stop(); feedbackTimer.Stop(); Edge.Stop(); activationWait?.Unregister(null); tray.Visible = false; tray.Dispose(); SystemEvents.DisplaySettingsChanged -= DisplayChanged; Store.Changed -= StoreChanged; (Store.Api as IDisposable)?.Dispose(); login?.Close(); }
    }
}
