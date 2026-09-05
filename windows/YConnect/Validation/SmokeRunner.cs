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
                Find<PasswordBox>(app.Widget, "login-key-input").Password = DemoApi.Key; await Click(app.Widget, "login-key-connect"); await Idle(); Assert(app.Store.Mode == "apiKey", "UI API-key login failed"); Capture(app.Widget, "17-widget-api-key.png");
                app.ShowManager("keys"); await Idle(); Assert(FindOptional<Button>(app.Manager, "keys-create") == null, "account actions leaked into API-key mode");
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
        private static async Task Idle()
        {
            var timeout = Stopwatch.StartNew();
            do { await Task.Delay(90); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle); if (timeout.Elapsed > TimeSpan.FromSeconds(25)) throw new TimeoutException("WPF action did not settle"); } while (app.Store.Busy);
        }
        private static async Task Click(DependencyObject root, string id)
        {
            var button = Find<Button>(root, id); Assert(button.IsEnabled, "Button disabled: " + id); Invoke(button); await Idle(); steps.Add("Clicked " + id);
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
        public static void Capture(Window window, string name)
        {
            window.UpdateLayout();
            var width = (int)Math.Ceiling(window.ActualWidth); var height = (int)Math.Ceiling(window.ActualHeight);
            if (width < 1 || height < 1) throw new InvalidOperationException("Window has no renderable layout");
            var image = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); image.Render(window);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image)); using (var file = File.Create(Path.Combine(directory, name))) encoder.Save(file);
        }
    }
}
