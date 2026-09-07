using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using YConnect;
using YConnect.Core;
using YConnect.Native;
using YConnect.Views;

internal static class Program
{
    private static int passed, failed;
    private static string root;
    private static readonly List<string> results = new List<string>();
    private static void Assert(bool value, string message) { if (!value) throw new Exception(message); }
    private static void Throws(Action action) { try { action(); } catch { return; } throw new Exception("Expected rejection"); }
    private static async Task ThrowsAsync(Func<Task> action) { try { await action(); } catch { return; } throw new Exception("Expected async rejection"); }
    private static void Test(string title, Action operation)
    {
        try { operation(); passed++; results.Add("PASS " + title); Console.WriteLine("PASS " + title); } catch (Exception e) { failed++; results.Add("FAIL " + title + ": " + e); Console.WriteLine("FAIL " + title + ": " + e.Message); }
    }
    private static async Task TestAsync(string title, Func<Task> operation)
    {
        try { await operation(); passed++; results.Add("PASS " + title); Console.WriteLine("PASS " + title); } catch (Exception e) { failed++; results.Add("FAIL " + title + ": " + e); Console.WriteLine("FAIL " + title + ": " + e.Message); }
    }
    private static EnvironmentPaths Env(string name) => new EnvironmentPaths(true, true, Path.Combine(root, name));
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.FirstOrDefault() == "--interactive-fixture") return LauncherChecks.InteractiveFixture(args[1]);
        if (args.FirstOrDefault() == "--launch-fixture")
        {
            File.WriteAllText(args[1], new JObject { ["keyMatched"] = Environment.GetEnvironmentVariable("YCONNECT_API_KEY") == DemoApi.Key, ["cwd"] = Environment.CurrentDirectory, ["arguments"] = new JArray(args.Skip(2)), ["baseUrl"] = Environment.GetEnvironmentVariable("YCONNECT_BASE_URL") }.ToString()); return 0;
        }
        if (args.FirstOrDefault() == "--verify-connection") return VerifyLiveConnection().GetAwaiter().GetResult();
        if (args.FirstOrDefault() == "--launch-fail-fixture") return 17;
        if (args.FirstOrDefault() == "--verify-terminal-clients") return LauncherChecks.RealTerminalClients(Path.GetFullPath(args[1]), args.Length > 2 ? Path.GetFullPath(args[2]) : ClientLauncher.Runner).GetAwaiter().GetResult();
        if (args.FirstOrDefault() == "--verify-launchers") return VerifyInstalledLaunchers();
        root = Path.GetFullPath(args.FirstOrDefault() ?? Path.Combine(Path.GetTempPath(), "YConnectTests-" + Guid.NewGuid().ToString("N"))); Directory.CreateDirectory(root);
        Test("Headless WPF layout, capability parity and responsive snapshots", () => LayoutChecks.Run(Path.Combine(root, "layout")));
        Run().GetAwaiter().GetResult(); File.WriteAllLines(Path.Combine(root, "results.txt"), results.Concat(new[] { passed + " passed, " + failed + " failed" })); Console.WriteLine(passed + " passed, " + failed + " failed"); return failed == 0 ? 0 : 1;
    }
    private static async Task Run()
    {
        Test("Launcher plans preserve existing configurations and isolate each key", () =>
        {
            var env = Env("launcher 空格 & ' %"); Directory.CreateDirectory(env.ClientHome);
            var registry = new ClientRegistry(env);
            foreach (var client in ClientRegistry.All.Where(c => ClientLauncher.Supported(c.Id)))
            {
                var files = registry.Paths(client.Id); foreach (var file in files) SecureFiles.WriteText(file, "original configuration — do not change");
                var model = client.Compatible(DemoApi.Models).First().Id;
                var plan = ClientLauncher.Build(env, client.Id, model, DemoApi.Models, DemoApi.Key, env.ClientHome, "powershell", ClientLauncher.CanAutoStart(client.Id));
                Assert(files.All(f => File.ReadAllText(f) == "original configuration — do not change"), "launcher modified global config");
                Assert(!Directory.Exists(plan.Directory), "preview plan wrote session files");
                Assert(!string.Join(" ", plan.Session.Arguments).Contains(DemoApi.Key) && plan.Files.Values.All(v => !v.Contains(DemoApi.Key)), "key leaked into command/config");
                var bytes = plan.Session.Protect(); Assert(!Encoding.UTF8.GetString(bytes).Contains(DemoApi.Key) && LaunchSession.Unprotect(bytes).Variables["YCONNECT_API_KEY"] == DemoApi.Key, "encrypted handoff failed");
                var second = ClientLauncher.Build(env, client.Id, model, DemoApi.Models, "another-fixture-key", env.ClientHome, "cmd", false);
                Assert(plan.Directory != second.Directory && plan.Session.Variables["YCONNECT_API_KEY"] == DemoApi.Key, "second session overwrote first");
            }
        });
        Test("Real CMD and PowerShell bootstrap receive key, cwd and quoted arguments", () =>
        {
            foreach (var shell in new[] { "cmd", "powershell" })
            {
                var env = Env("launch-shell-" + shell + " 空格 & ' %"); SecureFiles.ProtectDirectory(env.DataRoot);
                var evidence = Path.Combine(env.DataRoot, "child.json"); var manifest = Path.Combine(env.DataRoot, "session.bin");
                var arguments = new[] { "--launch-fixture", evidence, "model.with/slashes:tag", "a string with spaces", "quote\"inside", "C:\\trailing\\", "semi;dollar$()&percent%literal" };
                var session = new LaunchSession { Client = "Fixture", Model = "fixture", Executable = typeof(Program).Assembly.Location, WorkingDirectory = env.DataRoot, Arguments = arguments, Shell = shell, AutoStart = true, CloseOnExit = true };
                session.Variables["YCONNECT_API_KEY"] = DemoApi.Key; session.Variables["YCONNECT_BASE_URL"] = YakCoolApi.Gateway + "/v1";
                SecureFiles.AtomicWrite(manifest, session.Protect(), true);
                using (var child = Process.Start(new ProcessStartInfo(ClientLauncher.Runner, LaunchSession.Quote(manifest)) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
                { if (!child.WaitForExit(15000)) { child.Kill(); throw new Exception("launcher timed out: " + shell); } Assert(child.ExitCode == 0, "launcher failed: " + shell + " " + child.StandardError.ReadToEnd()); }
                var result = Json.Parse(File.ReadAllText(evidence)); Assert(result.Flag("keyMatched") && result.Text("cwd") == env.DataRoot && result.Array("arguments").Values<string>().SequenceEqual(arguments.Skip(2)), "shell lost key, cwd or arguments: " + shell);
                Assert(!File.Exists(manifest) && File.ReadAllText(Path.Combine(env.DataRoot, "started.txt")) == "ready", "handoff was not consumed/acknowledged");
            }
        });
        Test("npm CMD shims preserve literal percent, ampersand and working paths", () =>
        {
            var env = Env("npm-shim & %PATH% ' 空格"); Directory.CreateDirectory(env.DataRoot);
            var shim = Path.Combine(env.DataRoot, "fixture.cmd"); var output = Path.Combine(env.DataRoot, "result.json");
            File.WriteAllText(shim, "@echo off\r\n\"%YCONNECT_FIXTURE_EXE%\" %*\r\n", new UTF8Encoding(false));
            var session = new LaunchSession { Executable = shim, WorkingDirectory = env.DataRoot, Arguments = new[] { "--launch-fixture", output, "model:tag/name", "config & %PATH% ' literal" } };
            session.Variables["YCONNECT_API_KEY"] = DemoApi.Key; session.Variables["YCONNECT_FIXTURE_EXE"] = typeof(Program).Assembly.Location;
            var info = session.ClientStartInfo(); info.CreateNoWindow = true;
            using (var child = Process.Start(info)) { Assert(child.WaitForExit(10000) && child.ExitCode == 0, "npm wrapper failed"); }
            var result = Json.Parse(File.ReadAllText(output)); Assert(result.Flag("keyMatched") && result.Array("arguments")[1].ToString() == "config & %PATH% ' literal", "npm command expanded literal data");
        });
        Test("Windows Terminal receives an encrypted one-use session", () =>
        {
            if (ClientDetection.ResolveExecutable("wt") == null) { Console.WriteLine("Windows Terminal unavailable; native shell coverage remains active"); return; }
            var env = Env("terminal-handoff"); Directory.CreateDirectory(env.ClientHome);
            var plan = ClientLauncher.Build(env, "codex", "gpt-5.4", DemoApi.Models, DemoApi.Key, env.ClientHome, "terminal", true);
            var output = Path.Combine(env.DataRoot, "child.json");
            plan.Session.Executable = typeof(Program).Assembly.Location; plan.Session.Arguments = new[] { "--launch-fixture", output }; plan.Session.CloseOnExit = true;
            ClientLauncher.Start(plan, "terminal").GetAwaiter().GetResult();
            for (var i = 0; i < 100 && !File.Exists(output); i++) Thread.Sleep(100);
            Assert(File.Exists(output) && Json.Parse(File.ReadAllText(output)).Flag("keyMatched"), "Terminal dropped session environment");
            Assert(!File.Exists(Path.Combine(plan.Directory, "session.bin")), "Terminal handoff was not consumed");
        });
        foreach (var descriptor in ClientRegistry.All.Where(d => !d.Bridge))
        {
            var d = descriptor;
            Test(d.Name + " apply, native helper, no-op and exact restore", () =>
            {
                var env = Env("适配 空格 ' " + d.Id); var clients = new ClientRegistry(env); var selected = d.Compatible(DemoApi.Models).First();
                var files = clients.Paths(d.Id); var original = new Dictionary<string, byte[]>();
                foreach (var file in files)
                {
                    var seed = file.EndsWith(".toml") ? "# keep this comment\n[other]\nvalue = 7\n" : file.EndsWith(".yaml") ? "# keep this comment\nnetwork:\n  host: localhost\n" : "{\n  \"unrelated\": { \"value\": 7 }\n}\n";
                    SecureFiles.WriteText(file, seed); original[file] = File.ReadAllBytes(file);
                }
                var plan = clients.Build(d.Id, selected.Id, DemoApi.Models, DemoApi.Key); clients.Transactions.Apply(plan);
                foreach (var file in files) Assert(!File.ReadAllText(file).Contains(DemoApi.Key), "inline credential leaked");
                Assert(clients.Inspect(d.Id).State == "configured", "not configured after apply");
                if (File.Exists(env.Helper(d.Id)))
                {
                    using (var process = Process.Start(new ProcessStartInfo(env.Helper(d.Id)) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }))
                    { var output = process.StandardOutput.ReadToEnd(); process.WaitForExit(); Assert(process.ExitCode == 0 && output == DemoApi.Key, "native helper failed to return exact key"); }
                }
                var again = clients.Build(d.Id, selected.Id, DemoApi.Models, DemoApi.Key); Assert(again.Changes.All(f => f.BeforeHash == f.AfterHash), "second apply was not idempotent"); clients.Transactions.Apply(again);
                clients.Restore(d.Id); foreach (var file in files) Assert(File.ReadAllBytes(file).SequenceEqual(original[file]), "restore did not preserve original bytes");
                Assert(!File.Exists(env.Secret(d.Id)), "new credential not removed on restore");
                Assert(!File.Exists(env.Helper(d.Id)), "new helper not removed on restore");
            });
        }
        Test("Protocol gates and Claude model-family restriction", () =>
        {
            var clients = new ClientRegistry(Env("protocols"));
            Throws(() => clients.Build("gemini-cli", "gpt-5.4", DemoApi.Models, DemoApi.Key));
            Throws(() => clients.Build("claude-desktop", "grok-4", DemoApi.Models, DemoApi.Key));
            Assert(clients.Get("codex").Compatible(DemoApi.Models).Count() == DemoApi.Models.Length, "gateway-compatible models hidden from Codex");
            Assert(clients.Get("claude-desktop").Compatible(DemoApi.Models).All(m => m.Id.Contains("claude")), "Claude Desktop family gate failed");
        });
        Test("Non-owned JSON providers and nested settings survive", () =>
        {
            var clients = new ClientRegistry(Env("json-preservation")); var file = clients.Paths("opencode")[0]; SecureFiles.WriteText(file, "{ // original JSONC\n provider: { custom: { token: 'test-secret', name: 'keep' } }, plugin: ['keep-me'], unrelated: { depth: [1,2] }, }");
            var plan = clients.Build("opencode", "gpt-5.4", DemoApi.Models, DemoApi.Key); clients.Transactions.Apply(plan); var data = Json.Parse(File.ReadAllText(file));
            Assert(data["provider"]["custom"].Text("token") == "test-secret" && data["plugin"][0].ToString() == "keep-me", "unknown provider changed");
        });
        Test("Preview redacts another provider's credential", () =>
        {
            var preview = ConfigurationEditors.RedactPreview("  \"apiKey\": \"unrelated-very-secret\",\n  \"apiKeyHelper\": \"C:\\\\helper.exe\"\n");
            Assert(!preview.Contains("unrelated-very-secret"), "preview leaked foreign credential"); Assert(preview.Contains("helper.exe"), "helper should remain inspectable");
        });
        Test("TOML unrelated multiline literals and comments survive", () =>
        {
            var source = "# original comment\ndescription = '''\n[model_providers.yakcool]\nnot = 'a table'\n'''\n[tools]\nkeep = true\n";
            var output = ConfigurationEditors.EditToml(source, new JObject { ["model"] = "example" }, new Dictionary<string, JObject> { ["model_providers.yakcool"] = new JObject { ["name"] = "YAKCOOL" } });
            Assert(output.Contains(source), "unowned multiline text changed");
        });
        Test("Malformed JSON and TOML are rejected before writes", () =>
        {
            var clients = new ClientRegistry(Env("invalid")); SecureFiles.WriteText(clients.Paths("opencode")[0], "{ invalid: [ }");
            Throws(() => clients.Build("opencode", "gpt-5.4", DemoApi.Models, DemoApi.Key));
            Assert(!File.Exists(clients.Environment.Secret("opencode")), "credential written before validation");
            Throws(() => ConfigurationEditors.EditToml("x = [", new JObject(), new Dictionary<string, JObject>()));
        });
        Test("Windows UTF-8 BOM configurations restore original bytes", () =>
        {
            var clients = new ClientRegistry(Env("windows-bom")); var file = clients.Paths("codex")[0]; var original = new byte[] { 0xef, 0xbb, 0xbf }.Concat(Encoding.UTF8.GetBytes("# UTF-8 BOM\n[other]\nvalue = 1\n")).ToArray(); SecureFiles.AtomicWrite(file, original);
            clients.Transactions.Apply(clients.Build("codex", "gpt-5.4", DemoApi.Models, DemoApi.Key)); clients.Restore("codex"); Assert(File.ReadAllBytes(file).SequenceEqual(original), "BOM bytes were not restored");
        });
        Test("Hermes exact transport identifiers and unowned comments", () =>
        {
            foreach (var candidate in new[] { ("gpt-5.4", "codex_responses"), ("claude-opus-4-6", "anthropic_messages"), ("deepseek-v3.2", "chat_completions") })
            {
                var clients = new ClientRegistry(Env("hermes-" + candidate.Item1)); var file = clients.Paths("hermes")[0]; SecureFiles.WriteText(file, "# Header\nnetwork:\n  # Keep network comment\n  port: 3456\nproviders:\n  other:\n    api: https://example.com\n");
                var plan = clients.Build("hermes", candidate.Item1, DemoApi.Models, DemoApi.Key); clients.Transactions.Apply(plan); var result = File.ReadAllText(file);
                Assert(result.Contains("transport: " + candidate.Item2) && result.Contains("# Keep network comment") && result.Contains("https://example.com"), "Hermes mapping changed");
            }
        });
        Test("Preview detects external modification before apply", () =>
        {
            var clients = new ClientRegistry(Env("concurrency")); var file = clients.Paths("pi")[0]; var plan = clients.Build("pi", "gpt-5.4", DemoApi.Models, DemoApi.Key);
            SecureFiles.WriteText(file, "{\"external\":true}"); Throws(() => clients.Transactions.Apply(plan)); Assert(File.ReadAllText(file).Contains("external"), "external contents lost");
        });
        Test("Multi-file failure rolls back touched files", () =>
        {
            var clients = new ClientRegistry(Env("rollback")); var plan = clients.Build("pi", "gpt-5.4", DemoApi.Models, DemoApi.Key);
            clients.Transactions.BeforeWrite = (index, file) => { if (index == 2) throw new IOException("injected failure"); }; Throws(() => clients.Transactions.Apply(plan));
            Assert(plan.Changes.All(f => !File.Exists(f.Path)), "partial transaction was left installed");
        });
        Test("Post-write validation failure rolls back", () =>
        {
            var clients = new ClientRegistry(Env("post-validation")); var plan = clients.Build("opencode", "gpt-5.4", DemoApi.Models, DemoApi.Key);
            clients.Transactions.ValidateWritten = p => throw new IOException("injected validation failure"); Throws(() => clients.Transactions.Apply(plan)); Assert(plan.Changes.All(f => !File.Exists(f.Path)), "post-validation rollback failed");
        });
        Test("Restore refuses an external edit after installation", () =>
        {
            var clients = new ClientRegistry(Env("restore-drift")); var plan = clients.Build("codex", "gpt-5.4", DemoApi.Models, DemoApi.Key); clients.Transactions.Apply(plan); var file = clients.Paths("codex")[0]; File.AppendAllText(file, "\n# external change");
            Throws(() => clients.Restore("codex")); Assert(File.ReadAllText(file).Contains("external change"), "external edit overwritten");
        });
        Test("Backup contents and session use DPAPI; scoped ACL", () =>
        {
            var env = Env("encryption"); SecureFiles.SaveSession(env, new JObject { ["key"] = DemoApi.Key }); var binary = File.ReadAllBytes(Path.Combine(env.DataRoot, "Credentials", "session.bin"));
            Assert(!Encoding.UTF8.GetString(binary).Contains(DemoApi.Key), "session stored plaintext"); Assert(SecureFiles.LoadSession(env).Text("key") == DemoApi.Key, "DPAPI round trip failed");
            var acl = File.GetAccessControl(Path.Combine(env.DataRoot, "Credentials", "session.bin")); Assert(acl.AreAccessRulesProtected, "secret inherited public access");
            SecureFiles.ClearSession(env); Assert(SecureFiles.LoadSession(env) == null, "session not cleared");
        });
        Test("Hard-linked configuration cannot be overwritten", () =>
        {
            var env = Env("hardlink"); Directory.CreateDirectory(env.DataRoot); var original = Path.Combine(env.DataRoot, "original.json"); var linked = Path.Combine(env.DataRoot, "linked.json"); File.WriteAllText(original, "{}");
            Assert(CreateHardLink(linked, original, IntPtr.Zero), "test hardlink creation failed"); Throws(() => SecureFiles.AtomicWrite(linked, Encoding.UTF8.GetBytes("{\"changed\":true}"))); Assert(File.ReadAllText(original) == "{}", "hardlink target changed");
        });
        Test("Credentials, URLs and model IDs reject injection", () =>
        {
            Throws(() => YakCoolApi.ValidateKey("key\nCookie: leak")); Throws(() => YakCoolApi.ValidateCookie("cookie; other=token")); Throws(() => YakCoolApi.ValidateModel("model\nname"));
            foreach (var url in new[] { "http://aibalance.yaklang.com", "https://yaklang.com.attacker.test", "https://aibalance.yaklang.com/path", "https://user@aibalance.yaklang.com", "https://aibalance.yaklang.com:8443" }) Throws(() => YakCoolApi.ValidateGateway(url));
            Assert(!WebLoginWindow.IsAllowed("https://yakcool.com.evil.test/") && WebLoginWindow.IsAllowed("https://open.weixin.qq.com/"), "login host allowlist failed");
        });
        Test("DPI, negative displays, left/right and small screen bounds", () =>
        {
            foreach (var scale in new[] { 1d, 1.25, 1.5, 2d }) foreach (var left in new[] { false, true }) foreach (var percent in new[] { 2d, 58d, 98d })
                    {
                        var work = new System.Drawing.Rectangle(-1920, -100, 1920, 1080); var edge = WindowsDesktop.EdgeBounds(work, scale, left, percent); var widget = WindowsDesktop.WidgetBounds(work, edge, scale, left, 408, 900);
                        Assert(work.Contains(edge) && work.Contains(widget), "window escaped working area");
                    }
        });
        Test("Installed client filtering and stable recent ordering", () =>
        {
            var env = Env("installed"); var clients = new ClientRegistry(env); var ids = ClientRegistry.All.Where(c => !c.Bridge).Select(c => c.Id).ToArray();
            foreach (var count in new[] { 0, 1, 3, 4, 5, 8 })
            {
                env.SetPreviewClients(ids.Take(count).ToArray());
                Assert(clients.InstalledClients(new[] { ids.Last(), ids.First() }).Length == count, "uninstalled client leaked");
            }
            env.SetPreviewClients(ids.Take(5).ToArray());
            var ordered = clients.InstalledClients(new[] { ids[3], ids[1], ids[7] }).Select(c => c.Id).ToArray();
            Assert(ordered.SequenceEqual(new[] { ids[3], ids[1], ids[0], ids[2], ids[4] }), "recent ordering is unstable");
            var isolated = new EnvironmentPaths(true, false, Path.Combine(root, "config-is-not-installed"));
            SecureFiles.WriteText(isolated.HomePath(".yconnect-nonexistent-test-client", "config.json"), "{}");
            Assert(!ClientDetection.Installed(isolated, "yconnect-nonexistent-test-client"), "configuration alone was treated as installation");
        });
        Test("Startup defaults, explicit off, legacy migration and retry", () =>
        {
            var registry = false; var writes = 0; var saves = 0; var prefs = new Preferences();
            Action<bool> write = value => { registry = value; writes++; };
            StartupPolicy.Initialize(false, false, prefs, () => registry, write, () => saves++);
            Assert(registry && prefs.StartupChoice == true && writes == 1 && saves == 1, "new install did not enable startup");
            prefs.StartupChoice = false; registry = false;
            StartupPolicy.Initialize(false, false, prefs, () => registry, write, () => saves++);
            Assert(!registry && writes == 1, "explicit off was overwritten");
            var legacy = new Preferences();
            StartupPolicy.Initialize(false, true, legacy, () => false, write, () => saves++);
            Assert(legacy.StartupChoice == false && writes == 1, "legacy off was lost");
            var isolated = new Preferences();
            StartupPolicy.Initialize(true, false, isolated, () => registry, write, () => saves++);
            Assert(isolated.StartupChoice == null && writes == 1, "preview touched startup");
            var retry = new Preferences();
            Throws(() => StartupPolicy.Initialize(false, false, retry, () => false, value => { throw new IOException("denied"); }, () => saves++));
            Assert(retry.StartupChoice == null, "failed startup was marked done");
            StartupPolicy.Initialize(false, false, retry, () => registry, write, () => saves++);
            Assert(retry.StartupChoice == true && registry, "startup retry failed");
        });
        Test("Native drag excludes inputs, selectors and buttons", () =>
        {
            Assert(!DragSurface.IsInteractive(new System.Windows.Controls.TextBlock { Text = "Balance" }), "card text cannot drag");
            Assert(!DragSurface.IsInteractive(new System.Windows.Controls.Border()), "blank card cannot drag");
            foreach (var control in new System.Windows.DependencyObject[] { new System.Windows.Controls.Button(), new System.Windows.Controls.TextBox(), new System.Windows.Controls.PasswordBox(), new System.Windows.Controls.ComboBox(), new System.Windows.Controls.CheckBox(), new System.Windows.Controls.Primitives.Thumb() })
                Assert(DragSurface.IsInteractive(control), "interactive control became a drag surface");
        });
        Test("Proximity geometry includes corners and negative monitor coordinates", () =>
        {
            var bounds = new System.Drawing.Rectangle(-1920, 500, 30, 112);
            Assert(WindowsDesktop.Distance(bounds, new System.Drawing.Point(-1910, 540)) == 0, "inside distance");
            Assert(Math.Abs(WindowsDesktop.Distance(bounds, new System.Drawing.Point(-1860, 652)) - 50) < .01, "corner distance");
        });
        await TestAsync("Balance presentation preserves account/key privacy and unknown states", async () =>
        {
            var store = new YConnectStore(Env("balance"), new DemoApi());
            Assert(BalancePresentation.From(store).Value == "尚未连接", "signed out value");
            await store.LoginAccount("demo-public-session-only");
            var exact = BalancePresentation.From(store); Assert(exact.Value == "¥128.60" && exact.Percent > 85 && exact.Percent < 86 && !exact.Stale, "account amount/percent");
            Assert(BalancePresentation.From(store, true).Value == "约 86%", "privacy amount leaked");
            ((JObject)store.Dashboard["ai_service_credit"]).Remove("token_limit");
            Assert(BalancePresentation.From(store, true).Value == "暂不可用", "missing limit fabricated percentage");
            await store.LoginKey(DemoApi.Key); var shared = BalancePresentation.From(store);
            Assert(shared.Value == "约 80%" && !shared.Value.Contains("¥"), "shared key leaked exact account balance");
            store.KeyInfo["quota"] = new JObject { ["follows_account"] = false, ["remaining_rmb"] = 12.34, ["used_percent_approx"] = 40 };
            Assert(BalancePresentation.From(store).Value == "¥12.34" && BalancePresentation.From(store).Percent == 60, "independent key quota");
            store.KeyInfo["quota"] = new JObject { ["follows_account"] = true };
            Assert(BalancePresentation.From(store).Value == "暂不可用" && BalancePresentation.From(store).Percent == null, "unknown key quota fabricated");
        });
        await TestAsync("Key suggestions fill naming gaps and models remain authorized", async () =>
        {
            var store = new YConnectStore(Env("suggestions"), new DemoApi()); await store.LoginAccount("demo-public-session-only");
            Assert(store.SuggestedKeyName() == "Y CONNECT-1", "first suggestion");
            store.Keys.Add(new JObject { ["label"] = "Y CONNECT-1" }); store.Keys.Add(new JObject { ["label"] = "y connect-3" });
            Assert(store.SuggestedKeyName() == "Y CONNECT-2", "first unused name");
            store.RememberModel("gpt-5.4"); Assert(store.FrequentModels.First().Id == "gpt-5.4" && store.Preferences.CurrentModel == "gpt-5.4", "recent selection");
            Throws(() => store.RememberModel("unavailable-model"));
            store.Preferences.CurrentModel = "unavailable-model"; await store.LoginKey(DemoApi.Key);
            Assert(store.Models.Any(m => m.Id == store.Preferences.CurrentModel), "stale model carried into key mode");
        });
        await TestAsync("Account and key state, revocation boundaries, model discovery", async () =>
        {
            var store = new YConnectStore(Env("store"), new DemoApi()); await store.LoginAccount("demo-public-session-only"); Assert(store.Mode == "account" && store.Keys.Count == 2 && store.Models.Count == 6, "account failed");
            await store.CreateKey("Native test"); Assert(store.Keys.Count == 3, "key creation failed"); var id = store.Preferences.SelectedKey.Value; await store.DeleteKey(id); Assert(store.Keys.Count == 2, "deletion failed");
            await store.Redeem("DEMO-REDEEM-1234"); Assert(store.Remaining == 138.6, "redemption failed"); await store.LoginKey(DemoApi.Key); Assert(store.Keys.Count == 0 && store.Dashboard == null, "account data leaked into key mode");
            Assert(store.Models.All(m => YakCoolApi.Protocols.All(m.Protocols.Contains)), "gateway protocols were not expanded");
            await ThrowsAsync(() => store.CreateKey("forbidden")); await ThrowsAsync(() => store.Probe("gpt-5.4", "responses", false)); await store.SignOut(); Assert(store.CurrentKey == null && store.Models.Count == 0, "signout did not clear state");
        });
        await TestAsync("Basic checks issue no paid model request", async () =>
        {
            var store = new YConnectStore(Env("checks"), new DemoApi()); await store.LoginKey(DemoApi.Key); await store.CheckConnection(); Assert(store.Checks.Count == 3 && store.Checks.All(c => c.State == "passed"), "checks failed");
        });
        await TestAsync("Real enabled status, exhausted quota, empty models and revoked key", async () =>
        {
            var api = new SwitchableApi(); var store = new YConnectStore(Env("real-health-contract"), api); await store.LoginKey(DemoApi.Key);
            api.Info = JObject.Parse("{key:{status:'enabled'},quota:{exhausted:true,display:'余额已用尽'}}"); await store.CheckConnection();
            Assert(store.Checks[1].State == "warning" && store.Checks[2].State == "passed" && api.ProbeCount == 0, "quota confused with disabled key");
            api.ModelData = new JObject { ["data"] = new JArray() }; await store.CheckConnection(); Assert(store.Checks[2].State == "warning", "zero models marked healthy");
            api.Info["key"]["status"] = "disabled"; await store.CheckConnection(); Assert(store.Checks[1].State == "failed" && store.Checks[2].State == "skipped", "revoked key continued model checks");
            await store.SignOut(); await store.CheckConnection(); Assert(store.Checks[0].State == "passed" && store.Checks.Skip(1).All(c => c.State == "skipped"), "signed-out check reported broken service");
        });
        await TestAsync("Probe evidence distinguishes truncation, empty output and incorrect answers", async () =>
        {
            var handler = new RecordingHandler(); using (var api = new YakCoolApi(handler))
            {
                handler.Response = "{choices:[{finish_reason:'length',message:{content:'',reasoning_content:'thinking'}}]}";
                var truncated = await api.Probe(DemoApi.Key, "fixture", "chat_completions", "connectivity"); Assert(truncated.Status == "warning" && truncated.Reasoning == "thinking", "truncation lost evidence");
                handler.Response = "{choices:[{message:{content:''}}]}";
                Assert((await api.Probe(DemoApi.Key, "fixture", "chat_completions", "thinking_off")).Status == "failed", "empty thinking-off passed");
                Assert((await api.Probe(DemoApi.Key, "fixture", "chat_completions", "effort_high")).Status == "failed", "empty effort passed");
                handler.Response = "{choices:[{message:{content:'999',reasoning_content:'reasoning'}}]}";
                Assert((await api.Probe(DemoApi.Key, "fixture", "chat_completions", "thinking_on")).Status == "warning", "wrong math passed");
                handler.Response = "{choices:[{message:{content:'pong'}}]}";
                Assert((await api.Probe(DemoApi.Key, "fixture", "chat_completions", "tools_roundtrip")).Status == "unsupported", "constant answer faked tool result");
                handler.Response = "{choices:[{message:{content:'YCONNECT_OK'}}]}";
                Assert((await api.Probe(DemoApi.Key, "fixture", "chat_completions", "connectivity")).Status == "passed", "valid marker rejected");
            }
        });
        await TestAsync("Failed baseline stops quality requests and protocol is not falsely verified", async () =>
        {
            var api = new SwitchableApi { ProbeResult = new ModelProbeResult { Status = "failed", Result = "empty" } }; var store = new YConnectStore(Env("failed-quality"), api); await store.LoginKey(DemoApi.Key);
            await store.ProbeQuality("gpt-5.4", "responses", true); Assert(api.ProbeCount == 1 && store.QualityChecks[0].State == "failed" && store.QualityChecks.Skip(2).All(x => x.State == "skipped"), "baseline failure consumed more requests");
            await store.Probe("gpt-5.4", "responses", true); Assert(store.LastProbe.Status == "failed", "minimum result not preserved");
            await store.LoginKey("yc-demo-another-key"); Assert(store.Checks.Count == 0 && store.LastProbe == null && store.QualityChecks.Count == 0, "old key evidence survived switch");
        });
        await TestAsync("Cancel stops the in-flight quality request and skips the remaining checks", async () =>
        {
            var api = new SwitchableApi { WaitForCancellation = true }; var store = new YConnectStore(Env("cancel-quality"), api); await store.LoginKey(DemoApi.Key);
            var pending = store.ProbeQuality("gpt-5.4", "responses", true); Assert(store.CanCancelTest, "cancel button would be absent"); store.CancelTest(); await pending;
            Assert(!store.CanCancelTest && api.ProbeCount == 1 && store.QualityChecks.All(c => c.State == "skipped"), "cancel kept running or sent more requests");
        });
        await TestAsync("Full model profile mirrors AIBalance capability dimensions", async () =>
        {
            var store = new YConnectStore(Env("quality"), new DemoApi()); await store.LoginKey(DemoApi.Key); await store.ProbeQuality("gpt-5.4", "responses", true);
            Assert(store.QualityChecks.Count == 15, "quality matrix size changed");
            foreach (var key in new[] { "protocol", "connectivity", "vision", "tools_auto", "tools_schema", "tools_forced", "tools_roundtrip", "thinking_off", "thinking_on", "effort_minimal", "effort_low", "effort_medium", "effort_high", "effort_xhigh", "effort_max" })
                Assert(store.QualityChecks.Any(x => x.Key == key), "missing quality check " + key);
            Assert(store.QualityChecks.All(x => new[] { "passed", "unsupported" }.Contains(x.State)), "quality profile did not finish");
        });
        await TestAsync("Encrypted account and key sessions restore after restart", async () =>
        {
            foreach (var account in new[] { true, false })
            {
                var env = Env("restart-" + account); var store = new YConnectStore(env, new DemoApi());
                if (account) await store.LoginAccount("demo-public-session-only"); else await store.LoginKey(DemoApi.Key);
                var restarted = new YConnectStore(env, new DemoApi()); await restarted.RestoreSession();
                Assert(restarted.Mode == (account ? "account" : "apiKey") && restarted.Models.Count == 6, "saved session did not restore");
                await restarted.SignOut(); var signedOut = new YConnectStore(env, new DemoApi()); await signedOut.RestoreSession(); Assert(!signedOut.Authenticated, "logout persisted credentials");
            }
        });
        await TestAsync("Expired refresh clears stale data and encrypted session", async () =>
        {
            var env = Env("expire"); var api = new SwitchableApi(); var store = new YConnectStore(env, api); await store.LoginKey(DemoApi.Key);
            api.Failure = new ApiRequestException(401, "expired"); Assert(!await store.Run(store.Refresh), "expired request passed");
            Assert(!store.Authenticated && store.Models.Count == 0 && store.CurrentKey == null && SecureFiles.LoadSession(env) == null, "expired credentials survived");
        });
        await TestAsync("Transient startup failure preserves saved login for retry", async () =>
        {
            var env = Env("retry-session"); var api = new SwitchableApi(); var first = new YConnectStore(env, api); await first.LoginAccount("demo-public-session-only");
            api.Failure = new InvalidOperationException("temporary network failure"); var retry = new YConnectStore(env, api); await retry.RestoreSession();
            Assert(!retry.Authenticated && retry.CanRetrySession && SecureFiles.LoadSession(env) != null, "transient failure destroyed session");
            api.Failure = null; await retry.RestoreSession(); Assert(retry.Authenticated && !retry.CanRetrySession, "session retry failed");
        });
        await TestAsync("Staff and unauthenticated public sessions are rejected", async () =>
        {
            foreach (var me in new[] { new JObject { ["user"] = new JObject(), ["staff_session"] = true }, new JObject { ["user"] = null } })
            {
                var api = new SwitchableApi { Me = me }; var env = Env("reject-" + Guid.NewGuid()); var store = new YConnectStore(env, api);
                await ThrowsAsync(() => store.LoginAccount("demo-public-session-only")); Assert(!store.Authenticated && SecureFiles.LoadSession(env) == null, "invalid public session was persisted");
            }
        });
        await TestAsync("HTTP public cookie, business bearer and gateway protocols", async () =>
        {
            var handler = new RecordingHandler(); using (var api = new YakCoolApi(handler))
            {
                await api.Get("/api/user/dashboard", cookie: "demo-public-session-only"); Assert(handler.LastUri.Host == "yakcool.com" && handler.Cookie == "yakcool_user_session=demo-public-session-only" && handler.Authorization == null, "cookie boundary failed");
                await api.Get("/api/key/info", key: DemoApi.Key); Assert(handler.Authorization == "Bearer " + DemoApi.Key && handler.Cookie == null, "key boundary failed");
                await ThrowsAsync(() => api.Get("/api/health", cookie: "demo-public-session-only")); await ThrowsAsync(() => api.Get("//evil", key: DemoApi.Key));
                await api.Probe(DemoApi.Key, "claude-sonnet-4-6", "anthropic_messages", "thinking_on"); Assert(handler.LastUri.AbsolutePath == "/v1/messages" && handler.ApiKey == DemoApi.Key && handler.Cookie == null, "Messages credential boundary");
                Assert(handler.Body.Contains("\"thinking\"") && handler.Body.Contains("\"enabled\"") && handler.Body.Contains("max_tokens"), "thinking probe payload incorrect");
                await api.Probe(DemoApi.Key, "gpt-5.4", "responses", "effort_high"); Assert(handler.LastUri.AbsolutePath == "/v1/responses" && handler.Body.Contains("max_output_tokens") && handler.Body.Contains("\"high\""), "Responses effort probe failed");
            }
        });
        await TestAsync("HTTP redirect and error secret redaction", async () =>
        {
            var handler = new RecordingHandler { Status = HttpStatusCode.Found, Response = "{\"error\":\"Bearer " + DemoApi.Key + "\"}" }; using (var api = new YakCoolApi(handler))
            {
                try { await api.Get("/api/key/info", key: DemoApi.Key); throw new Exception("Redirect accepted"); } catch (InvalidOperationException e) { Assert(!e.Message.Contains(DemoApi.Key), "API error leaked credential"); }
            }
        });
        await TestAsync("Recharge cent-accurate input validation", RechargeChecks.Amounts);
        await TestAsync("Recharge pending, verified paid and terminal order states", RechargeChecks.PaymentStates);
        await TestAsync("Recharge rejects amount, order, channel and QR mismatches", RechargeChecks.Mismatches);
        await TestAsync("Recharge expiry, late payment and network recovery", RechargeChecks.ExpiryAndErrors);
        await TestAsync("Recharge account isolation and duplicate-submit prevention", RechargeChecks.AccountAndConcurrency);
        await TestAsync("Recharge exact authenticated HTTP route boundary", RechargeChecks.HttpBoundary);
        await TestAsync("Late terminal handoff survives UI timeout and expires safely", () => LauncherChecks.SlowHandoff(root, typeof(Program).Assembly.Location));
        await TestAsync("Concurrent launches cancel, fail and retry independently; closed bootstrap fails fast", () => LauncherChecks.Concurrency(root, typeof(Program).Assembly.Location));
        await TestAsync("AppData physical paths cross the MSIX to Windows Terminal boundary", () => LauncherChecks.PhysicalHandoff(root, typeof(Program).Assembly.Location));
        await TestAsync("Bootstrap errors report exact safe stages and never report false readiness", () => LauncherChecks.Failures(root, typeof(Program).Assembly.Location));
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateHardLink(string name, string existing, IntPtr attributes);
    private sealed class SwitchableApi : IYakCoolApi
    {
        private readonly DemoApi inner = new DemoApi(); public Exception Failure; public JObject Me, Info, ModelData; public ModelProbeResult ProbeResult; public int ProbeCount; public bool WaitForCancellation;
        public Task<JObject> Get(string path, string key = null, string cookie = null) { if (Failure != null) throw Failure; if (path == "/api/auth/me" && Me != null) return Task.FromResult(Me); if (path == "/api/key/info" && Info != null) return Task.FromResult(Info); if (path == "/api/key/models" && ModelData != null) return Task.FromResult(ModelData); return inner.Get(path, key, cookie); }
        public Task<JObject> Send(string path, string method, JObject body, string cookie) { if (Failure != null) throw Failure; return inner.Send(path, method, body, cookie); }
        public async Task<ModelProbeResult> Probe(string key, string model, string protocol, string check, CancellationToken cancellation = default) { ProbeCount++; if (WaitForCancellation) await Task.Delay(Timeout.Infinite, cancellation); return ProbeResult ?? await inner.Probe(key, model, protocol, check, cancellation); }
    }
    private static async Task<int> VerifyLiveConnection()
    {
        try
        {
            var production = new EnvironmentPaths(); var saved = SecureFiles.LoadSession(production);
            if (saved == null) { Console.WriteLine("No saved session"); return 2; }
            var preferences = SecureFiles.ReadText(Path.Combine(production.DataRoot, "preferences.json"));
            using (var api = new YakCoolApi(useSystemProxy: !(preferences != null && Json.Parse(preferences).Flag("BypassProxy"))))
            {
                var store = new YConnectStore(new EnvironmentPaths(true, false, Path.Combine(Path.GetTempPath(), "YConnectReadOnlyCheck-" + Guid.NewGuid().ToString("N"))), api);
                if (saved.Text("mode") == "account") await store.LoginAccount(saved.Text("cookie"), false); else await store.LoginKey(saved.Text("key"), false);
                await store.CheckConnection(); foreach (var check in store.Checks) Console.WriteLine(check.Title + ": " + check.State + " (" + check.Milliseconds + " ms)");
                Console.WriteLine("Authorized models: " + store.Models.Count + "; paid requests: 0"); return store.Checks.All(c => c.State == "passed") ? 0 : 1;
            }
        }
        catch (Exception error) { Console.WriteLine(YakCoolApi.Redact(error.Message)); return 1; }
    }
    private static int VerifyInstalledLaunchers()
    {
        foreach (var id in new[] { "codex", "grok-build" })
        {
            if (ClientDetection.Resolve(id) == null) { Console.WriteLine(id + ": not installed"); continue; }
            var env = new EnvironmentPaths(true, true, Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "launcher-validation", Guid.NewGuid().ToString("N"))); Directory.CreateDirectory(env.ClientHome);
            var plan = ClientLauncher.Build(env, id, "gpt-5.4", DemoApi.Models, DemoApi.Key, env.ClientHome, "powershell", false);
            SecureFiles.ProtectDirectory(plan.Directory); foreach (var file in plan.Files) SecureFiles.WriteText(file.Key, file.Value, true);
            if (id == "codex") { plan.Session.Variables["CODEX_HOME"] = plan.Directory; plan.Session.Arguments = plan.Session.Arguments.Concat(new[] { "features", "list" }).ToArray(); }
            else plan.Session.Arguments = plan.Session.Arguments.Concat(new[] { "inspect" }).ToArray();
            var info = plan.Session.ClientStartInfo(); info.CreateNoWindow = true; info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            using (var process = Process.Start(info))
            {
                var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(20000)) { process.Kill(); Console.WriteLine(id + ": timed out"); return 1; }
                Task.WaitAll(stdout, stderr);
                if (process.ExitCode != 0) { Console.WriteLine(id + ": config validation failed: " + YakCoolApi.Redact(stderr.Result, DemoApi.Key)); return 1; }
                Console.WriteLine(id + ": installed CLI accepted session configuration; no model prompt sent");
            }
        }
        return 0;
    }
    private sealed class RecordingHandler : HttpMessageHandler
    {
        public Uri LastUri; public string Authorization, Cookie, ApiKey, Body; public HttpStatusCode Status = HttpStatusCode.OK; public string Response;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            LastUri = request.RequestUri; Authorization = request.Headers.TryGetValues("Authorization", out var a) ? a.Single() : null; Cookie = request.Headers.TryGetValues("Cookie", out var c) ? c.Single() : null; ApiKey = request.Headers.TryGetValues("x-api-key", out var k) ? k.Single() : null; Body = request.Content == null ? null : await request.Content.ReadAsStringAsync();
            return new HttpResponseMessage(Status) { Content = new StringContent(Response ?? "{\"output\":[{\"content\":[{\"text\":\"OK\"}]}],\"content\":[{\"text\":\"OK\"}],\"choices\":[{\"message\":{\"content\":\"OK\"}}]}", Encoding.UTF8, "application/json") };
        }
    }
}
