using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using Newtonsoft.Json;
using YConnect.Core;

internal static class Program
{
    private static int Main(string[] args)
    {
        string receipt = null, stage = "read-session";
        try
        {
            if (args.Length == 1 && args[0] == "--key") { Console.Write(Environment.GetEnvironmentVariable("YCONNECT_API_KEY") ?? ""); return 0; }
            if (args.Length == 1 && args[0] == "--ready") { LaunchHandshake.Ready(Environment.GetEnvironmentVariable("YCONNECT_LAUNCH_RECEIPT")); return 0; }
            if (args.Length == 1 && args[0] == "--run")
            {
                receipt = Environment.GetEnvironmentVariable("YCONNECT_LAUNCH_RECEIPT"); stage = "start-client";
                var value = Environment.GetEnvironmentVariable("YCONNECT_LAUNCH_COMMAND");
                var command = JsonConvert.DeserializeObject<LaunchSession>(value ?? throw new InvalidOperationException("请从 Y CONNECT 打开专用终端"));
                using (var child = Process.Start(command.ClientStartInfo()))
                {
                    if (receipt != null)
                    {
                        using (var current = Process.GetCurrentProcess()) LaunchHandshake.TrackProcess(receipt, "client-helper", current);
                        LaunchHandshake.TrackProcess(receipt, "client", child);
                    }
                    if (child.WaitForExit(350) && child.ExitCode != 0)
                    {
                        var failure = new LaunchFailure { Stage = "client-exit", Kind = "ExitCode", Code = child.ExitCode, Message = "客户端启动后立即退出，请查看终端中的客户端错误输出。" };
                        LaunchHandshake.Failed(receipt, failure); Console.Error.WriteLine(failure); return child.ExitCode;
                    }
                    LaunchHandshake.Ready(receipt); child.WaitForExit(); return child.ExitCode;
                }
            }
            if (args.Length == 2 && args[0] == "--session") args = new[] { Encoding.UTF8.GetString(Convert.FromBase64String(args[1])) };
            if (args.Length != 1) return 2;
            var manifest = Path.GetFullPath(args[0]);
            if (Path.GetFileName(manifest) != "session.bin") return 2;
            LaunchHandshake.AssertPlainPath(manifest); receipt = LaunchHandshake.Receipt(manifest);
            using (var current = Process.GetCurrentProcess()) LaunchHandshake.TrackProcess(receipt, "bootstrap", current);
            if (!File.Exists(manifest)) throw new FileNotFoundException();
            if (new FileInfo(manifest).Length > 1024 * 1024) throw new InvalidDataException();
            stage = "decrypt-session";
            var session = LaunchSession.Unprotect(File.ReadAllBytes(manifest));
            File.Delete(manifest); // one-use encrypted handoff, including when Terminal was already running
            stage = "check-session";
            if (session == null || DateTime.UtcNow - session.Created > LaunchHandshake.Lifetime || session.Created > DateTime.UtcNow.AddSeconds(10)) throw new InvalidOperationException();
            if (!Directory.Exists(session.WorkingDirectory)) throw new DirectoryNotFoundException();
            var runner = typeof(Program).Assembly.Location;
            var isCmd = session.Shell == "cmd";
            var info = new ProcessStartInfo(isCmd ? Path.Combine(Environment.SystemDirectory, "cmd.exe") : Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe")) { UseShellExecute = false, WorkingDirectory = session.WorkingDirectory, CreateNoWindow = session.CloseOnExit };
            foreach (var name in session.RemoveVariables) info.EnvironmentVariables.Remove(name);
            foreach (var pair in session.Variables) info.EnvironmentVariables[pair.Key] = pair.Value;
            session.Variables.Clear(); session.RemoveVariables = new string[0];
            info.EnvironmentVariables["YCONNECT_LAUNCH_COMMAND"] = JsonConvert.SerializeObject(session);
            info.EnvironmentVariables["YCONNECT_LAUNCHER"] = runner;
            info.EnvironmentVariables["YCONNECT_LAUNCH_RECEIPT"] = receipt;
            if (isCmd)
            {
                // Only fixed text and a quoted process environment variable enter cmd.
                var script = "title Y CONNECT - YAKCOOL & echo YAKCOOL session ready. Type yconnect to launch. & doskey yconnect=\"%YCONNECT_LAUNCHER%\" --run";
                if (session.AutoStart) script += " & \"%YCONNECT_LAUNCHER%\" --run";
                else script += " & \"%YCONNECT_LAUNCHER%\" --ready";
                info.Arguments = "/d /v:off " + (session.CloseOnExit ? "/c " : "/k ") + script;
            }
            else
            {
                var script = "$Host.UI.RawUI.WindowTitle = " + LaunchSession.PowerShellLiteral("Y CONNECT · " + session.Client) + "; function global:yconnect { & $env:YCONNECT_LAUNCHER --run }; Write-Host " + LaunchSession.PowerShellLiteral("YAKCOOL 已就绪 · " + session.Client + " · " + session.Model) + " -ForegroundColor Cyan; Write-Host '输入 yconnect 启动；退出客户端后可再次运行。此窗口使用独立连接。';";
                if (session.AutoStart) script += " yconnect";
                else script += " & $env:YCONNECT_LAUNCHER --ready";
                if (session.CloseOnExit) script += "; exit $LASTEXITCODE";
                // A GUI started from PowerShell 7 can inherit its module path. Windows
                // PowerShell 5.1 then hangs importing an incompatible PSReadLine before
                // the -NoExit startup command. Let this process rebuild its own defaults.
                // No user/machine environment or client configuration is changed.
                info.EnvironmentVariables.Remove("PSModulePath");
                info.Arguments = "-NoLogo -NoProfile " + (session.CloseOnExit ? "" : "-NoExit ") + "-EncodedCommand " + LaunchSession.Encoded(script);
            }
            stage = "start-shell";
            using (var shell = Process.Start(info))
            {
                LaunchHandshake.TrackProcess(receipt, "shell", shell);
                shell.WaitForExit();
                File.WriteAllText(Path.Combine(Path.GetDirectoryName(receipt), "exited.txt"), shell.ExitCode.ToString(System.Globalization.CultureInfo.InvariantCulture));
                // An interactive shell closing is the end of a session, not a
                // bootstrap failure. Preserve its code in the receipt, but allow
                // Terminal's default graceful-close policy to dismiss the tab.
                return session.CloseOnExit ? shell.ExitCode : 0;
            }
        }
        catch (Exception error)
        {
            // Never echo credentials, process environment, or a request payload on failure.
            var failure = LaunchFailure.From(error, stage);
            try { LaunchHandshake.Failed(receipt, failure); } catch { }
            Console.Error.WriteLine("Y CONNECT：" + failure); return 1;
        }
    }
}
