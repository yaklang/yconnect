using System;
using System.Globalization;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using QRCoder;
using YConnect.Core;
using YConnect.Native;

namespace YConnect.Views
{
    public sealed class RechargeWindow : Window
    {
        private readonly AppController app;
        private readonly ContentControl body = new ContentControl();
        private readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        private RechargeSession session;
        private TextBlock countdown;
        private string amount = "50", channel = "wechat", error, balanceMessage;
        private bool busy, closed, editing, balanceRefreshed, loginRequired;
        private DateTime lastQuery = DateTime.MinValue;
        public RechargeSession Session => session;
        public RechargeWindow(AppController app, RechargeSession existing = null)
        {
            this.app = app; session = existing;
            if (session?.HasOrder == true) { amount = session.Amount; channel = session.Channel; }
            Title = "YConnect · 账户充值"; Width = 460; MaxHeight = Math.Max(400, SystemParameters.WorkArea.Height - 40);
            SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize; WindowStyle = WindowStyle.None;
            AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = true;
            WindowStartupLocation = WindowStartupLocation.CenterScreen; UseLayoutRounding = true; SnapsToDevicePixels = true;
            var header = Ui.Between(Ui.IconLabel(Ui.Logo(30), Ui.Stack(Ui.Text("账户充值", 19, "Ink", true), Ui.Text("YAKCOOL · 为下一次灵感续航", 11, "Muted")), 30, 10), Ui.IconButton("\uE8BB", "关闭充值窗口", "recharge-close", Close));
            var content = Ui.Stack(header, Ui.Gap(18), body, Ui.Gap(14), Ui.Text("一次充值 · 不自动续费 · 余额用于 AI 模型服务", 11, "Muted"));
            var shell = Ui.Card(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = MaxHeight - 50 }, 22, "Page");
            shell.Margin = new Thickness(6); shell.SetResourceReference(Border.BorderBrushProperty, "WindowFrame"); Content = shell;
            DragSurface.Attach(this, shell);
            PreviewKeyDown += (s, e) => { if (e.Key == Key.Escape) { Close(); e.Handled = true; } };
            app.Store.Changed += StoreChanged;
            Loaded += async (s, e) => { timer.Start(); if (session?.HasOrder == true) await Check(); };
            Closed += (s, e) => { closed = true; timer.Stop(); app.Store.Changed -= StoreChanged; };
            timer.Tick += async (s, e) =>
            {
                if (closed || busy || editing || session == null) return;
                if (!session.IsCurrent) { StoreChanged(); return; }
                if (countdown != null) { countdown.Text = Countdown(); if (!session.CanShowQr) Render(); }
                if (session.Paid && !balanceRefreshed && DateTime.UtcNow - lastQuery > TimeSpan.FromSeconds(5)) await RefreshBalance();
                // Stop automatic polling after the local QR window; manual checks still reconcile late payments.
                else if (session.NeedsPolling && session.SecondsLeft > 0 && DateTime.UtcNow - lastQuery > TimeSpan.FromSeconds(2)) await Check();
            };
            StoreChanged();
        }
        private void StoreChanged()
        {
            if (closed) return;
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(StoreChanged)); return; }
            var previous = session;
            if (session != null && !session.IsCurrent) { session = null; error = "账户已变更，请核对充值账户后继续。"; editing = false; }
            if (session == null && app.Store.Mode == "account" && !loginRequired) session = app.RechargeSession;
            // Do not rebuild an amount TextBox on background account updates; preserve focus and caret.
            if (previous != session || body.Content == null || session == null || !(body.Content is FrameworkElement current) || (string)current.Tag != "form") Render();
        }
        private Button Action(string text, string id, Func<Task> action, string style = null)
        {
            var button = Ui.Button(text, id, null, style); button.IsEnabled = !busy;
            button.Click += async (s, e) => { if (!busy) await action(); }; return button;
        }
        private async Task Create()
        {
            if (closed || busy || session == null) return;
            long cents;
            try { cents = RechargeSession.ParseAmount(amount); } catch (Exception ex) { error = ex.Message; Render(); return; }
            busy = true; error = null; Render();
            try { await session.Create(cents, channel); editing = false; balanceRefreshed = false; }
            catch (Exception ex) { Fail(ex); }
            finally { busy = false; if (!closed) Render(); }
            if (!closed && session?.Paid == true) await RefreshBalance();
        }
        private void Fail(Exception ex)
        {
            error = YakCoolApi.Redact(ex.Message);
            if (ex is ApiRequestException request && request.StatusCode == 401) { loginRequired = true; timer.Stop(); }
        }
        private async Task Check()
        {
            if (closed || busy || session == null) return;
            var previousState = session.State; var previousError = error; var previousQr = session.CanShowQr; var previousLogin = loginRequired;
            busy = true; lastQuery = DateTime.UtcNow;
            try { await session.Query(); error = null; }
            catch (Exception ex) { Fail(ex); }
            finally { busy = false; if (!closed && (previousState != session?.State || previousError != error || previousQr != session?.CanShowQr || previousLogin != loginRequired)) Render(); }
            if (!closed && session?.Paid == true && !balanceRefreshed) await RefreshBalance();
        }
        private async Task RefreshBalance()
        {
            if (closed || busy || app.Store.Busy || session?.IsCurrent != true || !session.Paid) return;
            busy = true; lastQuery = DateTime.UtcNow;
            try
            {
                balanceRefreshed = await app.Store.Run(app.Store.Refresh);
                balanceMessage = balanceRefreshed ? "余额已同步到控制台与桌面小组件" : "支付已确认，余额暂未刷新，请稍后重试。";
            }
            finally { busy = false; if (!closed) Render(); }
        }
        private string Countdown() => session.SecondsLeft > 0 ? "支付码展示剩余 " + session.SecondsLeft / 60 + ":" + (session.SecondsLeft % 60).ToString("00") + " · 自动查询到账" : "支付码已隐藏 · 已付款可继续查询结果";
        public void Render()
        {
            if (closed) return;
            countdown = null;
            var panel = Ui.Stack();
            if (app.Store.Environment.Demo) { panel.Children.Add(Ui.Notice("演示环境 · 仅验证界面，不可付款，不产生真实订单")); panel.Children.Add(Ui.Gap(10)); }
            if (!string.IsNullOrEmpty(error)) { panel.Children.Add(Ui.Notice(error, true)); panel.Children.Add(Ui.Gap(10)); }
            if (session == null || loginRequired)
            {
                panel.Children.Add(Ui.Text(loginRequired ? "登录已过期，请重新连接账户" : "先登录要充值的 YakCool 账户", 16, "Ink", true));
                panel.Children.Add(Ui.Gap(8)); panel.Children.Add(Ui.Text("API Key 只能访问模型，无法确认充值归属。账户登录后再选择金额和支付方式。", 12, "Muted")); panel.Children.Add(Ui.Gap(16));
                panel.Children.Add(Action("登录 YakCool 账户", "recharge-login", async () => { Close(); await app.LoginForRecharge(); }, "Primary"));
            }
            else
            {
                panel.Children.Add(Ui.Card(Ui.Between(Ui.IconLabel(Ui.Avatar(session.AccountName, 30), Ui.Stack(Ui.Text(session.AccountName, 13, "Ink", true), Ui.Text("充值至此账户的 AI 服务余额", 11, "Muted")), 30, 9), Ui.Text(app.Store.Remaining.HasValue ? "¥" + app.Store.Remaining.Value.ToString("0.00") : "—", 19, "Ink", true)), 12));
                panel.Children.Add(Ui.Gap(14));
                if (!session.HasOrder || editing)
                {
                    panel.Tag = "form";
                    panel.Children.Add(Ui.Between(Ui.Text("充值金额", 13, "Ink", true), Ui.Text("¥1–¥10,000", 11, "Muted"))); panel.Children.Add(Ui.Gap(8));
                    var input = Ui.Id(new TextBox { Text = amount, FontSize = 24, Padding = new Thickness(12, 8, 12, 8), MaxLength = 8, IsEnabled = !busy }, "recharge-amount");
                    System.Windows.Automation.AutomationProperties.SetName(input, "充值金额，人民币，最多两位小数");
                    input.TextChanged += (s, e) => amount = input.Text;
                    panel.Children.Add(input); panel.Children.Add(Ui.Gap(8));
                    var presets = new UIElement[4]; var values = new[] { "50", "100", "200", "500" };
                    for (var i = 0; i < values.Length; i++) { var value = values[i]; presets[i] = Action("¥" + value, "recharge-preset-" + value, () => { amount = value; error = null; Render(); return Task.CompletedTask; }, amount == value ? "Primary" : null); }
                    panel.Children.Add(Ui.Columns(4, presets)); panel.Children.Add(Ui.Gap(6));
                    panel.Children.Add(Ui.Text("支付方式", 13, "Ink", true)); panel.Children.Add(Ui.Gap(8));
                    panel.Children.Add(Ui.Columns(2, Action((channel == "wechat" ? "✓  " : "") + "微信支付", "recharge-wechat", () => { channel = "wechat"; Render(); return Task.CompletedTask; }, channel == "wechat" ? "Primary" : null), Action((channel == "alipay" ? "✓  " : "") + "支付宝", "recharge-alipay", () => { channel = "alipay"; Render(); return Task.CompletedTask; }, channel == "alipay" ? "Primary" : null)));
                    panel.Children.Add(Ui.Gap(8)); panel.Children.Add(Action(busy ? "正在核对订单…" : "确认金额 · 生成支付码", "recharge-create", Create, "Primary"));
                    panel.Children.Add(Ui.Gap(8)); panel.Children.Add(Ui.Text("下一步使用手机扫码，并在支付页面核对金额后付款。", 11, "Muted"));
                }
                else
                {
                    var title = session.Paid ? "充值成功" : session.State == "verifying" ? "正在核实支付结果" : session.State == "mismatch" ? "订单需要核对" : session.State == "closed" || session.State == "failed" ? "订单未完成" : session.CanShowQr ? "使用" + (session.Channel == "wechat" ? "微信" : "支付宝") + "扫一扫" : "请查询支付结果";
                    var heading = Ui.Text(title, 17, session.Paid ? "Green" : "Ink", true); heading.HorizontalAlignment = HorizontalAlignment.Center;
                    var price = Ui.Text("¥" + session.Amount, 32, "Ink", true); price.HorizontalAlignment = HorizontalAlignment.Center;
                    panel.Children.Add(heading); panel.Children.Add(Ui.Gap(4)); panel.Children.Add(price); panel.Children.Add(Ui.Gap(12));
                    if (session.CanShowQr)
                    {
                        var bitmap = QrImage(session.CodeUrl); var modules = bitmap.PixelWidth / 8;
                        var size = modules * Math.Max(2, Math.Floor(212d / modules));
                        var qr = Ui.Id(new Image { Source = bitmap, Width = size, Height = size, Stretch = Stretch.Uniform, SnapsToDevicePixels = true }, "recharge-qr");
                        RenderOptions.SetBitmapScalingMode(qr, BitmapScalingMode.NearestNeighbor);
                        panel.Children.Add(new Border { Background = Brushes.White, Padding = new Thickness(8), CornerRadius = new CornerRadius(12), HorizontalAlignment = HorizontalAlignment.Center, Child = qr });
                        panel.Children.Add(Ui.Gap(8)); countdown = Ui.Text(Countdown(), 11, "Muted"); countdown.HorizontalAlignment = HorizontalAlignment.Center; panel.Children.Add(countdown);
                    }
                    else
                    {
                        var text = session.Paid ? balanceMessage ?? "支付已由服务端核验，正在同步账户余额…" : session.State == "mismatch" ? "支付金额或上游核验不一致。请勿重复付款，可到官网核对。" : session.State == "verifying" ? "服务端尚未确认到账，请勿重复付款。" : "支付码已隐藏。若已扫码付款，请先查询结果，避免重复充值。";
                        panel.Children.Add(Ui.Notice(text, session.State == "mismatch"));
                    }
                    panel.Children.Add(Ui.Gap(12));
                    panel.Children.Add(Ui.Text("订单号  " + session.OrderNumber, 10, "Muted")); panel.Children.Add(Ui.Gap(12));
                    if (session.Paid)
                    {
                        panel.Children.Add(balanceRefreshed ? Ui.Button("完成", "recharge-done", Close, "Primary") : Action("刷新余额", "recharge-refresh-balance", RefreshBalance, "Primary"));
                        panel.Children.Add(Ui.Gap(8)); panel.Children.Add(Action("再充一笔", "recharge-another", () => { session = app.StartAnotherRecharge(); error = balanceMessage = null; balanceRefreshed = false; Render(); return Task.CompletedTask; }));
                    }
                    else
                    {
                        panel.Children.Add(Action(busy ? "查询中…" : "我已支付 · 查询结果", "recharge-check", Check, "Primary")); panel.Children.Add(Ui.Gap(8));
                        if (session.SecondsLeft == 0 && session.State == "pending")
                        {
                            panel.Children.Add(Action("重新获取支付码", "recharge-renew", () => { amount = session.Amount; channel = session.Channel; return Create(); })); panel.Children.Add(Ui.Gap(8));
                        }
                        panel.Children.Add(Action("修改金额 / 支付方式", "recharge-edit", () => { amount = session.Amount; channel = session.Channel; editing = true; error = null; Render(); return Task.CompletedTask; }));
                        panel.Children.Add(Ui.Gap(8)); panel.Children.Add(Ui.Text("关闭窗口不会取消已创建的订单；本次运行中重新打开可继续查询。", 11, "Muted"));
                    }
                }
            }
            panel.Children.Add(Ui.Gap(10));
            panel.Children.Add(Ui.SmallButton("在官网核对账户与订单 ↗", "recharge-website", () =>
            {
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(YakCoolApi.Origin + "/workspace") { UseShellExecute = true }); }
                catch (Exception ex) { error = "无法打开官网：" + YakCoolApi.Redact(ex.Message); Render(); }
            }));
            body.Content = panel;
        }
        public static BitmapSource QrImage(string payload)
        {
            using (var generator = new QRCodeGenerator())
            using (var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M))
            using (var png = new PngByteQRCode(data))
            using (var stream = new MemoryStream(png.GetGraphic(8)))
            {
                var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad; bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze(); return bitmap;
            }
        }
    }
}
