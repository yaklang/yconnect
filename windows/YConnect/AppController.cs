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
        }
        private void StoreChanged()
        {
            if (renderQueued) return; renderQueued = true;
            Application.Current.Dispatcher.BeginInvoke(new Action(() => { renderQueued = false; Widget.Render(); manager?.Render(); UpdateTray(); }), DispatcherPriority.Background);
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
            if (Edge == null || Widget == null || ActiveScreen == null) return;
            var scale = WindowsDesktop.Scale(ActiveScreen); var work = ActiveScreen.WorkingArea;
            Widget.SetMaximumHeight(work.Height / scale - 16);
            var edge = WindowsDesktop.EdgeBounds(work, scale, Store.Preferences.OnLeft, Store.Preferences.YPercent);
            var rectangle = WindowsDesktop.WidgetBounds(work, edge, scale, Store.Preferences.OnLeft, Widget.ActualWidth > 0 ? Widget.ActualWidth : 408, Widget.ActualHeight > 0 ? Widget.ActualHeight : 620);
            WindowsDesktop.Move(Widget, rectangle.X, rectangle.Y);
        }
        public void ShowWidget() { Edge?.CloseQuick(); Widget.Render(); Widget.Show(); PositionAll(); Widget.Activate(); }
        public void ToggleWidget() { if (Widget.IsVisible) Widget.Hide(); else ShowWidget(); }
        public void ShowManager(string section) { Manager.Navigate(section); Manager.Show(); if (Manager.WindowState == WindowState.Minimized) Manager.WindowState = WindowState.Normal; Manager.Activate(); }
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
            using (var key = Registry.CurrentUser.CreateSubKey(StartupKey)) { if (enabled) key.SetValue("YConnect", StartupCommand, RegistryValueKind.String); else key.DeleteValue("YConnect", false); }
            if (StartupEnabled != enabled) throw new IOException("Windows 未保存启动项"); Store.SetMessage(enabled ? "已开启开机启动" : "已关闭开机启动");
        }
        public void CopyKey()
        {
            try { CopySensitive(Store.RequireKey()); Store.SetMessage("API Key 已复制，60 秒后自动清理剪贴板"); } catch (Exception e) { Store.SetError(e.Message); }
        }
        public void CopyAccess(string model = null)
        {
            try
            {
                var text = "YConnect · YakCool 接入信息\n\nAPI Key\n" + Store.RequireKey() + "\n\nChat Completions: " + YakCoolApi.Gateway + "/v1/chat/completions\nResponses: " + YakCoolApi.Gateway + "/v1/responses\nAnthropic Messages: " + YakCoolApi.Gateway + "/v1/messages";
                if (model != null && Store.Models.Any(m => m.Id == model)) text += "\n\n模型: " + model;
                CopySensitive(text); Store.SetMessage("接入信息已复制");
            }
            catch (Exception e) { Store.SetError(e.Message); }
        }
        private static void CopySensitive(string value)
        {
            Clipboard.SetText(value); var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) }; timer.Tick += (s, e) => { timer.Stop(); try { if (Clipboard.ContainsText() && Clipboard.GetText() == value) Clipboard.Clear(); } catch { } }; timer.Start();
        }
        public void CopyEndpoint(string protocol)
        {
            var suffix = protocol == "responses" ? "responses" : protocol == "anthropic_messages" ? "messages" : "chat/completions";
            try { Clipboard.SetText(YakCoolApi.Gateway + "/v1/" + suffix); Store.SetMessage("接入地址已复制"); } catch (Exception e) { Store.SetError(e.Message); }
        }
        public void OpenData() { Directory.CreateDirectory(Store.Environment.DataRoot); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Store.Environment.DataRoot) { UseShellExecute = true }); }
        private void UpdateTray()
        {
            var status = Store.Remaining.HasValue ? "余额 ¥" + Store.Remaining.Value.ToString("F2") : Store.Authenticated ? "已连接" : "尚未连接"; tray.Text = "YConnect · " + status;
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
        public void Dispose() { refresh.Stop(); activationWait?.Unregister(null); tray.Visible = false; tray.Dispose(); SystemEvents.DisplaySettingsChanged -= DisplayChanged; Store.Changed -= StoreChanged; (Store.Api as IDisposable)?.Dispose(); login?.Close(); }
    }
}
