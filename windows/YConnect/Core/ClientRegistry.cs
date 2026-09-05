using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    public sealed class AvailableModel
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string[] Protocols { get; set; } = new string[0];
        public override string ToString() => Name + "  ·  " + Id;
    }
    public sealed class ClientDescriptor
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Mark { get; set; }
        public string Description { get; set; }
        public string[] Protocols { get; set; }
        public bool ClaudeOnly { get; set; }
        public bool Bridge => Protocols.Length == 0;
        public IEnumerable<AvailableModel> Compatible(IEnumerable<AvailableModel> models) => models.Where(m => Protocols.Any(m.Protocols.Contains) && (!ClaudeOnly || System.Text.RegularExpressions.Regex.IsMatch(m.Id, @"(^|[/_.-])claude", System.Text.RegularExpressions.RegexOptions.IgnoreCase)));
    }
    public sealed class ClientStatus
    {
        public string State { get; set; } = "notConfigured";
        public bool HasBackup { get; set; }
        public string Issue { get; set; }
    }
    public sealed class ClientRegistry
    {
        public static readonly ClientDescriptor[] All =
        {
            new ClientDescriptor { Id="opencode", Name="OpenCode", Mark=">_", Description="开源 AI 编程助手", Protocols=new[]{"chat_completions"} },
            new ClientDescriptor { Id="codex", Name="Codex", Mark="◇", Description="OpenAI 编程智能体", Protocols=new[]{"responses"} },
            new ClientDescriptor { Id="claude-code", Name="Claude Code", Mark="✳", Description="Anthropic 终端助手", Protocols=new[]{"anthropic_messages"} },
            new ClientDescriptor { Id="claude-desktop", Name="Claude Desktop", Mark="▣", Description="Claude 第三方推理版", Protocols=new[]{"anthropic_messages"}, ClaudeOnly=true },
            new ClientDescriptor { Id="pi", Name="Pi", Mark="π", Description="轻量级编程智能体", Protocols=YakCoolApi.Protocols },
            new ClientDescriptor { Id="grok-build", Name="Grok Build", Mark="G", Description="xAI 编程工作台", Protocols=YakCoolApi.Protocols },
            new ClientDescriptor { Id="openclaw", Name="OpenClaw", Mark="⌘", Description="个人 AI 助手", Protocols=YakCoolApi.Protocols },
            new ClientDescriptor { Id="hermes", Name="Hermes", Mark="H", Description="Nous Research 智能体", Protocols=YakCoolApi.Protocols },
            new ClientDescriptor { Id="gemini-cli", Name="Gemini CLI", Mark="✦", Description="需要 Gemini 协议桥", Protocols=new string[0] },
        };
        private const string ProfileId = "9d254f75-6d3a-4b8c-a0e8-4d3a4f4d42f7";
        public EnvironmentPaths Environment { get; }
        public Transactions Transactions { get; }
        private readonly byte[] helper;
        public ClientRegistry(EnvironmentPaths env)
        {
            Environment = env; Transactions = new Transactions(env);
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("YConnect.CredentialReader.exe"))
            using (var buffer = new MemoryStream()) { stream.CopyTo(buffer); helper = buffer.ToArray(); }
        }
        public ClientDescriptor Get(string id) => All.FirstOrDefault(c => c.Id == id) ?? throw new InvalidOperationException("未知客户端");
        public string[] Paths(string id)
        {
            Get(id); var env = Environment;
            switch (id)
            {
                case "opencode": return new[] { Path.Combine(env.RootOverride("XDG_CONFIG_HOME", env.HomePath(".config")), "opencode", "opencode.json") };
                case "codex": return new[] { Path.Combine(env.RootOverride("CODEX_HOME", env.HomePath(".codex")), "config.toml") };
                case "claude-code": return new[] { Path.Combine(env.RootOverride("CLAUDE_CONFIG_DIR", env.HomePath(".claude")), "settings.json") };
                case "pi": return new[] { env.HomePath(".pi", "agent", "models.json"), env.HomePath(".pi", "agent", "settings.json") };
                case "grok-build": return new[] { env.HomePath(".grok", "config.toml") };
                case "claude-desktop": return new[] { Path.Combine(env.LocalAppData, "Claude-3p", "configLibrary", ProfileId + ".json"), Path.Combine(env.LocalAppData, "Claude-3p", "configLibrary", "_meta.json") };
                case "openclaw": return new[] { env.HomePath(".openclaw", "openclaw.json") };
                case "hermes": return new[] { env.HomePath(".hermes", "config.yaml") };
                default: return new string[0];
            }
        }
        public bool Installed(string id)
        {
            return Native.ClientDetection.Installed(Environment, id);
        }
        public ClientDescriptor[] InstalledClients(IEnumerable<string> recent) => recent.Concat(All.Select(c => c.Id)).Distinct().Select(id => All.FirstOrDefault(c => c.Id == id)).Where(c => c != null && Installed(c.Id)).ToArray();
        public ClientStatus Inspect(string id)
        {
            var result = new ClientStatus();
            try
            {
                foreach (var file in Paths(id)) if (SecureFiles.ReadText(file) is string text) Validate(file, text);
                var latest = Transactions.Latest(id); result.HasBackup = latest != null;
                if (latest != null) result.State = latest.Array("files").All(f => SecureFiles.Hash(SecureFiles.Read(f.Text("path"))) == f.Text("afterHash", null)) ? "configured" : "drifted";
            }
            catch { result.State = "invalid"; result.Issue = "配置格式或文件路径异常，检查后再应用"; }
            return result;
        }
        private static JObject ReadObject(string file) => SecureFiles.ReadText(file) is string text ? Json.Parse(text) : new JObject();
        private static JObject Child(JObject parent, string key) { var child = Json.Object(parent[key], key); parent[key] = child; return child; }
        private static string Endpoint(string protocol) => YakCoolApi.Gateway + (protocol == "anthropic_messages" ? "" : "/v1");
        private static string ApiName(string protocol) => protocol == "responses" ? "openai-responses" : protocol == "anthropic_messages" ? "anthropic-messages" : "openai-completions";
        public static void Validate(string file, string text)
        {
            if (file.EndsWith(".toml")) ConfigurationEditors.ValidateToml(text);
            else if (file.EndsWith(".yaml")) ConfigurationEditors.ValidateYaml(text);
            else Json.Parse(text);
        }
        public ConfigurationPlan Build(string id, string modelId, IEnumerable<AvailableModel> models, string key)
        {
            var descriptor = Get(id); YakCoolApi.ValidateKey(key); YakCoolApi.ValidateModel(modelId);
            if (descriptor.Bridge) throw new InvalidOperationException("Gemini CLI 需要 generateContent 协议桥，当前不能直接应用");
            var available = descriptor.Compatible(models).ToArray();
            var selected = available.FirstOrDefault(m => m.Id == modelId) ?? throw new InvalidOperationException("模型不支持此客户端的原生协议");
            var protocol = descriptor.Protocols.First(selected.Protocols.Contains);
            var eligible = new[] { selected }.Concat(available.Where(m => m.Id != selected.Id && m.Protocols.Contains(protocol))).ToArray();
            foreach (var model in eligible) YakCoolApi.ValidateModel(model.Id);
            var files = Paths(id); var secret = Environment.Secret(id); var helperPath = Environment.Helper(id); var command = "\"" + helperPath + "\"";
            var plan = new ConfigurationPlan { Client = id }; plan.Add(secret, key, "credential");
            if (id != "opencode" && id != "openclaw") plan.Add(helperPath, helper, "helper");
            Action<string, JObject> add = (file, root) => plan.Add(file, Json.Stringify(root));
            var modelEntries = new JArray(eligible.Select(m => new JObject { ["id"] = m.Id, ["name"] = m.Name }));
            switch (id)
            {
                case "opencode":
                    {
                        var root = ReadObject(files[0]); var provider = Child(Child(root, "provider"), "yakcool");
                        provider["name"] = "YakCool"; provider["npm"] = "@ai-sdk/openai-compatible";
                        provider["options"] = new JObject { ["baseURL"] = YakCoolApi.Gateway + "/v1", ["apiKey"] = "{file:" + secret.Replace('\\', '/') + "}" };
                        provider["models"] = new JObject(eligible.Select(m => new JProperty(m.Id, new JObject { ["name"] = m.Name })));
                        root["model"] = "yakcool/" + modelId; root["$schema"] = root["$schema"] ?? "https://opencode.ai/config.json"; add(files[0], root); break;
                    }
                case "pi":
                    {
                        var root = ReadObject(files[0]); var settings = ReadObject(files[1]);
                        Child(root, "providers")["yakcool"] = new JObject { ["baseUrl"] = Endpoint(protocol), ["api"] = ApiName(protocol), ["apiKey"] = "!" + command, ["models"] = modelEntries };
                        settings["defaultProvider"] = "yakcool"; settings["defaultModel"] = modelId; add(files[0], root); add(files[1], settings); break;
                    }
                case "claude-code":
                    {
                        var root = ReadObject(files[0]); var env = Child(root, "env");
                        foreach (var k in new[] { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY" }) env.Remove(k);
                        env["ANTHROPIC_BASE_URL"] = YakCoolApi.Gateway; env["ANTHROPIC_MODEL"] = modelId; root["model"] = modelId; root["apiKeyHelper"] = command; add(files[0], root); break;
                    }
                case "codex":
                    {
                        plan.Add(files[0], ConfigurationEditors.EditToml(SecureFiles.ReadText(files[0]), new JObject { ["model"] = modelId, ["model_provider"] = "yakcool" }, new Dictionary<string, JObject>
                        {
                            ["model_providers.yakcool"] = new JObject { ["name"] = "YakCool", ["base_url"] = YakCoolApi.Gateway + "/v1", ["wire_api"] = "responses" },
                            ["model_providers.yakcool.auth"] = new JObject { ["command"] = helperPath, ["args"] = new JArray(), ["timeout_ms"] = 5000, ["refresh_interval_ms"] = 300000 },
                        })); break;
                    }
                case "grok-build":
                    {
                        var source = SecureFiles.ReadText(files[0]) ?? ""; var parsed = Tomlyn.Toml.ToModel(source);
                        var defaults = parsed.TryGetValue("models", out var current) ? JObject.FromObject(current) : new JObject(); defaults["default"] = "yakcool";
                        plan.Add(files[0], ConfigurationEditors.EditToml(source, new JObject(), new Dictionary<string, JObject>
                        {
                            ["models"] = defaults,
                            ["model.yakcool"] = new JObject { ["model"] = modelId, ["base_url"] = YakCoolApi.Gateway + "/v1", ["name"] = "YakCool · " + selected.Name, ["api_backend"] = protocol == "anthropic_messages" ? "messages" : protocol, ["auth_provider"] = "yconnect" },
                            ["auth_provider.yconnect"] = new JObject { ["command"] = helperPath, ["args"] = new JArray(), ["token_ttl_secs"] = 300, ["timeout_secs"] = 5 },
                        })); break;
                    }
                case "claude-desktop":
                    {
                        var root = ReadObject(files[0]); var meta = ReadObject(files[1]); root.Remove("inferenceGatewayApiKey");
                        root["inferenceProvider"] = "gateway"; root["inferenceGatewayBaseUrl"] = YakCoolApi.Gateway; root["inferenceGatewayAuthScheme"] = "bearer";
                        root["inferenceCredentialKind"] = "helper-script"; root["inferenceCredentialHelper"] = helperPath; root["inferenceCredentialHelperTtlSec"] = 300; root["inferenceCredentialHelperTimeoutSec"] = 5; root["inferenceCredentialHelperSilentRefreshEnabled"] = true;
                        root["inferenceModels"] = new JArray(eligible.Select(m => new JObject { ["name"] = m.Id, ["labelOverride"] = m.Name }));
                        if (meta["entries"] != null && !(meta["entries"] is JArray)) throw new InvalidOperationException("Claude Desktop 档案索引格式无效");
                        meta["entries"] = new JArray(meta.Array("entries").Where(e => e.Text("id") != ProfileId).Concat(new[] { new JObject { ["id"] = ProfileId, ["name"] = "YakCool · YConnect" } })); meta["appliedId"] = ProfileId;
                        add(files[0], root); add(files[1], meta); break;
                    }
                case "openclaw":
                    {
                        var root = ReadObject(files[0]); var rootModels = Child(root, "models"); rootModels["mode"] = "merge";
                        Child(rootModels, "providers")["yakcool"] = new JObject { ["baseUrl"] = Endpoint(protocol), ["api"] = ApiName(protocol), ["apiKey"] = new JObject { ["source"] = "file", ["provider"] = "yconnect", ["id"] = "value" }, ["models"] = modelEntries };
                        Child(Child(root, "secrets"), "providers")["yconnect"] = new JObject { ["source"] = "file", ["path"] = secret, ["mode"] = "singleValue", ["timeoutMs"] = 5000 };
                        var defaults = Child(Child(root, "agents"), "defaults"); var model = defaults["model"] is JValue ? new JObject() : Json.Object(defaults["model"]); model["primary"] = "yakcool/" + modelId; defaults["model"] = model; add(files[0], root); break;
                    }
                case "hermes":
                    {
                        var source = SecureFiles.ReadText(files[0]) ?? "";
                        var transport = protocol == "responses" ? "codex_responses" : protocol;
                        var body = new[] { "api: " + JToken.FromObject(Endpoint(protocol)).ToString(Newtonsoft.Json.Formatting.None), "key_cmd: " + JToken.FromObject(command).ToString(Newtonsoft.Json.Formatting.None), "transport: " + transport, "default_model: " + JToken.FromObject(modelId).ToString(Newtonsoft.Json.Formatting.None), "models:" }.Concat(eligible.Select(m => "  " + JToken.FromObject(m.Id).ToString(Newtonsoft.Json.Formatting.None) + ": {}"));
                        source = ConfigurationEditors.SetYamlBlock(source, new[] { "providers", "yakcool" }, body.ToArray());
                        // Preserve other root model fields while changing only owned selectors.
                        var yaml = new YamlDotNet.RepresentationModel.YamlStream(); yaml.Load(new StringReader(source));
                        var root = (YamlDotNet.RepresentationModel.YamlMappingNode)yaml.Documents[0].RootNode;
                        var modelBody = new List<string>();
                        if (root.Children.TryGetValue(new YamlDotNet.RepresentationModel.YamlScalarNode("model"), out var old))
                        {
                            if (!(old is YamlDotNet.RepresentationModel.YamlMappingNode mapping)) throw new InvalidOperationException("Hermes model 必须是块映射");
                            foreach (var entry in mapping.Children.Where(e => e.Key.ToString() != "default" && e.Key.ToString() != "provider"))
                            {
                                if (!(entry.Value is YamlDotNet.RepresentationModel.YamlScalarNode)) throw new InvalidOperationException("Hermes model 含复杂扩展字段，请检查配置后再应用");
                                modelBody.Add(entry.Key + ": " + JToken.FromObject(entry.Value.ToString()).ToString(Newtonsoft.Json.Formatting.None));
                            }
                        }
                        modelBody.Add("provider: custom:yakcool"); modelBody.Add("default: " + JToken.FromObject(modelId).ToString(Newtonsoft.Json.Formatting.None));
                        plan.Add(files[0], ConfigurationEditors.SetYamlBlock(source, new[] { "model" }, modelBody.ToArray())); break;
                    }
            }
            foreach (var f in plan.Changes.Where(f => f.Role == "configuration"))
            {
                var text = System.Text.Encoding.UTF8.GetString(f.After);
                if (text.Contains(key)) throw new InvalidOperationException("生成配置包含明文业务 Key，已停止写入"); Validate(f.Path, text);
            }
            return plan;
        }
        public string Restore(string id) { Get(id); return Transactions.Restore(id, Paths(id).Concat(new[] { Environment.Secret(id), Environment.Helper(id) })); }
    }
}
