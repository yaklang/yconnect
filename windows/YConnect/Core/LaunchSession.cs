using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;

namespace YConnect.Core
{
    // Shared by the WPF app and the tiny console bootstrapper. Keys never enter shell text.
    public sealed class LaunchSession
    {
        public DateTime Created { get; set; } = DateTime.UtcNow;
        public string Client { get; set; }
        public string Model { get; set; }
        public string Executable { get; set; }
        public string[] Arguments { get; set; } = new string[0];
        public string WorkingDirectory { get; set; }
        public string Shell { get; set; } = "powershell";
        public bool AutoStart { get; set; }
        public bool CloseOnExit { get; set; }
        public Dictionary<string, string> Variables { get; set; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public string[] RemoveVariables { get; set; } = new string[0];
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("io.yaklang.yconnect.launch.v1");
        public byte[] Protect() => ProtectedData.Protect(Encoding.UTF8.GetBytes(JsonConvert.SerializeObject(this)), Entropy, DataProtectionScope.CurrentUser);
        public static LaunchSession Unprotect(byte[] bytes) => JsonConvert.DeserializeObject<LaunchSession>(Encoding.UTF8.GetString(ProtectedData.Unprotect(bytes, Entropy, DataProtectionScope.CurrentUser)));
        public static string Quote(string value)
        {
            // Windows CommandLineToArgvW / CRT quoting, including a trailing backslash.
            var result = new StringBuilder("\""); var slashes = 0;
            foreach (var ch in value ?? "")
            {
                if (ch == '\\') { slashes++; continue; }
                result.Append('\\', ch == '"' ? slashes * 2 + 1 : slashes); slashes = 0; result.Append(ch);
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }
        public static string PowerShellLiteral(string value) => "'" + (value ?? "").Replace("'", "''") + "'";
        public static string Encoded(string script) => Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        public ProcessStartInfo ClientStartInfo()
        {
            if (!File.Exists(Executable)) throw new FileNotFoundException("客户端程序已移动或卸载，请重新检测");
            if (!Directory.Exists(WorkingDirectory)) throw new DirectoryNotFoundException("工作目录不存在");
            var info = new ProcessStartInfo(Executable, string.Join(" ", Arguments.Select(Quote))) { UseShellExecute = false, WorkingDirectory = WorkingDirectory };
            if (Executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || Executable.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
            {
                if (Arguments.Any(value => value.Any(ch => ch == '"' || ch == '\r' || ch == '\n'))) throw new InvalidOperationException("此批处理入口不支持包含引号或换行的参数");
                info.FileName = Path.Combine(Environment.SystemDirectory, "cmd.exe");
                info.EnvironmentVariables["YCONNECT_CLIENT_EXECUTABLE"] = Executable;
                var references = new List<string>();
                for (var i = 0; i < Arguments.Length; i++) { var name = "YCONNECT_CLIENT_ARG_" + i; info.EnvironmentVariables[name] = Arguments[i]; references.Add("\"%" + name + "%\""); }
                // Expand path/arguments once from the environment, with delayed expansion disabled.
                // Never CALL a batch shim: CALL would expand percent signs a second time.
                info.Arguments = "/d /v:off /s /c \"\"%YCONNECT_CLIENT_EXECUTABLE%\" " + string.Join(" ", references) + "\"";
            }
            else if (!Executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                // npm .cmd and PowerShell shims: data is quoted as literals, never concatenated as code.
                info.FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
                info.Arguments = "-NoLogo -NoProfile -EncodedCommand " + Encoded("& " + PowerShellLiteral(Executable) + " " + string.Join(" ", Arguments.Select(PowerShellLiteral)) + "; exit $LASTEXITCODE");
            }
            foreach (var name in RemoveVariables) info.EnvironmentVariables.Remove(name);
            foreach (var pair in Variables) info.EnvironmentVariables[pair.Key] = pair.Value;
            return info;
        }
    }
}
