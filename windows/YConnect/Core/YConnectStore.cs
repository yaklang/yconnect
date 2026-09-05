using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    public sealed class ServiceCheck
    {
        public string Title { get; set; }
        public string State { get; set; } = "pending";
        public string Detail { get; set; }
        public long Milliseconds { get; set; }
    }
    public sealed class YConnectStore
    {
        public event Action Changed;
        public EnvironmentPaths Environment { get; }
        public ClientRegistry Clients { get; }
        public IYakCoolApi Api { get; }
        public Preferences Preferences { get; private set; } = new Preferences();
        public string Mode { get; private set; } = "signedOut";
        public bool Busy { get; private set; }
        public bool CanRetrySession { get; private set; }
        public string Error { get; private set; }
        public string Message { get; private set; }
        public string Warning { get; private set; }
        public JObject Dashboard { get; private set; }
        public JObject Account { get; private set; }
        public JObject KeyInfo { get; private set; }
        public JArray Keys { get; private set; } = new JArray();
        public JArray Catalog { get; private set; } = new JArray();
        public List<AvailableModel> Models { get; private set; } = new List<AvailableModel>();
        public List<ServiceCheck> Checks { get; private set; } = new List<ServiceCheck>();
        public DateTime? LastRefresh { get; private set; }
        private string standaloneKey, cookie, previewKey;
        private ConfigurationPlan preview;
        public bool Authenticated => Mode == "account" || Mode == "apiKey";
        public string CurrentKey => Mode == "apiKey" ? standaloneKey : Keys.FirstOrDefault(k => (long?)k["id"] == Preferences.SelectedKey && k.Flag("active"))?.Text("api_key");
        public string DisplayName => Mode == "account" ? Dashboard?["user"].Text("display_name", "YakCool 账户") : Mode == "apiKey" ? KeyInfo?["key"].Text("label", "API Key") : "连接你的 YakCool";
        public double? Remaining => Dashboard?["ai_service_credit"]?["token_remaining"] != null ? Dashboard["ai_service_credit"].Number("token_remaining") / Math.Max(1, Dashboard["ai_service_credit"].Number("weighted_tokens_per_rmb", 10000000)) : (double?)null;
        public string SelectedModel => Preferences.SelectedModels.Text(Preferences.SelectedClient);
        public YConnectStore(EnvironmentPaths env, IYakCoolApi api)
        {
            Environment = env; Api = api; Clients = new ClientRegistry(env);
            try
            {
                var text = SecureFiles.ReadText(Path.Combine(env.DataRoot, "preferences.json"));
                if (text != null) Preferences = JsonConvert.DeserializeObject<Preferences>(text) ?? new Preferences();
                Clients.Get(Preferences.SelectedClient); Preferences.SelectedModels = Preferences.SelectedModels ?? new JObject();
                Preferences.RecentClients = Preferences.RecentClients ?? new string[0]; Preferences.RecentModels = Preferences.RecentModels ?? new string[0];
                Preferences.YPercent = Math.Max(2, Math.Min(98, Preferences.YPercent));
            }
            catch { Preferences = new Preferences(); Warning = "偏好设置无法读取，已使用默认设置"; }
        }
        public void Notify() => Changed?.Invoke();
        public void SetMessage(string message) { Message = message; Error = null; Notify(); }
        public void SetError(string message) { Error = YakCoolApi.Redact(message, CurrentKey, cookie); Notify(); }
        public void SavePreferences() { SecureFiles.WriteText(Path.Combine(Environment.DataRoot, "preferences.json"), JsonConvert.SerializeObject(Preferences, Formatting.Indented)); Notify(); }
        public async Task<bool> Run(Func<Task> operation)
        {
            if (Busy) return false;
            Busy = true; Error = null; Message = null; Notify();
            try { await operation(); return true; }
            catch (Exception e) { Error = YakCoolApi.Redact(e.Message, CurrentKey, cookie); return false; }
            finally { Busy = false; Notify(); }
        }
        public string RequireKey() => !string.IsNullOrEmpty(CurrentKey) ? CurrentKey : throw new InvalidOperationException("请先连接 API Key 或选择有效的账户 Key");
        private string RequireAccount() => Mode == "account" && cookie != null ? cookie : throw new InvalidOperationException("此功能需要 YakCool 账户登录，API Key 模式没有账户管理权限");
        public static List<AvailableModel> NormalizeModels(JToken data)
        {
            if (!(data is JArray array)) throw new InvalidOperationException("模型列表格式无效");
            var models = new List<AvailableModel>();
            foreach (var entry in array)
            {
                var id = YakCoolApi.ValidateModel(entry.Text("id"));
                if (!(entry["protocols"] is JArray protocols)) throw new InvalidOperationException("模型能力数据格式无效");
                var names = protocols.Values<string>().Where(p => p != null).Select(p => p.Trim().ToLowerInvariant()).Distinct().ToArray();
                var existing = models.FirstOrDefault(m => m.Id == id);
                if (existing != null) existing.Protocols = existing.Protocols.Concat(names).Distinct().ToArray();
                else models.Add(new AvailableModel { Id = id, Name = entry.Text("name", id), Protocols = names });
            }
            return models;
        }
        public async Task RestoreSession()
        {
            try
            {
                var auth = SecureFiles.LoadSession(Environment); if (auth == null) return;
                Mode = "restoring"; Notify();
                if (auth.Text("mode") == "account") await LoginAccount(auth.Text("cookie"), false); else await LoginKey(auth.Text("key"), false);
            }
            catch (Exception e)
            {
                ResetAuthentication(); CanRetrySession = !(e is ApiRequestException expired && expired.StatusCode == 401);
                if (!CanRetrySession) SecureFiles.ClearSession(Environment);
                Error = CanRetrySession ? "暂时无法恢复登录，可在网络恢复后重试。" + YakCoolApi.Redact(e.Message) : "登录已过期，请重新连接。";
            }
            finally { Notify(); }
        }
        public async Task LoginKey(string raw, bool persist = true)
        {
            var key = YakCoolApi.ValidateKey(raw);
            var requests = new[] { Api.Get("/api/key/info", key: key), Api.Get("/api/key/models", key: key) };
            var results = await Task.WhenAll(requests); var info = results[0]; var models = NormalizeModels(results[1]["data"]);
            if (!(info["key"] is JObject) || !(info["quota"] is JObject)) throw new InvalidOperationException("Key 状态数据无效");
            if (persist) SecureFiles.SaveSession(Environment, new JObject { ["mode"] = "apiKey", ["key"] = key });
            Mode = "apiKey"; CanRetrySession = false; standaloneKey = key; cookie = null; KeyInfo = info; Models = models; Dashboard = null; Account = null; Keys = new JArray(); Catalog = new JArray(); preview = null; Warning = null;
            ChooseModel(); LastRefresh = DateTime.Now; Message = "API Key 已安全连接";
        }
        public async Task LoginAccount(string value, bool persist = true)
        {
            YakCoolApi.ValidateCookie(value);
            var me = await Api.Get("/api/auth/me", cookie: value);
            if (me.Flag("staff_session")) throw new InvalidOperationException("只接受 YakCool 公开用户会话");
            if (!(me["user"] is JObject)) throw new ApiRequestException(401, "公开用户会话已过期，请重新扫码");
            var data = await FetchAccount(value);
            if (persist) SecureFiles.SaveSession(Environment, new JObject { ["mode"] = "account", ["cookie"] = value });
            cookie = value; standaloneKey = null; Mode = "account"; CanRetrySession = false; KeyInfo = null; InstallAccount(data); preview = null;
            await LoadSelectedModels(); Message = "YakCool 账户已安全连接";
        }
        private async Task<JObject[]> FetchAccount(string session)
        {
            var results = await Task.WhenAll(new[] { "/api/user/dashboard", "/api/user/account", "/api/user/api-keys", "/api/user/models" }.Select(p => Api.Get(p, cookie: session)));
            if (!(results[0]["user"] is JObject) || !(results[2]["keys"] is JArray) || !(results[3]["models"] is JArray)) throw new InvalidOperationException("账户数据格式无效");
            YakCoolApi.ValidateGateway(results[0].Text("gateway_url", YakCoolApi.Gateway)); return results;
        }
        private void InstallAccount(JObject[] data)
        {
            Dashboard = data[0]; Account = data[1]; Keys = data[2].Array("keys"); Catalog = data[3].Array("models");
            var selected = Keys.FirstOrDefault(k => k.Flag("active") && (long?)k["id"] == Preferences.SelectedKey) ?? Keys.FirstOrDefault(k => k.Flag("active"));
            Preferences.SelectedKey = (long?)selected?["id"]; LastRefresh = DateTime.Now;
        }
        private async Task LoadSelectedModels()
        {
            Models.Clear(); Warning = null; if (string.IsNullOrEmpty(CurrentKey)) return;
            try { Models = NormalizeModels((await Api.Get("/api/key/models", key: CurrentKey))["data"]); ChooseModel(); }
            catch { Warning = "账户已连接，当前 Key 的协议列表暂不可用。刷新后再配置客户端。"; }
        }
        public async Task Refresh()
        {
            try
            {
                if (Mode == "apiKey") await LoginKey(standaloneKey, false);
                else if (Mode == "account") { InstallAccount(await FetchAccount(cookie)); await LoadSelectedModels(); }
                Message = "信息已刷新";
            }
            catch (ApiRequestException e) when (e.StatusCode == 401) { SecureFiles.ClearSession(Environment); ResetAuthentication(); throw new InvalidOperationException("登录已过期，请重新连接。"); }
        }
        public async Task SignOut()
        {
            if (Mode == "account") try { await Api.Send("/api/auth/logout", "POST", null, cookie); } catch { }
            SecureFiles.ClearSession(Environment); ResetAuthentication(); Message = "已退出登录";
        }
        private void ResetAuthentication() { standaloneKey = null; cookie = null; Mode = "signedOut"; Dashboard = null; Account = null; KeyInfo = null; Keys.Clear(); Catalog.Clear(); Models.Clear(); Checks.Clear(); preview = null; previewKey = null; LastRefresh = null; Warning = null; CanRetrySession = false; }
        public async Task SelectKey(long id)
        {
            if (!Keys.Any(k => (long?)k["id"] == id && k.Flag("active"))) throw new InvalidOperationException("请选择有效的账户 Key");
            Preferences.SelectedKey = id; preview = null; await LoadSelectedModels(); SavePreferences();
        }
        public async Task CreateKey(string label)
        {
            if (label == null || !Regex.IsMatch(label.Trim(), @"\A[\p{L}\p{N} _.-]{1,40}\z")) throw new InvalidOperationException("名称限 1–40 个字母、数字、空格、下划线、点或连字符");
            var result = await Api.Send("/api/user/api-keys", "POST", new JObject { ["label"] = label.Trim() }, RequireAccount());
            Preferences.SelectedKey = (long?)result["key"]?["id"]; await Refresh(); Message = "API Key 已创建";
        }
        public async Task DeleteKey(long id)
        {
            if (id <= 0) throw new InvalidOperationException("Key ID 无效");
            await Api.Send("/api/user/api-keys/" + id, "DELETE", null, RequireAccount()); await Refresh(); Message = "API Key 已删除";
        }
        public async Task Redeem(string code)
        {
            code = code?.Replace(" ", "").Trim().ToUpperInvariant();
            if (code == null || !Regex.IsMatch(code, @"\A[A-Z0-9-]{12,64}\z")) throw new InvalidOperationException("兑换码应为 12–64 个字母、数字或连字符");
            var result = await Api.Send("/api/user/redeem", "POST", new JObject { ["code"] = code }, RequireAccount()); await Refresh();
            Message = result.Text("status") == "applied" ? "兑换成功" + (result["amount_cents"] != null ? "，到账 ¥" + (result.Number("amount_cents") / 100).ToString("F2") : "") : result.Text("message", "兑换正在处理");
        }
        public void SelectClient(string id) { Clients.Get(id); Preferences.SelectedClient = id; ChooseModel(); SavePreferences(); }
        public void SelectModel(string id)
        {
            if (!Clients.Get(Preferences.SelectedClient).Compatible(Models).Any(m => m.Id == id)) throw new InvalidOperationException("所选模型不兼容");
            Preferences.SelectedModels[Preferences.SelectedClient] = id; SavePreferences();
        }
        private void ChooseModel()
        {
            var valid = Clients.Get(Preferences.SelectedClient).Compatible(Models).ToArray();
            if (!valid.Any(m => m.Id == SelectedModel)) Preferences.SelectedModels[Preferences.SelectedClient] = valid.FirstOrDefault()?.Id ?? "";
        }
        public async Task<ConfigurationPlan> PreviewConfiguration()
        {
            var id = Preferences.SelectedClient; var model = SelectedModel; var key = RequireKey();
            preview = await Task.Run(() => Clients.Build(id, model, Models.ToArray(), key)); previewKey = key; return preview;
        }
        public async Task ApplyConfiguration(ConfigurationPlan plan)
        {
            if (preview != plan || previewKey != RequireKey()) throw new InvalidOperationException("请重新预览当前配置");
            Message = await Task.Run(() => Clients.Transactions.Apply(plan)); preview = null;
            Preferences.RecentClients = new[] { plan.Client }.Concat(Preferences.RecentClients.Where(id => id != plan.Client)).Take(4).ToArray(); SavePreferences();
        }
        public async Task RestoreConfiguration(string id) { Message = await Task.Run(() => Clients.Restore(id)); preview = null; }
        public async Task CheckConnection()
        {
            Checks = new List<ServiceCheck> { new ServiceCheck { Title = "YakCool 服务" }, new ServiceCheck { Title = "Key 权限" }, new ServiceCheck { Title = "模型与协议" } };
            Func<Task<string>>[] operations ={
                async()=>{var r=await Api.Get("/api/health");if(!new[]{"ok","healthy"}.Contains(r.Text("status")))throw new InvalidOperationException("服务状态异常");return "服务可达";},
                async()=>{var r=await Api.Get("/api/key/info",key:RequireKey());if(!new[]{"active","ok"}.Contains(r["key"].Text("status")))throw new InvalidOperationException("Key 未启用");return "Key 有效";},
                async()=>{Models=NormalizeModels((await Api.Get("/api/key/models",key:RequireKey()))["data"]);ChooseModel();return Models.Count+" 个模型可用";},
            };
            for (var i = 0; i < operations.Length; i++)
            {
                var item = Checks[i]; item.State = "running"; Notify(); var watch = System.Diagnostics.Stopwatch.StartNew();
                try { item.Detail = await operations[i](); item.State = "passed"; } catch (Exception e) { item.Detail = YakCoolApi.Redact(e.Message, CurrentKey); item.State = "failed"; }
                item.Milliseconds = watch.ElapsedMilliseconds; Notify();
            }
            Message = Checks.All(c => c.State == "passed") ? "基础检查通过，未调用付费模型" : "检查完成，请查看失败项目";
        }
        public async Task Probe(string model, string protocol, bool confirmed)
        {
            if (!confirmed) throw new InvalidOperationException("真实模型调用需要确认");
            if (!Models.Any(m => m.Id == model && m.Protocols.Contains(protocol))) throw new InvalidOperationException("所选模型或协议不可用");
            Message = "模型响应：" + await Api.Probe(RequireKey(), model, protocol);
        }
    }
}
