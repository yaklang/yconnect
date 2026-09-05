using System;
using System.IO;
using System.Linq;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    public sealed class EnvironmentPaths
    {
        public bool Development { get; }
        public bool Demo { get; }
        public bool BypassProxy { get; set; }
        private string[] previewClients;
        public string[] PreviewClients => previewClients ?? ClientRegistry.All.Where(c => !c.Bridge).Select(c => c.Id).ToArray();
        public void SetPreviewClients(params string[] ids) { if (!Development) throw new InvalidOperationException("安装列表替身仅允许在隔离环境使用"); previewClients = ids; }
        public string DataRoot { get; }
        public string ClientHome { get; }
        public string LocalAppData { get; }
        public EnvironmentPaths(bool development = false, bool demo = false, string testRoot = null)
        {
            Development = development || demo || testRoot != null; Demo = demo;
            DataRoot = testRoot ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), demo ? "YConnectDemo" : Development ? "YConnectDev" : "YConnect");
            ClientHome = Development ? Path.Combine(DataRoot, "ClientSandbox", "Home") : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            LocalAppData = Development ? Path.Combine(DataRoot, "ClientSandbox", "LocalAppData") : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        }
        public string HomePath(params string[] parts)
        {
            var result = ClientHome; foreach (var p in parts) result = Path.Combine(result, p); return result;
        }
        public string RootOverride(string variable, string fallback) => Development ? fallback : Environment.GetEnvironmentVariable(variable) ?? fallback;
        public string Secret(string id) => Path.Combine(DataRoot, "Secrets", id + "-yakcool-key");
        public string Helper(string id) => Path.Combine(DataRoot, "Secrets", id + ".exe");
    }
    public sealed class Preferences
    {
        public bool EdgeEnabled { get; set; } = true;
        public bool OnLeft { get; set; }
        public double YPercent { get; set; } = 58;
        public bool Pinned { get; set; }
        public bool SidebarCollapsed { get; set; }
        public bool AnimationsEnabled { get; set; } = true;
        public bool BalancePeekEnabled { get; set; } = true;
        public bool PeekPercentageOnly { get; set; }
        public bool? StartupChoice { get; set; }
        public int StartupPolicyVersion { get; set; } = 1;
        public string Theme { get; set; } = "light";
        public bool BypassProxy { get; set; }
        public string SelectedClient { get; set; } = "opencode";
        public long? SelectedKey { get; set; }
        public JObject SelectedModels { get; set; } = new JObject();
        public string[] RecentClients { get; set; } = new string[0];
        public string[] RecentModels { get; set; } = new string[0];
        public string CurrentModel { get; set; }
    }
    public static class Json
    {
        public static string Text(this JToken token, string key, string fallback = "") => token?[key]?.Type == JTokenType.Null ? fallback : (string)token?[key] ?? fallback;
        public static double Number(this JToken token, string key, double fallback = 0) => double.TryParse(token?.Text(key), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var value) ? value : fallback;
        public static bool Flag(this JToken token, string key, bool fallback = false) => token?[key]?.Type == JTokenType.Boolean ? (bool)token[key] : fallback;
        public static JArray Array(this JToken token, string key) => token?[key] as JArray ?? new JArray();
        public static JObject Object(JToken value, string label = "配置")
        {
            if (value == null) return new JObject();
            if (value is JObject obj) return obj;
            throw new InvalidOperationException(label + "必须是对象");
        }
        public static JObject Parse(string text)
        {
            using (var reader = new Newtonsoft.Json.JsonTextReader(new StringReader(text)) { MaxDepth = 64, DateParseHandling = Newtonsoft.Json.DateParseHandling.None })
            {
                var result = JObject.Load(reader, new JsonLoadSettings { DuplicatePropertyNameHandling = DuplicatePropertyNameHandling.Error });
                if (reader.Read()) throw new InvalidOperationException("配置包含额外 JSON 内容");
                return result;
            }
        }
        public static string Stringify(JToken value) => value.ToString(Newtonsoft.Json.Formatting.Indented) + "\n";
    }
}
