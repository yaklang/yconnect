using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using YConnect;
using YConnect.Core;
using YConnect.Native;

internal static class Program
{
    // A real WinExe / WPF dispatcher, deliberately not the console test runner.
    private sealed class TestApp : App { protected override void OnStartup(StartupEventArgs e) { } }
    private static readonly List<string> results = new List<string>();
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    [STAThread]
    private static int Main(string[] args)
    {
        var root = Path.GetFullPath(args[0]); Directory.CreateDirectory(root);
        var fixture = Path.GetFullPath(args[1]); var runner = args.Length > 2 ? Path.GetFullPath(args[2]) : ClientLauncher.Runner;
        var app = new TestApp { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/YConnect;component/Views/Theme.xaml", UriKind.Relative) });
        app.Dispatcher.BeginInvoke(new Action(async () =>
        {
            if (args.Contains("--live-start"))
            {
                try { await LiveStart(root, runner); app.Shutdown(0); }
                catch (Exception error) { File.WriteAllText(Path.Combine(root, "result.txt"), "FAIL " + error.GetType().Name + ": " + error.Message); app.Shutdown(1); }
                return;
            }
            AppController controller = null; var ticks = 0;
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
            timer.Tick += (s, e) => ticks++; timer.Start();
            try
            {
                var environment = new EnvironmentPaths(true, true, Path.Combine(root, "sandbox"));
                var store = new YConnectStore(environment, new DemoApi()); await store.LoginAccount("demo-public-session-only", false);
                store.SelectClient("codex"); store.Preferences.AnimationsEnabled = false;
                controller = new AppController(store);
                typeof(App).GetProperty("Controller").SetValue(app, controller, null);
                controller.Manager.Navigate("clients");
                var one = Plan(root, "one 空格 & %PATH%", fixture);
                var two = Plan(root, "two", fixture);
                Func<ClientLaunchPlan, string, CancellationToken, Task<string>> launch = async (plan, terminal, cancellation) => { await Task.Delay(800, cancellation); return await ClientLauncher.Start(plan, terminal, runner, cancellation); };
                var first = controller.Launches.Start(one, "terminal", launch);
                var second = controller.Launches.Start(two, "terminal", launch);
                controller.Manager.Render(); Render(controller.Manager, Path.Combine(root, "parallel-pending.png"));
                Check(controller.Launches.Attempts.Count(a => a.State == "pending") == 2 && !store.Busy, "concurrent launches acquired global Busy");
                Check(All<Button>((DependencyObject)controller.Manager.Content).Single(b => AutomationProperties.GetAutomationId(b) == "client-launch").IsEnabled, "second launch button disabled");
                Check(All<ComboBox>((DependencyObject)controller.Manager.Content).Single(b => AutomationProperties.GetAutomationId(b) == "launch-terminal").IsEnabled, "terminal selection blocked");
                var completed = await Task.WhenAll(first, second); Check(completed.All(a => a.State == "ready"), string.Join("; ", completed.Select(a => a.Detail)));
                VerifyFixture(one); VerifyFixture(two);
                Check(ticks > 5, "WPF dispatcher stalled while opening terminals");
                results.Add("PASS two simultaneous interactive Windows Terminal sessions from WPF WinExe: console input/output, unique key/model/cwd, UI remains enabled.");

                File.WriteAllText(Path.Combine(one.Directory, "stop.txt"), "stop fixture");
                await Task.Delay(1000); Check(LaunchHandshake.IsRunning(one.Directory, "shell") == true, "shell closed when its client exited");
                StopOwned(one.Directory); await Task.Delay(200);
                Check(LaunchHandshake.IsRunning(two.Directory, "shell") == true, "closing one session affected the other"); VerifyFixture(two);
                var third = Plan(root, "three", fixture);
                Check((await controller.Launches.Start(third, "terminal", launch)).State == "ready", "relaunch after close failed"); VerifyFixture(third);
                results.Add("PASS client exit preserves its PowerShell; close one isolated session, other stays alive, open a third successfully.");

                foreach (var terminal in new[] { "powershell", "cmd" })
                {
                    var plan = Plan(root, terminal, fixture); plan.Session.Shell = terminal;
                    var attempt = await controller.Launches.Start(plan, terminal, launch); Check(attempt.State == "ready", attempt.Detail); VerifyFixture(plan); StopOwned(plan.Directory);
                }
                results.Add("PASS standalone PowerShell and CMD receive real interactive console handles, with the same independent key handoff.");
                var realPlans = new List<ClientLaunchPlan>();
                foreach (var id in new[] { "codex", "grok-build" })
                {
                    if (ClientDetection.Resolve(id) == null) { results.Add("SKIP " + id + " is not installed"); continue; }
                    var env = new EnvironmentPaths(true, true, Path.Combine(root, "installed-" + id)); Directory.CreateDirectory(env.ClientHome); env.BypassProxy = true;
                    var plan = ClientLauncher.Build(env, id, "gpt-5.4", DemoApi.Models, DemoApi.Key, env.ClientHome, "terminal", true);
                    if (id == "codex") plan.Session.Variables["CODEX_HOME"] = plan.Directory;
                    realPlans.Add(plan);
                }
                var realResults = await Task.WhenAll(realPlans.Select(plan => controller.Launches.Start(plan, "terminal", launch)));
                Check(realResults.All(a => a.State == "ready"), string.Join("; ", realResults.Select(a => a.Detail)));
                await Task.Delay(1500);
                foreach (var plan in realPlans) Check(LaunchHandshake.IsRunning(plan.Directory, "client") == true, plan.Session.Client + " interactive CLI exited early");
                results.Add("PASS installed CLI interactive startup: " + string.Join(", ", realPlans.Select(p => p.Session.Client)) + "; fixture API keys and isolated homes, no model prompt sent.");
                controller.Manager.Render(); Render(controller.Manager, Path.Combine(root, "parallel-ready.png"));
                File.WriteAllLines(Path.Combine(root, "result.txt"), results); app.Shutdown(0);
            }
            catch (Exception ex) { File.WriteAllLines(Path.Combine(root, "result.txt"), results.Concat(new[] { "FAIL " + ex })); app.Shutdown(1); }
            finally { timer.Stop(); if (controller != null) { controller.Launches.Dispose(); controller.Dispose(); } StopOwned(root); }
        }));
        return app.Run();
    }
    private static ClientLaunchPlan Plan(string root, string id, string fixture)
    {
        var directory = Path.Combine(root, id); Directory.CreateDirectory(directory);
        var session = new LaunchSession { Client = "YConnect 验证（非客户端）", Model = id, Executable = fixture, WorkingDirectory = directory, Arguments = new[] { "--interactive-fixture", directory }, AutoStart = true, CloseOnExit = false };
        session.Variables["YCONNECT_API_KEY"] = DemoApi.Key + "-" + id;
        session.Variables["YCONNECT_MODEL"] = id;
        return new ClientLaunchPlan { Directory = directory, Session = session };
    }
    private static async Task LiveStart(string output, string runner)
    {
        // Explicit local acceptance mode. Credentials stay in memory / the normal
        // DPAPI handoff; never print them, send a prompt or edit client configs.
        var environment = new EnvironmentPaths();
        var preferences = SecureFiles.ReadText(Path.Combine(environment.DataRoot, "preferences.json"));
        environment.BypassProxy = preferences != null && Json.Parse(preferences).Flag("BypassProxy");
        using (var api = new YakCoolApi(useSystemProxy: !environment.BypassProxy))
        {
            var store = new YConnectStore(environment, api); await store.RestoreSession();
            Check(store.Authenticated && store.Models.Count > 0, "saved account unavailable");
            var directory = store.Preferences.LaunchDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            var plans = new List<ClientLaunchPlan>();
            try
            {
                foreach (var id in new[] { "codex", "grok-build" })
                {
                    Check(ClientDetection.Resolve(id) != null, id + " not installed");
                    var models = store.Clients.Get(id).Compatible(store.Models).ToArray();
                    var model = models.FirstOrDefault(m => m.Id == store.Preferences.CurrentModel) ?? models.First();
                    plans.Add(ClientLauncher.Build(environment, id, model.Id, store.Models.ToArray(), store.RequireKey(), directory, "terminal", true));
                }
                await Task.WhenAll(plans.Select(plan => ClientLauncher.Start(plan, "terminal", runner)));
                await Task.Delay(2500);
                foreach (var plan in plans) Check(LaunchHandshake.IsRunning(plan.Directory, "client") == true, plan.Session.Client + " exited during initialization");
                File.WriteAllLines(Path.Combine(output, "result.txt"), plans.Select(plan => "STARTED " + plan.Session.Client + " | " + plan.Session.Model + " | " + plan.Session.WorkingDirectory).Concat(new[] { "Saved account; no model prompt submitted. Both real interactive clients left open for user acceptance. This verifies process startup, not a successful model response." }));
            }
            catch { foreach (var plan in plans.Where(p => Directory.Exists(p.Directory))) StopOwned(plan.Directory); throw; }
        }
    }
    private static void VerifyFixture(ClientLaunchPlan plan)
    {
        var result = Json.Parse(File.ReadAllText(Path.Combine(plan.Directory, "fixture.json")));
        Check(result.Flag("keyMatched") && result.Flag("inputConsole") && result.Flag("outputConsole") && result.Text("cwd") == plan.Directory && result.Text("model") == plan.Session.Model, "interactive fixture lost key, model, cwd or console");
        using (var process = Process.GetProcessById((int)result.Number("pid"))) Check(!process.HasExited, "interactive fixture was only a short-lived command");
    }
    private static void StopOwned(string root)
    {
        // Read only our receipts; PID + creation time protects against PID reuse.
        foreach (var file in Directory.GetFiles(root, "*-process.json", SearchOption.AllDirectories).OrderBy(f => Path.GetFileName(f).StartsWith("bootstrap") ? 3 : Path.GetFileName(f).StartsWith("shell") ? 2 : Path.GetFileName(f).StartsWith("client-helper") ? 1 : 0))
        {
            var stamp = Json.Parse(File.ReadAllText(file));
            try
            {
                using (var process = Process.GetProcessById((int)stamp.Number("Id")))
                    if (!process.HasExited && process.StartTime.ToUniversalTime().Ticks == (long)stamp["Started"])
                    {
                        if (Path.GetFileName(file).StartsWith("bootstrap") && process.WaitForExit(3000)) continue;
                        try { process.Kill(); } catch (System.ComponentModel.Win32Exception) { if (!process.WaitForExit(500)) throw; }
                    }
            }
            catch (ArgumentException) { } catch (InvalidOperationException) { }
        }
        using (var query = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'YConnect.Launcher.exe' OR Name = 'YConnect.Tests.exe'"))
            foreach (ManagementObject process in query.Get())
                if (((string)process["CommandLine"] ?? "").IndexOf(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) >= 0)
                    try { using (var child = Process.GetProcessById(Convert.ToInt32(process["ProcessId"]))) { if (!child.HasExited) try { child.Kill(); } catch (System.ComponentModel.Win32Exception) { if (!child.WaitForExit(500)) throw; } } } catch (ArgumentException) { } catch (InvalidOperationException) { }
    }
    private static IEnumerable<T> All<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T item) yield return item;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in All<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    private static void Render(Window window, string path)
    {
        var content = (FrameworkElement)window.Content; content.Measure(new Size(1080, 820)); content.Arrange(new Rect(0, 0, 1080, 820)); content.UpdateLayout();
        var bitmap = new RenderTargetBitmap(1080, 820, 96, 96, PixelFormats.Pbgra32); bitmap.Render(content);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using (var file = File.Create(path)) encoder.Save(file);
    }
}
