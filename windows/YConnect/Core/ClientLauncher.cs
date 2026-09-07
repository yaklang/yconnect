using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using YConnect.Native;

namespace YConnect.Core
{
    public sealed class ClientLaunchPlan
    {
        public LaunchSession Session { get; set; }
        public string Directory { get; set; }
        public Dictionary<string, string> Files { get; } = new Dictionary<string, string>();
    }
    public static class ClientLauncher
    {
        public static bool Supported(string id) => new[] { "opencode", "codex", "claude-code", "pi", "grok-build", "hermes", "openclaw" }.Contains(id);
        public static bool CanAutoStart(string id) => Supported(id) && id != "openclaw";
        public static string Runner => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "YConnect.Launcher.exe");
        public static ClientLaunchPlan Build(EnvironmentPaths env, string id, string model, AvailableModel[] models, string key, string directory, string terminal, bool autoStart)
        {
            if (!Supported(id)) throw new InvalidOperationException("此桌面客户端尚未提供独立终端会话，请使用配置预览");
            if (!new[] { "terminal", "powershell", "cmd" }.Contains(terminal)) throw new InvalidOperationException("请选择有效的终端");
            if (autoStart && !CanAutoStart(id)) throw new InvalidOperationException("OpenClaw 需先准备独立网关，请打开专用终端操作");
            key = YakCoolApi.ValidateKey(key);
            if (!Regex.IsMatch(model ?? "", @"\A[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,199}\z")) throw new InvalidOperationException("该模型 ID 无法安全传入客户端命令行");
            var client = ClientRegistry.All.First(c => c.Id == id);
            if (!client.Compatible(models).Any(m => m.Id == model)) throw new InvalidOperationException("请选择当前 Key 的可用模型");
            if (string.IsNullOrWhiteSpace(directory) || !Path.IsPathRooted(directory) || !System.IO.Directory.Exists(directory)) throw new InvalidOperationException("请选择已存在的完整工作目录");
            directory = SecureFiles.PhysicalPath(directory, false);
            if (terminal == "cmd" && directory.StartsWith(@"\\")) throw new InvalidOperationException("CMD 不支持 UNC 工作目录，请选择 PowerShell 或 Windows Terminal");
            var executable = ClientDetection.Resolve(id);
            if (executable != null) executable = SecureFiles.PhysicalPath(executable, false);
            if (executable == null && !env.Demo) throw new InvalidOperationException("未找到 " + client.Name + " 的可执行文件，请重新检测安装");
            var root = SecureFiles.PhysicalPath(Path.Combine(env.DataRoot, "LaunchSessions", Guid.NewGuid().ToString("N")));
            var session = new LaunchSession { Client = client.Name, Model = model, Executable = executable ?? client.Id + ".exe", WorkingDirectory = directory, Shell = terminal == "cmd" ? "cmd" : "powershell", AutoStart = autoStart };
            session.Variables["YCONNECT_API_KEY"] = key;
            session.Variables["YCONNECT_MODEL"] = model;
            session.Variables["YCONNECT_BASE_URL"] = YakCoolApi.Gateway + "/v1";
            if (env.BypassProxy) { foreach (var name in new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy" }) session.Variables[name] = ""; session.Variables["NO_PROXY"] = "*"; }
            var plan = new ClientLaunchPlan { Session = session, Directory = root };
            Action<string, JObject> addJson = (name, content) => plan.Files.Add(Path.Combine(root, name), Json.Stringify(content));
            var available = client.Compatible(models).ToArray();
            var entries = new JArray(available.Select(m => new JObject { ["id"] = m.Id, ["name"] = m.Name }));
            var helper = "\"" + Runner + "\" --key";
            switch (id)
            {
                case "codex":
                    // A unique provider ID prevents a stored helper/auth block from winning the merge.
                    var provider = "yconnect_" + Path.GetFileName(root);
                    session.Arguments = new[] { "-m", model, "-c", "model_provider=" + provider, "-c", "model_providers." + provider + ".name=YAKCOOL", "-c", "model_providers." + provider + ".base_url=" + YakCoolApi.Gateway + "/v1", "-c", "model_providers." + provider + ".wire_api=responses", "-c", "model_providers." + provider + ".env_key=YCONNECT_API_KEY" };
                    break;
                case "opencode":
                    session.Variables["OPENCODE_CONFIG_CONTENT"] = new JObject { ["model"] = "yakcool/" + model, ["provider"] = new JObject { ["yakcool"] = new JObject { ["name"] = "YAKCOOL", ["npm"] = "@ai-sdk/openai-compatible", ["options"] = new JObject { ["baseURL"] = YakCoolApi.Gateway + "/v1", ["apiKey"] = "{env:YCONNECT_API_KEY}" }, ["models"] = new JObject(available.Select(m => new JProperty(m.Id, new JObject { ["name"] = m.Name }))) } } }.ToString(Newtonsoft.Json.Formatting.None);
                    session.Arguments = new[] { "--model", "yakcool/" + model }; break;
                case "claude-code":
                    var claudeEnv = new JObject { ["ANTHROPIC_BASE_URL"] = YakCoolApi.Gateway, ["ANTHROPIC_API_KEY"] = "", ["ANTHROPIC_AUTH_TOKEN"] = "", ["ANTHROPIC_MODEL"] = model, ["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model, ["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model, ["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = model, ["CLAUDE_CODE_USE_BEDROCK"] = "0", ["CLAUDE_CODE_USE_VERTEX"] = "0", ["CLAUDE_CODE_USE_FOUNDRY"] = "0" };
                    addJson("claude-session.json", new JObject { ["env"] = claudeEnv, ["model"] = model, ["apiKeyHelper"] = helper });
                    session.RemoveVariables = new[] { "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR" };
                    foreach (var property in claudeEnv.Properties()) session.Variables[property.Name] = (string)property.Value;
                    session.Arguments = new[] { "--settings", Path.Combine(root, "claude-session.json"), "--model", model }; break;
                case "pi":
                    session.Variables["PI_CODING_AGENT_DIR"] = root;
                    addJson("models.json", new JObject { ["providers"] = new JObject { ["yakcool"] = new JObject { ["baseUrl"] = YakCoolApi.Gateway + "/v1", ["api"] = "openai-completions", ["apiKey"] = "!" + helper, ["models"] = entries } } });
                    session.Arguments = new[] { "--provider", "yakcool", "--model", model }; break;
                case "grok-build":
                    session.Variables["GROK_HOME"] = root;
                    plan.Files.Add(Path.Combine(root, "config.toml"), "[models]\ndefault = \"yakcool\"\n[model.yakcool]\nname = \"YAKCOOL\"\nmodel = " + JToken.FromObject(model).ToString(Newtonsoft.Json.Formatting.None) + "\nbase_url = \"" + YakCoolApi.Gateway + "/v1\"\napi_backend = \"chat_completions\"\nenv_key = \"YCONNECT_API_KEY\"\n");
                    session.Arguments = new[] { "--model", "yakcool" }; break;
                case "hermes":
                    session.Variables["HERMES_HOME"] = root; session.Variables["OPENAI_API_KEY"] = key; session.Variables["OPENAI_BASE_URL"] = YakCoolApi.Gateway + "/v1";
                    plan.Files.Add(Path.Combine(root, "config.yaml"), "model:\n  provider: custom\n  default: " + JToken.FromObject(model).ToString(Newtonsoft.Json.Formatting.None) + "\n  base_url: \"" + YakCoolApi.Gateway + "/v1\"\n");
                    break;
                case "openclaw":
                    session.Variables["OPENCLAW_STATE_DIR"] = root; session.Variables["OPENCLAW_CONFIG_PATH"] = Path.Combine(root, "openclaw.json");
                    addJson("openclaw.json", new JObject { ["models"] = new JObject { ["mode"] = "merge", ["providers"] = new JObject { ["yakcool"] = new JObject { ["baseUrl"] = YakCoolApi.Gateway + "/v1", ["api"] = "openai-completions", ["apiKey"] = "${YCONNECT_API_KEY}", ["models"] = entries } } }, ["agents"] = new JObject { ["defaults"] = new JObject { ["workspace"] = directory, ["model"] = new JObject { ["primary"] = "yakcool/" + model } } } });
                    session.Arguments = new[] { "--help" }; break;
            }
            foreach (var file in plan.Files) { if (file.Value.Contains(key)) throw new InvalidOperationException("启动配置不得包含明文 Key"); ClientRegistry.Validate(file.Key, file.Value); }
            return plan;
        }
        public static async Task<string> Start(ClientLaunchPlan plan, string terminal, string runner = null, CancellationToken cancellation = default)
        {
            runner = runner ?? Runner;
            if (!Path.IsPathRooted(runner) || !File.Exists(runner)) throw new InvalidOperationException("启动器组件缺失，请重新安装完整 Y CONNECT 包");
            runner = SecureFiles.PhysicalPath(runner);
            var sessions = Path.GetDirectoryName(plan.Directory);
            if (Directory.Exists(sessions))
                foreach (var previous in Directory.GetDirectories(sessions).Where(path => Regex.IsMatch(Path.GetFileName(path), @"\A[a-f0-9]{32}\z")))
                    try { LaunchHandshake.DeleteExpired(Path.Combine(previous, "session.bin")); } catch { }
            SecureFiles.ProtectDirectory(plan.Directory);
            foreach (var file in plan.Files) SecureFiles.WriteText(file.Key, file.Value, true);
            var manifest = Path.Combine(plan.Directory, "session.bin"); SecureFiles.AtomicWrite(manifest, plan.Session.Protect(), true);
            // Terminal expands %NAME% in its command line. Pass the path as data,
            // not as a literal path that could be expanded a second time.
            manifest = SecureFiles.PhysicalPath(manifest);
            var handoff = "--session " + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(manifest));
            var info = new ProcessStartInfo(runner, handoff) { UseShellExecute = false, WorkingDirectory = plan.Session.WorkingDirectory };
            var wt = terminal == "terminal" ? ClientDetection.ResolveExecutable("wt") : null;
            if (wt != null)
            {
                info.FileName = wt;
                info.Arguments = "-w new new-tab -d " + LaunchSession.Quote(Environment.SystemDirectory) + " " + LaunchSession.Quote(runner) + " " + handoff;
            }
            _ = LaunchHandshake.ExpireLater(manifest);
            try
            {
                using (var watching = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
                {
                    // App execution aliases / console activation must never block WPF's STA.
                    var dispatch = Task.Run(() => { using (var process = Process.Start(info)) { } });
                    _ = dispatch.ContinueWith(task => { var ignored = task.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                    var ready = LaunchHandshake.WaitForReady(manifest, TimeSpan.FromSeconds(30), watching.Token);
                    try
                    {
                        if (await Task.WhenAny(dispatch, ready).ConfigureAwait(false) == dispatch) await dispatch.ConfigureAwait(false);
                        await ready.ConfigureAwait(false);
                        return plan.Session.Client + (plan.Session.AutoStart ? " 已在新终端启动" : " 专用终端已就绪") + (terminal == "terminal" && wt == null ? "（本机未安装 Windows Terminal，已使用 PowerShell）" : "") + " · 原配置未修改";
                    }
                    finally { watching.Cancel(); }
                }
            }
            catch (System.ComponentModel.Win32Exception error) { throw new InvalidOperationException("Windows 无法打开终端（系统错误 " + error.NativeErrorCode + "），请重试或改选 PowerShell / CMD。"); }
        }
    }
}
