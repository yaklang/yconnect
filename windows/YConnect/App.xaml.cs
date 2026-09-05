using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using YConnect.Core;

namespace YConnect
{
    public partial class App : Application
    {
        public AppController Controller { get; private set; }
        private Mutex instance;
        private EventWaitHandle activation;
        protected override async void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            try
            {
                var smoke = e.Args.Contains("--smoke"); var verifyLogin = e.Args.Contains("--verify-login"); var demo = smoke || e.Args.Contains("--demo"); var development = demo || verifyLogin || e.Args.Contains("--development");
                var output = e.Args.FirstOrDefault(a => a.StartsWith("--output="))?.Substring(9);
                if ((smoke || verifyLogin) && string.IsNullOrEmpty(output)) throw new InvalidOperationException("Validation requires --output=<directory>");
                var root = smoke || verifyLogin ? Path.Combine(Path.GetFullPath(output), "sandbox") : null;
                var identity = smoke || verifyLogin ? "Validation-" + Guid.NewGuid().ToString("N") : demo ? "Demo" : development ? "Dev" : "Production";
                instance = new Mutex(true, "Local\\YConnect-" + identity, out var first);
                activation = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\YConnect-Activate-" + identity);
                if (!first) { activation.Set(); Shutdown(); return; }
                var env = new EnvironmentPaths(development, demo, root);
                try { var saved = SecureFiles.ReadText(Path.Combine(env.DataRoot, "preferences.json")); env.BypassProxy = saved != null && Json.Parse(saved).Flag("BypassProxy"); } catch { }
                env.BypassProxy |= e.Args.Contains("--no-proxy");
                var store = new YConnectStore(env, demo ? (IYakCoolApi)new DemoApi() : new YakCoolApi(useSystemProxy: !env.BypassProxy)); store.Preferences.BypassProxy = env.BypassProxy;
                if (e.Args.Contains("--no-proxy")) store.SavePreferences();
                Controller = new AppController(store, activation);
                if (demo) await store.LoginAccount("demo-public-session-only", false); else await store.RestoreSession();
                Controller.PositionAll();
                if (!e.Args.Contains("--background")) Controller.ShowWidget();
                if (e.Args.Contains("--manager")) Controller.ShowManager("overview");
                if (e.Args.Contains("--login") && !store.Authenticated) await Controller.LoginAccount();
                if (smoke)
                {
                    var successful = await Validation.SmokeRunner.Run(Controller, Path.GetFullPath(output));
                    Controller.Quit(); Environment.ExitCode = successful ? 0 : 1;
                }
                else if (verifyLogin) { var successful = await Validation.LiveLoginRunner.Run(Controller, Path.GetFullPath(output)); Controller.Quit(); Environment.ExitCode = successful ? 0 : 1; }
            }
            catch (Exception error)
            {
                var file = Path.Combine(Path.GetTempPath(), "yconnect-startup-error.txt"); File.WriteAllText(file, error.ToString());
                if (!e.Args.Contains("--smoke") && !e.Args.Contains("--verify-login")) MessageBox.Show("YConnect 启动失败：" + error.Message, "YConnect", MessageBoxButton.OK, MessageBoxImage.Error); Shutdown(1);
            }
        }
        protected override void OnExit(ExitEventArgs e) { activation?.Dispose(); instance?.Dispose(); base.OnExit(e); }
    }
}
