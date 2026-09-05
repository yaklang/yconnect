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
        root = Path.GetFullPath(args.FirstOrDefault() ?? Path.Combine(Path.GetTempPath(), "YConnectTests-" + Guid.NewGuid().ToString("N"))); Directory.CreateDirectory(root);
        Test("Headless WPF layout, capability parity and responsive snapshots", () => LayoutChecks.Run(Path.Combine(root, "layout")));
        Run().GetAwaiter().GetResult(); File.WriteAllLines(Path.Combine(root, "results.txt"), results.Concat(new[] { passed + " passed, " + failed + " failed" })); Console.WriteLine(passed + " passed, " + failed + " failed"); return failed == 0 ? 0 : 1;
    }
    private static async Task Run()
    {
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
            Throws(() => clients.Build("codex", "deepseek-v3.2", DemoApi.Models, DemoApi.Key));
            Throws(() => clients.Build("claude-code", "gpt-5.4", DemoApi.Models, DemoApi.Key));
            Throws(() => clients.Build("claude-desktop", "grok-4", DemoApi.Models, DemoApi.Key));
            Assert(clients.Get("codex").Compatible(DemoApi.Models).All(m => m.Protocols.Contains("responses")), "wrong compatible models");
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
            var output = ConfigurationEditors.EditToml(source, new JObject { ["model"] = "example" }, new Dictionary<string, JObject> { ["model_providers.yakcool"] = new JObject { ["name"] = "YakCool" } });
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
            Assert(store.SuggestedKeyName() == "YConnect-1", "first suggestion");
            store.Keys.Add(new JObject { ["label"] = "YConnect-1" }); store.Keys.Add(new JObject { ["label"] = "yconnect-3" });
            Assert(store.SuggestedKeyName() == "YConnect-2", "first unused name");
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
            await ThrowsAsync(() => store.CreateKey("forbidden")); await ThrowsAsync(() => store.Probe("gpt-5.4", "responses", false)); await store.SignOut(); Assert(store.CurrentKey == null && store.Models.Count == 0, "signout did not clear state");
        });
        await TestAsync("Basic checks issue no paid model request", async () =>
        {
            var store = new YConnectStore(Env("checks"), new DemoApi()); await store.LoginKey(DemoApi.Key); await store.CheckConnection(); Assert(store.Checks.Count == 3 && store.Checks.All(c => c.State == "passed"), "checks failed");
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
                await api.Probe(DemoApi.Key, "claude-sonnet-4-6", "anthropic_messages"); Assert(handler.LastUri.AbsolutePath == "/v1/messages" && handler.ApiKey == DemoApi.Key && handler.Cookie == null, "Messages credential boundary");
                Assert(handler.Body.Contains("Reply exactly with OK.") && handler.Body.Contains("max_tokens"), "probe payload incorrect");
                await api.Probe(DemoApi.Key, "gpt-5.4", "responses"); Assert(handler.LastUri.AbsolutePath == "/v1/responses" && handler.Body.Contains("max_output_tokens"), "Responses probe failed");
            }
        });
        await TestAsync("HTTP redirect and error secret redaction", async () =>
        {
            var handler = new RecordingHandler { Status = HttpStatusCode.Found, Response = "{\"error\":\"Bearer " + DemoApi.Key + "\"}" }; using (var api = new YakCoolApi(handler))
            {
                try { await api.Get("/api/key/info", key: DemoApi.Key); throw new Exception("Redirect accepted"); } catch (InvalidOperationException e) { Assert(!e.Message.Contains(DemoApi.Key), "API error leaked credential"); }
            }
        });
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateHardLink(string name, string existing, IntPtr attributes);
    private sealed class SwitchableApi : IYakCoolApi
    {
        private readonly DemoApi inner = new DemoApi(); public Exception Failure; public JObject Me;
        public Task<JObject> Get(string path, string key = null, string cookie = null) { if (Failure != null) throw Failure; if (path == "/api/auth/me" && Me != null) return Task.FromResult(Me); return inner.Get(path, key, cookie); }
        public Task<JObject> Send(string path, string method, JObject body, string cookie) { if (Failure != null) throw Failure; return inner.Send(path, method, body, cookie); }
        public Task<string> Probe(string key, string model, string protocol) => inner.Probe(key, model, protocol);
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
