using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Newtonsoft.Json.Linq;
using YConnect.Core;
using YConnect.Views;

namespace YConnect.Validation
{
    // Runs inside the application's own WPF dispatcher with isolated demo data.
    // It invokes real native control peers/handlers, then captures that visual
    // tree and its own window's native screen composition over a test backdrop.
    public static class SmokeRunner
    {
        private static readonly List<string> steps = new List<string>();
        private static string directory;
        private static AppController app;
        private static void Assert(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        public static async Task<bool> Run(AppController controller, string output)
        {
            directory = output; app = controller; Directory.CreateDirectory(output);
            try
            {
                app.Store.Preferences.Pinned = true; app.Store.SavePreferences(); app.ShowWidget(); await Idle(); Capture(app.Widget, "01-widget-account.png"); Capture(app.Edge, "02-right-edge.png");
                await NativeCapture.Save(app.Widget, Path.Combine(output, "20-widget-light-native.png"));
                Assert(app.Edge.IsVisible && app.Edge.Topmost, "edge should be visible and topmost");
                await VerifyDesktopUx();
                app.ShowManager("overview"); await Idle(); Capture(app.Manager, "03-manager-overview.png");
                await Click(app.Manager, "nav-models"); Find<TextBox>(app.Manager, "model-search").Text = "Claude"; await Idle();
                Assert(All<TextBlock>(app.Manager).Any(t => t.Text.Contains("Claude Sonnet")), "model search did not return Claude"); Capture(app.Manager, "04-model-search.png");
                await Click(app.Manager, "model-filter-responses"); await Idle(); Assert(All<TextBlock>(app.Manager).Any(t => t.Text.Contains("没有匹配")), "incompatible filter should show empty state");
                await Click(app.Manager, "nav-clients"); await Click(app.Manager, "client-select-codex"); await Idle();
                var model = Find<ComboBox>(app.Manager, "client-model"); Assert(model.Items.Cast<AvailableModel>().All(m => m.Protocols.Contains("responses")), "Codex picker included incompatible model");
                Capture(app.Manager, "05-clients-codex.png");
                app.DialogOpenedForValidation = dialog => dialog.Dispatcher.BeginInvoke(new Action(() => { Capture(dialog, "06-configuration-preview.png"); Invoke(Find<Button>(dialog, "dialog-confirm")); }), DispatcherPriority.Background);
                await Click(app.Manager, "client-preview"); await Idle(); Assert(app.Store.Clients.Inspect("codex").State == "configured", "UI configuration apply failed: " + app.Store.Error);
                steps.Add("Applied Codex config using the native preview dialog and confirmation button."); Capture(app.Manager, "07-clients-applied.png");
                app.DialogOpenedForValidation = dialog => dialog.Dispatcher.BeginInvoke(new Action(() => Invoke(Find<Button>(dialog, "dialog-confirm"))), DispatcherPriority.Background);
                await Click(app.Manager, "client-restore"); await Idle(); Assert(!File.Exists(app.Store.Clients.Paths("codex")[0]), "UI restore did not remove newly-created config"); steps.Add("Restored the pre-apply state through the native restore confirmation.");
                foreach (var client in ClientRegistry.All.Where(c => !c.Bridge && c.Id != "codex"))
                {
                    await Click(app.Manager, "client-select-" + client.Id); Capture(app.Manager, "client-" + client.Id + ".png");
                    await Click(app.Manager, "client-preview"); Assert(app.Store.Clients.Inspect(client.Id).State == "configured", "UI apply failed for " + client.Id + ": " + app.Store.Error);
                    await Click(app.Manager, "client-restore"); Assert(app.Store.Clients.Inspect(client.Id).State == "notConfigured", "UI restore failed for " + client.Id);
                }
                steps.Add("Applied and restored all 8 adapters through actual WPF controls and confirmation dialogs.");
                await Click(app.Manager, "nav-keys"); Capture(app.Manager, "08-key-management.png");
                app.DialogOpenedForValidation = dialog => dialog.Dispatcher.BeginInvoke(new Action(() => { Find<TextBox>(dialog, "new-key-label").Text = "WPF 自动验证"; Invoke(Find<Button>(dialog, "dialog-confirm")); }), DispatcherPriority.Background);
                await Click(app.Manager, "keys-create"); await Idle(); Assert(app.Store.Keys.Count == 3, "UI key creation failed"); var created = app.Store.Preferences.SelectedKey.Value;
                app.DialogOpenedForValidation = dialog => dialog.Dispatcher.BeginInvoke(new Action(() => Invoke(Find<Button>(dialog, "dialog-confirm"))), DispatcherPriority.Background);
                await Click(app.Manager, "key-delete-" + created); await Idle(); Assert(app.Store.Keys.Count == 2, "UI key deletion failed");
                Find<TextBox>(app.Manager, "redeem-code").Text = "DEMO-REDEEM-1234"; await Click(app.Manager, "redeem-submit"); Assert(Math.Abs(app.Store.Remaining.Value - 138.6) < .01, "UI redemption failed");
                await Click(app.Manager, "nav-checks"); await Click(app.Manager, "checks-start"); await Idle(); Assert(app.Store.Checks.All(c => c.State == "passed"), "UI checks failed"); Capture(app.Manager, "09-connection-checks.png");
                await Click(app.Manager, "probe-submit"); await Idle(); Assert(app.Store.Message.Contains("OK"), "confirmed demo probe failed");
                await Click(app.Manager, "nav-settings"); Capture(app.Manager, "10-settings.png");
                await Click(app.Manager, "setting-side-left"); Assert(app.Store.Preferences.OnLeft, "left edge setting failed"); Capture(app.Edge, "11-left-edge.png");
                await Click(app.Manager, "setting-side-right"); Assert(!app.Store.Preferences.OnLeft, "right edge setting failed");
                await Click(app.Manager, "setting-theme-dark"); app.ShowWidget(); await Idle(); Capture(app.Widget, "12-widget-dark.png"); Capture(app.Manager, "13-settings-dark.png");
                await NativeCapture.Save(app.Widget, Path.Combine(output, "21-widget-dark-native.png"), true);
                await Click(app.Manager, "setting-theme-light"); app.ShowManager("settings"); await Idle(); await Click(app.Manager, "setting-signout"); await Idle(); Assert(!app.Store.Authenticated, "UI sign-out failed");
                app.ShowWidget(); await Idle(); Capture(app.Widget, "14-widget-signed-out.png");
                await Click(app.Widget, "login-tab-key"); Capture(app.Widget, "15-widget-key-login.png");
                Find<PasswordBox>(app.Widget, "login-key-input").Password = "invalid key"; await Click(app.Widget, "login-key-connect"); await Idle(); Assert(!app.Store.Authenticated && !string.IsNullOrEmpty(app.Store.Error), "invalid key should remain signed out"); Capture(app.Widget, "16-validation-error.png");
                var originalClipboard = Clipboard.GetDataObject();
                try
                {
                    app.CopyText(DemoApi.Key, "validation-paste"); await Idle(); await Click(app.Widget, "login-key-paste");
                    Assert(Find<PasswordBox>(app.Widget, "login-key-input").Password == DemoApi.Key, "explicit key paste failed");
                    await Click(app.Widget, "login-key-connect"); await Idle();
                }
                finally { if (originalClipboard != null) Clipboard.SetDataObject(originalClipboard, true); else Clipboard.Clear(); }
                Assert(app.Store.Mode == "apiKey", "UI API-key login failed"); Capture(app.Widget, "17-widget-api-key.png");
                app.ShowManager("keys"); await Idle(); Assert(FindOptional<Button>(app.Manager, "keys-create") == null, "account actions leaked into API-key mode");
                app.Widget.Hide(); await Idle(); await VerifyPeek("33-peek-shared-key.png", "约 80%"); app.ShowWidget(); await Idle();
                // Native focus/blur behavior uses real WPF activation events.
                app.Store.Preferences.Pinned = false; app.Store.SavePreferences(); app.ShowWidget(); await Idle(); app.Manager.Activate(); await Idle(); Assert(!app.Widget.IsVisible, "unpinned widget did not hide on blur");
                app.Store.Preferences.Pinned = true; app.Store.SavePreferences(); app.ShowWidget(); await Idle(); app.Manager.Activate(); await Idle(); Assert(app.Widget.IsVisible, "pinned widget should survive blur"); steps.Add("Verified native activation/deactivation: transient hides, pinned remains visible.");
                await app.Store.Run(() => app.Store.LoginAccount("demo-public-session-only", false)); app.ShowWidget(); app.ShowManager("overview"); await Idle(); Capture(app.Widget, "18-widget-final.png"); Capture(app.Manager, "19-manager-final.png");
                await NativeCapture.Save(app.Manager, Path.Combine(output, "22-manager-native.png"));
                using (var process = Process.GetCurrentProcess())
                {
                    process.Refresh(); File.WriteAllText(Path.Combine(output, "runtime-metrics.json"), new JObject { ["workingSetBytes"] = process.WorkingSet64, ["privateBytes"] = process.PrivateMemorySize64, ["processCount"] = 1, ["edgeVisible"] = app.Edge.IsVisible, ["edgeTopmost"] = app.Edge.Topmost, ["widgetWidth"] = app.Widget.ActualWidth, ["widgetHeight"] = app.Widget.ActualHeight, ["screen"] = app.ActiveScreen.DeviceName, ["screenWorkingArea"] = app.ActiveScreen.WorkingArea.ToString(), ["framework"] = ".NET Framework 4.8 / WPF", ["demo"] = true }.ToString());
                }
                steps.Add("PASS: all native WPF interaction checks completed."); File.WriteAllLines(Path.Combine(output, "ui-results.txt"), steps); return true;
            }
            catch (Exception e) { File.WriteAllText(Path.Combine(output, "ui-results.txt"), string.Join("\n", steps) + "\nFAIL: " + e); try { Capture(app.Manager, "failure-manager.png"); Capture(app.Widget, "failure-widget.png"); } catch { } return false; }
            finally { app.DialogOpenedForValidation = null; }
        }
        private static async Task VerifyDesktopUx()
        {
            await VerifyFocusLayout();
            app.ShowManager("overview"); await Idle();
            await Click(app.Manager, "sidebar-toggle"); Assert(app.Manager.SidebarCollapsed, "sidebar did not collapse");
            Assert(Find<Button>(app.Manager, "sidebar-account").IsVisible, "collapsed account footer disappeared"); Capture(app.Manager, "23-manager-collapsed.png");
            await Click(app.Manager, "sidebar-toggle");
            var managerBounds = YConnect.Native.WindowsDesktop.Bounds(app.Manager);
            var heading = Find<TextBlock>(app.Manager, "manager-page-title");
            await NativeInput.Drag(app.Manager, heading, 34, 22);
            var managerAfter = YConnect.Native.WindowsDesktop.Bounds(app.Manager);
            steps.Add("Manager native drag bounds: " + managerBounds + " -> " + managerAfter);
            Assert(Math.Abs(managerAfter.Left - managerBounds.Left - 34) <= 8 && Math.Abs(managerAfter.Top - managerBounds.Top - 22) <= 8, "manager background did not smoothly follow native drag (including system drag threshold)");
            steps.Add("Native OS pointer dragged manager heading; buttons/inputs remain excluded.");
            YConnect.Native.WindowsDesktop.Move(app.Manager, managerBounds.Left, managerBounds.Top);
            app.ShowWidget(); await Idle();
            var oldPercent = app.Store.Preferences.YPercent;
            await NativeInput.Drag(app.Widget, Find<TextBlock>(app.Widget, "widget-balance-value"), -24, -72);
            Assert(!app.Widget.IsDragging && app.Store.Preferences.YPercent < oldPercent - 1, "widget card drag/snap did not commit");
            steps.Add("Native OS pointer dragged widget balance card; release smoothly docked and saved position.");
            app.Store.Preferences.YPercent = 58; app.PositionAll(); await Idle();
            var clipboard = Clipboard.GetDataObject();
            try
            {
                var height = app.Widget.ActualHeight;
                await Click(app.Widget, "widget-copy-key"); Assert(Clipboard.GetText() == app.Store.CurrentKey, "copy key was not just current key");
                Assert(Math.Abs(height - app.Widget.ActualHeight) <= 2, "copy feedback moved widget layout");
                await Click(app.Widget, "widget-model-gpt-5.4"); Assert(Clipboard.GetText() == "gpt-5.4", "model copy exposed access info instead of model ID");
                await Click(app.Widget, "widget-copy-access"); var access = Clipboard.GetText();
                Assert(access.Contains("YConnect") && access.Contains("gpt-5.4") && access.Contains(app.Store.CurrentKey) && AppController.Endpoints.All(e => access.Contains(e.Url)), "access copy missing source/model/key/endpoints");
                await Click(app.Widget, "widget-protocols"); Assert(app.Widget.ExpandedSection == "protocols", "protocol expansion");
                Capture(app.Widget, "24-widget-protocols.png");
                foreach (var endpoint in AppController.Endpoints) { await Click(app.Widget, "endpoint-" + endpoint.Id); Assert(Clipboard.GetText() == endpoint.Url, "endpoint copy included sensitive data"); }
                await Click(app.Widget, "widget-models"); Assert(app.Widget.ExpandedSection == "models" && FindOptional<Button>(app.Widget, "endpoint-responses") == null, "protocol/model expansions not mutually exclusive");
                var search = Find<TextBox>(app.Widget, "widget-model-search"); search.Text = "claude"; await Idle();
                Assert(FindOptional<Button>(app.Widget, "widget-model-gpt-5.4") == null && FindOptional<Button>(app.Widget, "widget-model-claude-sonnet-4-6") != null, "widget model filter failed"); Capture(app.Widget, "25-widget-model-search.png");
                search.Text = ""; await Click(app.Widget, "widget-models");
                steps.Add("Copied key, model ID, 5 individual URLs and full access info; verified inline feedback and mutually exclusive disclosures.");
            }
            finally { if (clipboard != null) Clipboard.SetDataObject(clipboard, true); else Clipboard.Clear(); }
            var defaultNameChecked = false;
            app.DialogOpenedForValidation = dialog => dialog.Dispatcher.BeginInvoke(new Action(() =>
            {
                var input = Find<TextBox>(dialog, "new-key-label");
                Assert(input.Text == app.Store.SuggestedKeyName() && input.IsKeyboardFocused && input.SelectionLength == input.Text.Length, "new-key suggestion was not focused and selected");
                defaultNameChecked = true; Capture(dialog, "26-new-key-focused.png"); dialog.DialogResult = false;
            }), DispatcherPriority.Background);
            await Click(app.Widget, "widget-new-key"); Assert(defaultNameChecked && app.Manager.Section == "keys", "widget new key did not open manager key page");
            app.DialogOpenedForValidation = null;
            var ids = ClientRegistry.All.Where(c => !c.Bridge).Select(c => c.Id).ToArray();
            foreach (var count in new[] { 0, 1, 3, 4, 5 })
            {
                app.Store.Environment.SetPreviewClients(ids.Take(count).ToArray()); app.ShowWidget(); app.ShowManager("clients"); await Idle();
                var visible = All<Button>(app.Widget).Count(b => AutomationProperties.GetAutomationId(b).StartsWith("widget-client-"));
                Assert(visible == (count > 4 ? 3 : count), "widget installed count " + count);
                Assert((FindOptional<Button>(app.Widget, "widget-more-clients") != null) == (count > 4), "More threshold");
                Assert(All<Button>(app.Manager).Count(b => AutomationProperties.GetAutomationId(b).StartsWith("client-select-")) == count, "manager leaked uninstalled client");
                Capture(app.Widget, "installed-" + count + "-widget.png");
                if (count == 0) Capture(app.Manager, "27-no-installed-clients.png");
            }
            app.Store.Environment.SetPreviewClients(ids); app.ShowManager("overview");
            app.Widget.Hide(); await Idle();
            await VerifyPeek("28-peek-balance.png", "¥128.60");
            app.Store.Preferences.PeekPercentageOnly = true; app.Edge.CloseQuick();
            await VerifyPeek("29-peek-percentage.png", "约 86%");
            app.Store.Preferences.PeekPercentageOnly = false;
            Ui.SetTheme("dark"); app.Store.Preferences.Theme = "dark"; app.Edge.Refresh(); app.Edge.CloseQuick();
            await VerifyPeek("30-peek-dark.png", "¥128.60", true);
            Ui.SetTheme("light"); app.Store.Preferences.Theme = "light";
            app.Store.Preferences.BalancePeekEnabled = false;
            var edge = YConnect.Native.WindowsDesktop.Bounds(app.Edge); var point = new System.Drawing.Point(edge.Left + 4, edge.Top + 30);
            app.Edge.SampleProximity(point, DateTime.UtcNow); app.Edge.SampleProximity(point, DateTime.UtcNow.AddSeconds(1)); Assert(!app.Edge.Peek.IsVisible, "disabled peek appeared"); app.Store.Preferences.BalancePeekEnabled = true;
            app.Store.Preferences.AnimationsEnabled = false; app.ShowWidget(); app.Widget.Hide(); Assert(!app.Widget.IsVisible, "reduce-motion hide was delayed");
            app.ShowWidget(); app.Store.Preferences.AnimationsEnabled = true; app.Widget.Hide(); app.ShowWidget(); await Idle(); Assert(app.Widget.IsVisible, "reopen lost to stale closing animation");
            steps.Add("Verified proximity dwell/leave, balance/privacy themes, no foreground activation, disabled peek and reduced-motion/reopen behavior.");
            foreach (var scale in new[] { 1d, 1.25, 1.5 })
            {
                Capture(app.Widget, "dpi-render-widget-" + (scale * 100).ToString("0") + ".png", scale);
                Capture(app.Manager, "dpi-render-manager-" + (scale * 100).ToString("0") + ".png", scale);
            }
            var oldWidth = app.Manager.Width; var oldHeight = app.Manager.Height;
            app.Manager.Width = 850; app.Manager.Height = 640; await Idle(); Capture(app.Manager, "31-manager-small.png");
            var footer = Find<Button>(app.Manager, "sidebar-account"); var footerBottom = footer.TranslatePoint(new Point(0, footer.ActualHeight), app.Manager);
            Assert(footerBottom.Y < app.Manager.ActualHeight, "account footer clipped at minimum height");
            app.Manager.Width = oldWidth; app.Manager.Height = oldHeight;
            await Click(app.Widget, "widget-protocols"); app.Widget.IsDragging = true; app.Widget.SetMaximumHeight(650); await Idle(); Assert(app.Widget.ActualHeight <= 650, "widget did not constrain small working area");
            Capture(app.Widget, "32-widget-short-working-area.png"); app.Widget.IsDragging = false; await Click(app.Widget, "widget-protocols"); app.PositionAll();
            steps.Add("Captured native WPF render targets at 100/125/150 percent, minimum manager layout, and short widget working area. OS display DPI was not changed.");
        }
        private static System.Windows.Rect[] NavigationBounds()
        {
            return new[] { "overview", "keys", "clients", "models", "checks", "settings" }.Select(id =>
            {
                var button = Find<Button>(app.Manager, "nav-" + id);
                return new System.Windows.Rect(button.TranslatePoint(new Point(0, 0), app.Manager), new Size(button.ActualWidth, button.ActualHeight));
            }).ToArray();
        }
        private static void SameBounds(System.Windows.Rect[] before, System.Windows.Rect[] after, string context)
        {
            Assert(before.Length == after.Length && before.Zip(after, (a, b) => Math.Abs(a.X - b.X) < .1 && Math.Abs(a.Y - b.Y) < .1 && Math.Abs(a.Width - b.Width) < .1 && Math.Abs(a.Height - b.Height) < .1).All(value => value), context + " changed layout");
        }
        private static async Task VerifyFocusLayout()
        {
            app.Store.Preferences.AnimationsEnabled = false; app.ShowManager("overview"); await Idle();
            foreach (var collapsed in new[] { false, true })
            {
                if (app.Manager.SidebarCollapsed != collapsed) await Click(app.Manager, "sidebar-toggle");
                var before = NavigationBounds();
                foreach (var id in new[] { "overview", "keys", "clients", "models", "checks", "settings" })
                {
                    Find<Button>(app.Manager, "nav-" + id).Focus(); await Idle(); SameBounds(before, NavigationBounds(), "Sidebar keyboard focus");
                    await Click(app.Manager, "nav-" + id); SameBounds(before, NavigationBounds(), "Sidebar selection");
                }
                Capture(app.Manager, collapsed ? "35-sidebar-collapsed-focus.png" : "34-sidebar-focus.png");
            }
            await Click(app.Manager, "sidebar-toggle"); app.ShowWidget(); await Idle();
            Func<System.Windows.Rect[]> header = () => new[] { "widget-refresh", "widget-pin", "widget-close", "widget-copy-key" }.Select(id =>
            {
                var button = Find<Button>(app.Widget, id); return new System.Windows.Rect(button.TranslatePoint(new Point(0, 0), app.Widget), new Size(button.ActualWidth, button.ActualHeight));
            }).ToArray();
            var original = header(); var height = app.Widget.ActualHeight;
            foreach (var id in new[] { "widget-refresh", "widget-pin", "widget-close", "widget-copy-key" })
            {
                Find<Button>(app.Widget, id).Focus(); await Idle(); SameBounds(original, header(), "Widget focus ring");
                Assert(Math.Abs(height - app.Widget.ActualHeight) < .1, "widget focus changed total height");
            }
            app.Store.Preferences.AnimationsEnabled = true; app.ShowManager("overview"); await Idle();
            steps.Add("Focus regression: all 6 navigation items retain identical bounds when focused/selected in expanded and collapsed rails; widget controls and total height also remain unchanged.");
        }
        private static async Task VerifyPeek(string name, string expected, bool dark = false)
        {
            app.Manager.Activate(); var foreground = YConnect.Native.WindowsDesktop.GetForegroundWindow();
            var original = System.Windows.Forms.Cursor.Position; var edge = YConnect.Native.WindowsDesktop.Bounds(app.Edge);
            var near = new System.Drawing.Point(edge.Left - 40, edge.Top + edge.Height / 2);
            var far = new System.Drawing.Point(edge.Left - 500, edge.Top);
            try
            {
                System.Windows.Forms.Cursor.Position = near; await Task.Delay(750);
                Assert(app.Edge.Peek.IsVisible && !app.Widget.IsVisible, "proximity failed to reveal only compact balance");
                Assert(Find<TextBlock>(app.Edge.Peek, "peek-balance-value").Text == expected, "peek displayed wrong account/key value");
                Assert(foreground == YConnect.Native.WindowsDesktop.GetForegroundWindow(), "peek stole foreground focus");
                Capture(app.Edge.Peek, name); await NativeCapture.Save(app.Edge.Peek, Path.Combine(directory, "native-" + name), dark, false);
                System.Windows.Forms.Cursor.Position = far; await Task.Delay(750); Assert(!app.Edge.Peek.IsVisible, "peek did not dismiss after leave");
                if (name == "28-peek-balance.png")
                {
                    System.Windows.Forms.Cursor.Position = near; await Task.Delay(750);
                    await NativeInput.Click(app.Edge.Peek, Find<Button>(app.Edge.Peek, "peek-open-widget")); await Idle();
                    Assert(app.Widget.IsVisible && !app.Edge.Peek.IsVisible, "native peek click did not open widget");
                    app.Widget.Hide(); app.Manager.Activate(); await Idle(); System.Windows.Forms.Cursor.Position = far;
                    steps.Add("Native OS pointer clicked non-activating balance peek and opened the full widget.");
                }
            }
            finally { var current = System.Windows.Forms.Cursor.Position; if (current == near || current == far) System.Windows.Forms.Cursor.Position = original; app.Edge.CloseQuick(); }
        }
        private static async Task Idle()
        {
            var timeout = Stopwatch.StartNew();
            do { await Task.Delay(90); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); if (timeout.Elapsed > TimeSpan.FromSeconds(25)) throw new TimeoutException("WPF action did not settle"); } while (app.Store.Busy);
            await Task.Delay(260);
        }
        private static async Task Click(DependencyObject root, string id)
        {
            var button = Find<Button>(root, id); Assert(button.IsEnabled, "Button disabled: " + id); button.BringIntoView(); await Task.Delay(80); Invoke(button); await Idle(); steps.Add("Clicked " + id); File.WriteAllLines(Path.Combine(directory, "ui-results.txt"), steps);
        }
        private static void Invoke(Button button)
        {
            var peer = new ButtonAutomationPeer(button); var pattern = (IInvokeProvider)peer.GetPattern(PatternInterface.Invoke); pattern.Invoke();
        }
        private static IEnumerable<T> All<T>(DependencyObject root) where T : DependencyObject
        {
            if (root is T item) yield return item;
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in All<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
        }
        private static T FindOptional<T>(DependencyObject root, string id) where T : DependencyObject => All<T>(root).FirstOrDefault(e => AutomationProperties.GetAutomationId(e) == id);
        private static T Find<T>(DependencyObject root, string id) where T : DependencyObject => FindOptional<T>(root, id) ?? throw new InvalidOperationException("Missing native control: " + id);
        public static void Capture(Window window, string name, double scale = 1)
        {
            window.UpdateLayout();
            var width = (int)Math.Ceiling(window.ActualWidth * scale); var height = (int)Math.Ceiling(window.ActualHeight * scale);
            if (width < 1 || height < 1) throw new InvalidOperationException("Window has no renderable layout");
            var image = new RenderTargetBitmap(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32); image.Render(window);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image)); using (var file = File.Create(Path.Combine(directory, name))) encoder.Save(file);
            if (scale == 1 && new[] { "01-widget-account.png", "02-right-edge.png", "03-manager-overview.png", "05-clients-codex.png", "08-key-management.png", "09-connection-checks.png", "10-settings.png", "14-widget-signed-out.png", "15-widget-key-login.png", "24-widget-protocols.png" }.Contains(name))
                foreach (var factor in new[] { 1.25, 1.5 }) Capture(window, Path.GetFileNameWithoutExtension(name) + "-render-" + (factor * 100).ToString("0") + ".png", factor);
        }
    }
}
