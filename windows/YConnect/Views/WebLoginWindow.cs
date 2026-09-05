using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using YConnect.Core;

namespace YConnect.Views
{
    public sealed class WebLoginWindow : Window
    {
        private readonly AppController controller;
        private readonly WebView2 web = new WebView2();
        private readonly TextBlock status = Ui.Text("正在打开 YakCool 官方登录页面…", 11, "Muted");
        private readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
        private bool inspecting;
        private string rejected;
        private DateTime lastAttempt;
        private bool closed;
        private readonly TaskCompletionSource<bool> ready = new TaskCompletionSource<bool>();
        public Task<bool> Ready => ready.Task;
        public string StatusText => status.Text;
        public string PageAddress => web.CoreWebView2?.Source;
        public async Task<string> PageReadiness() => await web.CoreWebView2.ExecuteScriptAsync("JSON.stringify({title:document.title,loginFrame:!!document.querySelector('#wx-login-container iframe'),visibleText:document.body.innerText.slice(0,1500)})");
        public Task CapturePage(Stream output) => web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, output);
        public static bool IsAllowed(string value)
        {
            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !uri.IsDefaultPort || uri.UserInfo != "") return false;
            return new[] { "yakcool.com", "yaklang.com", "weixin.qq.com", "wx.qq.com" }.Any(h => uri.Host.Equals(h, StringComparison.OrdinalIgnoreCase) || uri.Host.EndsWith("." + h, StringComparison.OrdinalIgnoreCase));
        }
        public WebLoginWindow(AppController controller)
        {
            this.controller = controller; Title = "YConnect · YakCool 官方扫码登录"; Width = 880; Height = 820; MinWidth = 680; MinHeight = 550; WindowStartupLocation = WindowStartupLocation.CenterScreen; SetResourceReference(BackgroundProperty, "Page"); web.DefaultBackgroundColor = System.Drawing.Color.White;
            var panel = new DockPanel { Margin = new Thickness(16) };
            var header = Ui.Between(Ui.Stack(Ui.Text("登录 YakCool", 20, "Ink", true), Ui.Gap(5), Ui.Text("在官方页面完成微信扫码，账户会话由 Windows 加密保护。", 12, "Muted")), Ui.Badge("HTTPS · yakcool.com")); header.Margin = new Thickness(0, 0, 0, 14); DockPanel.SetDock(header, Dock.Top); panel.Children.Add(header);
            var retry = Ui.AsyncButton("重新加载", "web-login-retry", async () => { if (web.CoreWebView2 == null) await Initialize(); else { rejected = null; web.CoreWebView2.Navigate(YakCoolApi.Origin + "/login"); } }, "Quiet"); retry.FontSize = 11;
            var footer = Ui.Between(status, retry); footer.Margin = new Thickness(0, 10, 0, 0); DockPanel.SetDock(footer, Dock.Bottom); panel.Children.Add(footer); panel.Children.Add(web); Content = panel;
            Loaded += async (s, e) => await Initialize(); timer.Tick += async (s, e) => await InspectCookies();
            Closed += (s, e) => { closed = true; timer.Stop(); ready.TrySetResult(false); web.Dispose(); };
        }
        private async Task Initialize()
        {
            try
            {
                var root = Path.Combine(controller.Store.Environment.DataRoot, "WebLogin"); SecureFiles.ProtectDirectory(root);
                var options = new CoreWebView2EnvironmentOptions(controller.Store.Environment.BypassProxy ? "--no-proxy-server" : null);
                var environment = await CoreWebView2Environment.CreateAsync(null, root, options);
                if (closed) return;
                await web.EnsureCoreWebView2Async(environment);
                if (closed) return;
                // Leave room for the official QR card and its refresh controls
                // on 1080p desktops; larger windows retain normal page scale.
                web.ZoomFactor = web.ActualHeight < 700 ? .85 : 1;
                web.CoreWebView2.Settings.AreDevToolsEnabled = false; web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                web.CoreWebView2.Settings.IsPasswordAutosaveEnabled = false; web.CoreWebView2.Settings.IsGeneralAutofillEnabled = false;
                web.CoreWebView2.PermissionRequested += (s, e) => e.State = CoreWebView2PermissionState.Deny;
                web.CoreWebView2.NavigationStarting += (s, e) => { if (!IsAllowed(e.Uri)) { e.Cancel = true; status.Text = "已阻止离开 YakCool 登录流程"; } };
                web.CoreWebView2.NewWindowRequested += (s, e) => { e.Handled = true; if (IsAllowed(e.Uri)) web.CoreWebView2.Navigate(e.Uri); };
                web.CoreWebView2.DownloadStarting += (s, e) => e.Cancel = true;
                web.CoreWebView2.ServerCertificateErrorDetected += (s, e) => e.Action = CoreWebView2ServerCertificateErrorAction.Cancel;
                web.CoreWebView2.NavigationCompleted += (s, e) => { if (e.IsSuccess) { status.Text = "请在 YakCool 官方页面完成微信扫码"; ready.TrySetResult(true); } else { status.Text = "页面加载失败（" + e.WebErrorStatus + "），请检查网络后重新加载。"; ready.TrySetResult(false); } };
                // Remove only our public session from this dedicated WebView profile.
                foreach (var cookie in await web.CoreWebView2.CookieManager.GetCookiesAsync(YakCoolApi.Origin)) if (cookie.Name == "yakcool_user_session") web.CoreWebView2.CookieManager.DeleteCookie(cookie);
                web.CoreWebView2.Navigate(YakCoolApi.Origin + "/login"); status.Text = "请在 YakCool 官方页面完成微信扫码"; timer.Start();
            }
            catch (Exception error) { if (!closed) status.Text = "无法打开扫码页面：" + YakCoolApi.Redact(error.Message) + "。请检查网络及 Microsoft Edge WebView2 Runtime 后重试。"; ready.TrySetResult(false); }
        }
        private async Task InspectCookies()
        {
            if (closed || inspecting || web.CoreWebView2 == null || controller.Store.Busy) return;
            inspecting = true;
            try
            {
                var cookies = await web.CoreWebView2.CookieManager.GetCookiesAsync(YakCoolApi.Origin);
                if (closed) return;
                var value = cookies.FirstOrDefault(c => c.Name == "yakcool_user_session" && (c.Domain == "yakcool.com" || c.Domain == ".yakcool.com") && c.IsSecure && (c.IsSession || c.Expires > DateTime.UtcNow));
                if (value == null || (value.Value == rejected && DateTime.UtcNow - lastAttempt < TimeSpan.FromSeconds(5))) return;
                lastAttempt = DateTime.UtcNow; status.Text = "正在验证公开用户会话…";
                if (await controller.Store.Run(() => controller.Store.LoginAccount(value.Value))) { timer.Stop(); if (!closed) { web.CoreWebView2.CookieManager.DeleteCookie(value); Close(); } controller.ShowWidget(); }
                else { rejected = value.Value; status.Text = controller.Store.Error; }
            }
            catch (Exception e) { status.Text = YakCoolApi.Redact(e.Message); }
            finally { inspecting = false; }
        }
    }
}
