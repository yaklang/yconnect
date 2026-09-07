using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Threading;
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
    public sealed class ModelQualityCheck
    {
        public string Key { get; set; }
        public string Title { get; set; }
        public string Category { get; set; }
        public string State { get; set; } = "pending";
        public string Result { get; set; }
        public string Detail { get; set; }
        public string Output { get; set; }
        public string Reasoning { get; set; }
        public int ToolCalls { get; set; }
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
        public bool HadPreferencesFile { get; private set; }
        public bool LegacyStartupPreferences { get; private set; }
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
        public List<ModelQualityCheck> QualityChecks { get; private set; } = new List<ModelQualityCheck>();
        public string QualityModel { get; private set; }
        public string QualityProtocol { get; private set; }
        public ModelProbeResult LastProbe { get; private set; }
        public string LastProbeModel { get; private set; }
        public string LastProbeProtocol { get; private set; }
        private CancellationTokenSource testing;
        public bool CanCancelTest => testing != null && !testing.IsCancellationRequested;
        public void CancelTest() { testing?.Cancel(); Notify(); }
        public DateTime? LastRefresh { get; private set; }
        private string standaloneKey, cookie, previewKey;
        private ConfigurationPlan preview;
        public bool Authenticated => Mode == "account" || Mode == "apiKey";
        public string CurrentKey => Mode == "apiKey" ? standaloneKey : Keys.FirstOrDefault(k => (long?)k["id"] == Preferences.SelectedKey && k.Flag("active"))?.Text("api_key");
        public string DisplayName => Mode == "account" ? Dashboard?["user"].Text("display_name", "YAKCOOL 账户") : Mode == "apiKey" ? KeyInfo?["key"].Text("label", "API Key") : "连接你的 YAKCOOL";
        public double? Remaining => Dashboard?["ai_service_credit"]?["token_remaining"] != null && Dashboard["ai_service_credit"]["token_remaining"].Type != JTokenType.Null ? Dashboard["ai_service_credit"].Number("token_remaining") / Math.Max(1, Dashboard["ai_service_credit"].Number("weighted_tokens_per_rmb", 10000000)) : (double?)null;
        public string SelectedModel => Preferences.SelectedModels.Text(Preferences.SelectedClient);
        public YConnectStore(EnvironmentPaths env, IYakCoolApi api)
        {
            Environment = env; Api = api; Clients = new ClientRegistry(env);
            try
            {
                var text = SecureFiles.ReadText(Path.Combine(env.DataRoot, "preferences.json"));
                HadPreferencesFile = text != null;
                LegacyStartupPreferences = text != null && Json.Parse(text)["StartupPolicyVersion"] == null;
                if (text != null) Preferences = JsonConvert.DeserializeObject<Preferences>(text) ?? new Preferences();
                Clients.Get(Preferences.SelectedClient); Preferences.SelectedModels = Preferences.SelectedModels ?? new JObject();
                Preferences.RecentClients = Preferences.RecentClients ?? new string[0]; Preferences.RecentModels = Preferences.RecentModels ?? new string[0];
                Preferences.YPercent = Math.Max(2, Math.Min(98, Preferences.YPercent));
            }
            catch { Preferences = new Preferences(); Warning = "偏好设置无法读取，已使用默认设置"; }
        }
        public void Notify() => Changed?.Invoke();
        public void SetMessage(string message) { Message = message; Error = null; Notify(); }
        public void ClearMessage(string expected) { if (Message == expected) { Message = null; Notify(); } }
        public string SuggestedKeyName()
        {
            for (var i = 1; ; i++) { var value = "Y CONNECT-" + i; if (!Keys.Any(k => k.Text("label").Equals(value, StringComparison.OrdinalIgnoreCase))) return value; }
        }
        public void RememberModel(string id)
        {
            if (!Models.Any(m => m.Id == id)) throw new InvalidOperationException("当前 Key 无权使用此模型");
            Preferences.CurrentModel = id;
            Preferences.RecentModels = new[] { id }.Concat(Preferences.RecentModels.Where(m => m != id)).Take(8).ToArray();
            SavePreferences();
        }
        public AvailableModel[] FrequentModels => Preferences.RecentModels.Concat(Models.Select(m => m.Id)).Distinct().Select(id => Models.FirstOrDefault(m => m.Id == id)).Where(m => m != null).Take(3).ToArray();
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
        private string RequireAccount() => Mode == "account" && cookie != null ? cookie : throw new InvalidOperationException("此功能需要 YAKCOOL 账户登录，API Key 模式没有账户管理权限");
        public RechargeSession NewRechargeSession()
        {
            var session = RequireAccount();
            return new RechargeSession(Api, session, DisplayName, () => Mode == "account" && cookie == session);
        }
        public static List<AvailableModel> NormalizeModels(JToken data)
        {
            if (!(data is JArray array)) throw new InvalidOperationException("模型列表格式无效");
            var models = new List<AvailableModel>();
            foreach (var entry in array)
            {
                var id = YakCoolApi.ValidateModel(entry.Text("id"));
                if (!(entry["protocols"] is JArray protocols)) throw new InvalidOperationException("模型能力数据格式无效");
                var names = protocols.Values<string>().Where(p => p != null).Select(p => p.Trim().ToLowerInvariant()).Where(YakCoolApi.Protocols.Contains).Distinct().ToArray();
                if (names.Length == 0) continue;
                var existing = models.FirstOrDefault(m => m.Id == id);
                if (existing != null) existing.ReportedProtocols = existing.ReportedProtocols.Concat(names).Distinct().ToArray();
                else models.Add(new AvailableModel { Id = id, Name = entry.Text("name", id), ReportedProtocols = names, Protocols = YakCoolApi.Protocols.ToArray() });
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
            var changedConnection = Mode != "apiKey" || standaloneKey != key;
            var requests = new[] { Api.Get("/api/key/info", key: key), Api.Get("/api/key/models", key: key) };
            var results = await Task.WhenAll(requests); var info = results[0]; var models = NormalizeModels(results[1]["data"]);
            ValidateKeyInfo(info);
            if (persist) SecureFiles.SaveSession(Environment, new JObject { ["mode"] = "apiKey", ["key"] = key });
            Mode = "apiKey"; CanRetrySession = false; standaloneKey = key; cookie = null; KeyInfo = info; Models = models; Dashboard = null; Account = null; Keys = new JArray(); Catalog = new JArray(); preview = null; Warning = null;
            if (changedConnection) ClearChecks();
            ChooseModel(); LastRefresh = DateTime.Now; Message = "API Key 已安全连接";
        }
        public async Task LoginAccount(string value, bool persist = true)
        {
            YakCoolApi.ValidateCookie(value);
            var me = await Api.Get("/api/auth/me", cookie: value);
            if (me.Flag("staff_session")) throw new InvalidOperationException("只接受 YAKCOOL 公开用户会话");
            if (!(me["user"] is JObject)) throw new ApiRequestException(401, "公开用户会话已过期，请重新扫码");
            var data = await FetchAccount(value);
            if (persist) SecureFiles.SaveSession(Environment, new JObject { ["mode"] = "account", ["cookie"] = value });
            var changedConnection = Mode != "account" || cookie != value;
            cookie = value; standaloneKey = null; Mode = "account"; CanRetrySession = false; KeyInfo = null; InstallAccount(data); preview = null;
            if (changedConnection) ClearChecks();
            await LoadSelectedModels(); Message = "YAKCOOL 账户已安全连接";
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
            if (Preferences.SelectedKey != (long?)selected?["id"]) ClearChecks();
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
        private void ResetAuthentication() { standaloneKey = null; cookie = null; Mode = "signedOut"; Dashboard = null; Account = null; KeyInfo = null; Keys.Clear(); Catalog.Clear(); Models.Clear(); ClearChecks(); preview = null; previewKey = null; LastRefresh = null; Warning = null; CanRetrySession = false; }
        public async Task SelectKey(long id)
        {
            if (!Keys.Any(k => (long?)k["id"] == id && k.Flag("active"))) throw new InvalidOperationException("请选择有效的账户 Key");
            Preferences.SelectedKey = id; preview = null; ClearChecks(); await LoadSelectedModels(); SavePreferences();
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
            if (!Models.Any(m => m.Id == Preferences.CurrentModel)) Preferences.CurrentModel = FrequentModels.FirstOrDefault()?.Id;
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
            Error = Message = null;
            Checks = new List<ServiceCheck> { new ServiceCheck { Title = "YAKCOOL 服务" }, new ServiceCheck { Title = "Key 权限" }, new ServiceCheck { Title = "模型与协议" } };
            Func<Task<string>>[] operations ={
                async()=>{var r=await Api.Get("/api/health");if(!new[]{"ok","healthy"}.Contains(r.Text("status")))throw new InvalidOperationException("服务状态异常");return "服务可达";},
                async()=>{var r=await Api.Get("/api/key/info",key:RequireKey()); ValidateKeyInfo(r); KeyInfo=r; if(r["quota"].Flag("exhausted")) { Checks[1].State="warning"; return "Key 已启用，额度已用尽，请充值"; } return "Key 已启用 · "+r["quota"].Text("display", "额度可用");},
                async()=>{Models=NormalizeModels((await Api.Get("/api/key/models",key:RequireKey()))["data"]);ChooseModel();if(Models.Count==0){Checks[2].State="warning";return "Key 有效，但当前没有可用模型";}return Models.Count+" 个授权模型 · 网关提供三种入口；实际调用需下方验证";},
            };
            for (var i = 0; i < operations.Length; i++)
            {
                var item = Checks[i]; item.State = "running"; Notify(); var watch = System.Diagnostics.Stopwatch.StartNew();
                if (i > 0 && string.IsNullOrEmpty(CurrentKey)) { item.State = "skipped"; item.Detail = "请先连接或选择有效的 API Key"; Notify(); continue; }
                if (i == 2 && Checks[1].State == "failed") { item.State = "skipped"; item.Detail = "Key 验证失败，修复后重新检查"; Models.Clear(); Notify(); continue; }
                try { item.Detail = await operations[i](); if (item.State == "running") item.State = "passed"; } catch (Exception e) { item.Detail = YakCoolApi.Redact(e.Message, CurrentKey); item.State = "failed"; }
                item.Milliseconds = watch.ElapsedMilliseconds; Notify();
            }
            Message = Checks.All(c => c.State == "passed") ? "基础检查通过，未调用付费模型" : "检查完成，请查看标记项目；未调用付费模型";
        }
        private void ClearChecks() { Checks.Clear(); QualityChecks.Clear(); QualityModel = QualityProtocol = null; LastProbe = null; LastProbeModel = LastProbeProtocol = null; }
        private static void ValidateKeyInfo(JObject info)
        {
            if (!(info["key"] is JObject key) || !(info["quota"] is JObject)) throw new InvalidOperationException("Key 状态数据无效，请稍后重试");
            var status = key.Text("status").Trim().ToLowerInvariant();
            if (!new[] { "enabled", "active", "ok" }.Contains(status)) throw new InvalidOperationException(string.IsNullOrEmpty(status) ? "服务未返回 Key 启用状态" : "Key 已停用，请选择其他 Key");
        }
        public async Task Probe(string model, string protocol, bool confirmed)
        {
            if (!confirmed) throw new InvalidOperationException("真实模型调用需要确认");
            if (!Models.Any(m => m.Id == model && m.Protocols.Contains(protocol))) throw new InvalidOperationException("所选模型或协议不可用");
            LastProbe = null; LastProbeModel = model; LastProbeProtocol = protocol;
            using var cancellation = new CancellationTokenSource(); testing = cancellation; Notify();
            ModelProbeResult result;
            try { result = await Api.Probe(RequireKey(), model, protocol, "connectivity", cancellation.Token); }
            catch (OperationCanceledException) { LastProbe = new ModelProbeResult { Status = "skipped", Result = "检测已取消", Detail = "已停止等待响应；已经到达服务端的请求可能仍会计费。" }; Message = "已取消模型测试"; return; }
            catch (Exception e) { LastProbe = new ModelProbeResult { Status = "failed", Result = "请求未完成", Detail = YakCoolApi.Redact(e.Message, CurrentKey) }; throw; }
            finally { testing = null; Notify(); }
            LastProbe = result;
            Message = result.Result + " · " + result.Milliseconds + " ms";
        }
        public async Task ProbeQuality(string model, string protocol, bool confirmed)
        {
            if (!confirmed) throw new InvalidOperationException("完整能力检测需要确认");
            if (!Models.Any(m => m.Id == model && m.Protocols.Contains(protocol))) throw new InvalidOperationException("所选模型或协议不可用");
            QualityModel = model; QualityProtocol = protocol; QualityChecks = NewQualityChecks();
            using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(4)); testing = cancellation;
            ModelProbeResult toolsAuto = null;
            var billable = 0;
            var deadline = DateTime.UtcNow.AddMinutes(4);
            try { foreach (var item in QualityChecks)
            {
                if (cancellation.IsCancellationRequested) { SkipPendingQuality(); break; }
                if (item.Key == "protocol") { item.State = "running"; item.Result = UiProtocol(protocol) + " 待实测"; item.Detail = "目录确认模型权限；入口是否响应由下一项真实调用确认。"; Notify(); continue; }
                if (item.Key == "tools_schema")
                {
                    item.State = toolsAuto?.ToolSchemaValid == true ? "passed" : "unsupported";
                    item.Result = toolsAuto?.ToolSchemaValid == true ? "结构符合 function tool_calls" : "工具结构不完整";
                    item.Detail = toolsAuto == null ? "自动工具调用没有留下可校验结果。" : "复用自动工具调用响应，不产生额外请求。";
                    item.ToolCalls = toolsAuto?.ToolCalls ?? 0; Notify(); continue;
                }
                if (DateTime.UtcNow >= deadline)
                {
                    foreach (var remaining in QualityChecks.Where(x => x.State == "pending")) { remaining.State = "skipped"; remaining.Result = "已跳过"; remaining.Detail = "完整检测达到 4 分钟上限。"; }
                    Notify(); break;
                }
                item.State = "running"; Notify();
                try
                {
                    billable++; var result = await Api.Probe(RequireKey(), model, protocol, item.Key, cancellation.Token);
                    item.State = result.Status; item.Result = result.Result; item.Detail = result.Detail; item.Output = result.Output; item.Reasoning = result.Reasoning; item.ToolCalls = result.ToolCalls; item.Milliseconds = result.Milliseconds;
                    if (item.Key == "tools_auto") toolsAuto = result;
                    if (item.Key == "connectivity") { var entry = QualityChecks[0]; entry.State = result.Status == "failed" ? "failed" : "passed"; entry.Result = entry.State == "passed" ? UiProtocol(protocol) + " 已响应" : "入口返回异常响应"; entry.Detail = "基于本次真实请求结果，不将目录声明当作实测。"; if (result.Status == "failed") { SkipPendingQuality(); Notify(); break; } }
                }
                catch (OperationCanceledException) { item.State = "skipped"; item.Result = "已停止"; item.Detail = "检测被取消或达到 4 分钟上限；已到达服务端的请求可能仍会计费。"; SkipPendingQuality(); Notify(); break; }
                catch (Exception e)
                {
                    var rejectedCapability = item.Key != "connectivity" && e is ApiRequestException requestError && new[] { 400, 422 }.Contains(requestError.StatusCode);
                    item.State = rejectedCapability ? "unsupported" : "failed"; item.Result = rejectedCapability ? "服务未接受该能力参数" : "请求失败"; item.Detail = YakCoolApi.Redact(e.Message, CurrentKey);
                    if (item.Key == "connectivity")
                    {
                        QualityChecks[0].State = "failed"; QualityChecks[0].Result = "本次未验证通过"; QualityChecks[0].Detail = item.Detail; SkipPendingQuality();
                        Notify(); break;
                    }
                }
                Notify();
            } } finally { testing = null; }
            var passed = QualityChecks.Count(x => x.State == "passed"); var unsupported = QualityChecks.Count(x => x.State == "unsupported"); var failed = QualityChecks.Count(x => x.State == "failed");
            var warnings = QualityChecks.Count(x => x.State == "warning");
            Message = (cancellation.IsCancellationRequested ? "检测已停止：" : "能力画像完成：") + passed + " 项通过" + (unsupported > 0 ? "，" + unsupported + " 项未观察到" : "") + (warnings > 0 ? "，" + warnings + " 项待核实" : "") + (failed > 0 ? "，" + failed + " 项失败" : "") + (Environment.Demo ? " · 演示模式未产生费用" : " · 已发起 " + billable + " 次请求");
        }
        private void SkipPendingQuality() { foreach (var remaining in QualityChecks.Where(x => x.State == "pending" || x.State == "running")) { remaining.State = "skipped"; remaining.Result = "已跳过"; remaining.Detail = "检测已停止，未继续发送请求。"; } }
        private static List<ModelQualityCheck> NewQualityChecks()
        {
            var checks = new List<ModelQualityCheck> {
                new ModelQualityCheck{Key="protocol",Title="模型与协议发现",Category="基础"},
                new ModelQualityCheck{Key="connectivity",Title="响应与指令遵循",Category="基础"},
                new ModelQualityCheck{Key="vision",Title="图片输入 / OCR",Category="多模态"},
                new ModelQualityCheck{Key="tools_auto",Title="工具调用（auto）",Category="工具"},
                new ModelQualityCheck{Key="tools_schema",Title="工具调用标准",Category="工具"},
                new ModelQualityCheck{Key="tools_forced",Title="指定工具选择",Category="工具"},
                new ModelQualityCheck{Key="tools_roundtrip",Title="工具结果回灌",Category="工具"},
                new ModelQualityCheck{Key="thinking_off",Title="关闭思考",Category="思考"},
                new ModelQualityCheck{Key="thinking_on",Title="打开思考",Category="思考"}
            };
            foreach (var effort in new[] { "minimal", "low", "medium", "high", "xhigh", "max" }) checks.Add(new ModelQualityCheck { Key = "effort_" + effort, Title = "思考强度 · " + effort, Category = "思考强度" });
            return checks;
        }
        private static string UiProtocol(string protocol) => protocol == "responses" ? "Responses API" : protocol == "anthropic_messages" ? "Anthropic Messages" : "Chat Completions";
    }
}
