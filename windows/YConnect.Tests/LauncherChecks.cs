using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using YConnect.Core;
using YConnect.Native;

internal static class LauncherChecks
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int value);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    public static int InteractiveFixture(string root)
    {
        Console.WriteLine("Y CONNECT interactive fixture: no network requests; independent console session.");
        uint mode;
        var evidence = new JObject { ["pid"] = Process.GetCurrentProcess().Id, ["keyMatched"] = Environment.GetEnvironmentVariable("YCONNECT_API_KEY") == DemoApi.Key + "-" + Path.GetFileName(root), ["model"] = Environment.GetEnvironmentVariable("YCONNECT_MODEL"), ["cwd"] = Environment.CurrentDirectory, ["inputConsole"] = GetConsoleMode(GetStdHandle(-10), out mode), ["outputConsole"] = GetConsoleMode(GetStdHandle(-11), out mode) };
        using (var current = Process.GetCurrentProcess()) LaunchHandshake.TrackProcess(Path.Combine(root, "started.txt"), "fixture", current);
        File.WriteAllText(Path.Combine(root, "fixture.json"), evidence.ToString());
        var deadline = DateTime.UtcNow.AddMinutes(2);
        while (!File.Exists(Path.Combine(root, "stop.txt")) && DateTime.UtcNow < deadline) System.Threading.Thread.Sleep(100);
        return 0;
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static LaunchSession Fixture(string directory, string executable) => new LaunchSession { Client = "Fixture", Model = "fixture", Executable = executable, Arguments = new[] { "--launch-fixture", Path.Combine(directory, "child.json") }, WorkingDirectory = directory, AutoStart = true, CloseOnExit = true };
    private static async Task<int> Bootstrap(string directory, LaunchSession session, byte[] data = null)
    {
        Directory.CreateDirectory(directory); var file = Path.Combine(directory, "session.bin");
        SecureFiles.AtomicWrite(file, data ?? session.Protect(), true);
        using (var child = Process.Start(new ProcessStartInfo(ClientLauncher.Runner, LaunchSession.Quote(file)) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true }))
        {
            var stdout = child.StandardOutput.ReadToEndAsync(); var stderr = child.StandardError.ReadToEndAsync();
            if (!await Task.Run(() => child.WaitForExit(15000))) { child.Kill(); throw new Exception("Fixture timed out"); }
            await Task.WhenAll(stdout, stderr); return child.ExitCode;
        }
    }
    public static async Task SlowHandoff(string root, string executable)
    {
        var directory = Path.Combine(root, "slow-handoff"); Directory.CreateDirectory(directory);
        var manifest = Path.Combine(directory, "session.bin"); var session = Fixture(directory, executable);
        SecureFiles.AtomicWrite(manifest, session.Protect(), true);
        try { await LaunchHandshake.WaitForReady(manifest, TimeSpan.FromMilliseconds(150)); throw new Exception("Missing receipt accepted"); } catch (TimeoutException) { }
        Check(File.Exists(manifest), "UI timeout deleted a still-valid handoff");
        // The late helper consumes the original envelope, not a newly generated one.
        using (var child = Process.Start(new ProcessStartInfo(ClientLauncher.Runner, LaunchSession.Quote(manifest)) { UseShellExecute = false, CreateNoWindow = true }))
        { await LaunchHandshake.WaitForReady(manifest, TimeSpan.FromSeconds(10)); Check(await Task.Run(() => child.WaitForExit(10000)) && child.ExitCode == 0, "late bootstrap failed"); }
        Check(File.Exists(Path.Combine(directory, "child.json")) && !File.Exists(manifest), "late launch lost handoff or child");
        SecureFiles.AtomicWrite(manifest, session.Protect(), true); LaunchHandshake.DeleteExpired(manifest); Check(File.Exists(manifest), "cleanup removed a live session");
        File.SetLastWriteTimeUtc(manifest, DateTime.UtcNow - LaunchHandshake.Lifetime - TimeSpan.FromSeconds(1)); LaunchHandshake.DeleteExpired(manifest); Check(!File.Exists(manifest), "expired encrypted handoff retained");
    }
    public static async Task PhysicalHandoff(string root, string executable)
    {
        var logical = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YConnectLaunchValidation", Guid.NewGuid().ToString("N"));
        SecureFiles.ProtectDirectory(logical);
        var env = new EnvironmentPaths(true, true, logical); Directory.CreateDirectory(env.ClientHome);
        var plan = ClientLauncher.Build(env, "grok-build", "gpt-5.4", DemoApi.Models, DemoApi.Key, env.ClientHome, "terminal", true);
        Check(plan.Directory.StartsWith(SecureFiles.PhysicalPath(logical) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase), "session path is not physical");
        Check(plan.Session.Variables["GROK_HOME"] == plan.Directory && System.Linq.Enumerable.All(plan.Files.Keys, p => p.StartsWith(plan.Directory)), "isolated client config kept a virtual path");
        Check(!Directory.Exists(plan.Directory), "resolving a plan wrote its session");
        plan.Session.Executable = executable; plan.Session.CloseOnExit = true;
        var output = Path.Combine(plan.Directory, "fixture.json"); plan.Session.Arguments = new[] { "--launch-fixture", output };
        await ClientLauncher.Start(plan, ClientDetection.ResolveExecutable("wt") == null ? "powershell" : "terminal");
        var result = Json.Parse(File.ReadAllText(output));
        Check(result.Flag("keyMatched") && result.Text("cwd") == SecureFiles.PhysicalPath(env.ClientHome), "external Terminal cannot read the AppData handoff");
        Check(!File.Exists(Path.Combine(plan.Directory, "session.bin")), "encrypted handoff was not consumed");
        File.WriteAllText(Path.Combine(root, "physical-handoff.txt"), "Logical: " + logical + "\nPhysical: " + plan.Directory + "\nExternal bootstrap consumed the envelope; no model prompt sent.");
    }
    public static async Task Concurrency(string root, string executable)
    {
        using (var launches = new ClientLaunches())
        {
            Func<ClientLaunchPlan, string, System.Threading.CancellationToken, Task<string>> pending = async (p, t, token) => { await Task.Delay(10000, token); return "ready"; };
            var one = new ClientLaunchPlan { Directory = Path.Combine(root, "concurrent-one"), Session = Fixture(root, executable) };
            var two = new ClientLaunchPlan { Directory = Path.Combine(root, "concurrent-two"), Session = Fixture(root, executable) };
            var first = launches.Start(one, "terminal", pending); var second = launches.Start(two, "cmd", pending);
            Check(launches.Attempts.Count == 2 && launches.Attempts[0].Id != launches.Attempts[1].Id && launches.Attempts[1].State == "pending", "launches serialized or replaced");
            launches.StopWaiting(launches.Attempts[1].Id); Check((await first).State == "unconfirmed" && !second.IsCompleted, "canceling one affected another");
            var third = await launches.Start(one, "powershell", (p, t, token) => Task.FromResult("ready")); Check(third.State == "ready" && !second.IsCompleted, "pending launch blocked a new launch");
            launches.StopWaiting(launches.Attempts[1].Id); Check((await second).State == "unconfirmed", "second cancellation failed");
            var failure = await launches.Start(one, "terminal", (p, t, token) => Task.FromException<string>(new IOException("fixture failure")));
            Check(failure.State == "failed" && launches.Attempts[1].State == "ready", "failure changed another session");
        }
        var dir = Path.Combine(root, "closed-before-ready"); Directory.CreateDirectory(dir);
        using (var child = Process.Start(new ProcessStartInfo(executable, "--launch-fail-fixture") { UseShellExecute = false, CreateNoWindow = true }))
        {
            LaunchHandshake.TrackProcess(Path.Combine(dir, "started.txt"), "bootstrap", child); await Task.Run(() => child.WaitForExit());
            var watch = Stopwatch.StartNew();
            try { await LaunchHandshake.WaitForReady(Path.Combine(dir, "session.bin"), TimeSpan.FromSeconds(5)); throw new Exception("dead bootstrap accepted"); }
            catch (InvalidOperationException) { Check(watch.Elapsed < TimeSpan.FromSeconds(1), "closed terminal kept waiting"); }
        }
    }
    public static async Task Failures(string root, string executable)
    {
        foreach (var mode in new[] { "missing-client", "missing-directory", "expired", "invalid-envelope", "client-exit" })
        {
            var dir = Path.Combine(root, mode); Directory.CreateDirectory(dir); var session = Fixture(dir, executable);
            if (mode == "missing-client") session.Executable = Path.Combine(dir, "missing.exe");
            if (mode == "missing-directory") session.WorkingDirectory = Path.Combine(dir, "missing");
            if (mode == "expired") session.Created = DateTime.UtcNow.AddMinutes(-3);
            if (mode == "client-exit") session.Arguments = new[] { "--launch-fail-fixture" };
            var exit = await Bootstrap(dir, session, mode == "invalid-envelope" ? new byte[] { 1, 2, 3 } : null);
            Check(File.ReadAllText(Path.Combine(dir, "started.txt")) == "failed", mode + " falsely reported ready");
            var failure = JsonConvert.DeserializeObject<LaunchFailure>(File.ReadAllText(Path.Combine(dir, "launch-error.json")));
            Check(failure.Stage == (mode == "missing-client" ? "start-client" : mode == "invalid-envelope" ? "decrypt-session" : mode == "client-exit" ? "client-exit" : "check-session"), "incorrect failure stage: " + mode);
        }
        var redacted = JsonConvert.SerializeObject(LaunchFailure.From(new IOException("secret-key-never-log"), "read-session")); Check(!redacted.Contains("secret-key"), "diagnostic leaked exception payload");
        var absent = Path.Combine(root, "absent"); Directory.CreateDirectory(absent);
        using (var child = Process.Start(new ProcessStartInfo(ClientLauncher.Runner, LaunchSession.Quote(Path.Combine(absent, "session.bin"))) { UseShellExecute = false, CreateNoWindow = true })) Check(await Task.Run(() => child.WaitForExit(10000)) && child.ExitCode != 0, "missing handoff accepted");
        Check(File.ReadAllText(Path.Combine(absent, "launch-error.json")).Contains("read-session"), "failure before decrypt was not reported");
    }
    public static async Task<int> RealTerminalClients(string root, string runner)
    {
        if (ClientDetection.ResolveExecutable("wt") == null) throw new Exception("Windows Terminal unavailable");
        foreach (var id in new[] { "grok-build", "codex" })
        {
            if (ClientDetection.Resolve(id) == null) { Console.WriteLine(id + ": not installed"); continue; }
            var env = new EnvironmentPaths(true, true, Path.Combine(root, id)); Directory.CreateDirectory(env.ClientHome); env.BypassProxy = true;
            var plan = ClientLauncher.Build(env, id, "gpt-5.4", DemoApi.Models, DemoApi.Key, env.ClientHome, "terminal", true);
            if (id == "codex") plan.Session.Variables["CODEX_HOME"] = plan.Directory;
            plan.Session.Arguments = System.Linq.Enumerable.ToArray(System.Linq.Enumerable.Concat(plan.Session.Arguments, id == "codex" ? new[] { "features", "list" } : new[] { "inspect" }));
            plan.Session.CloseOnExit = true;
            await ClientLauncher.Start(plan, "terminal", runner);
            var exitFile = Path.Combine(plan.Directory, "exited.txt");
            for (var i = 0; i < 300 && !File.Exists(exitFile); i++) await Task.Delay(100);
            Check(File.Exists(exitFile) && File.ReadAllText(exitFile) == "0", id + " did not exit successfully in Terminal");
            Console.WriteLine(id + ": actual installed CLI in Windows Terminal completed read-only command; isolated config, fixture key, no model prompt");
        }
        return 0;
    }
}
