using System;
using System.Linq;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    // All preview data is explicitly labelled in the UI and stays in its sandbox.
    public sealed class DemoApi : IYakCoolApi
    {
        public const string Key = "yc-demo-only-not-a-real-business-key-7392";
        public static readonly AvailableModel[] Models =
        {
            new AvailableModel{Id="claude-sonnet-4-6",Name="Claude Sonnet 4.6",Protocols=new[]{"anthropic_messages","chat_completions"}},
            new AvailableModel{Id="gpt-5.4",Name="GPT-5.4",Protocols=new[]{"responses","chat_completions"}},
            new AvailableModel{Id="grok-4",Name="Grok 4",Protocols=YakCoolApi.Protocols},
            new AvailableModel{Id="deepseek-v3.2",Name="DeepSeek V3.2",Protocols=new[]{"chat_completions"}},
            new AvailableModel{Id="claude-opus-4-6",Name="Claude Opus 4.6",Protocols=new[]{"anthropic_messages"}},
            new AvailableModel{Id="qwen3-coder",Name="Qwen3 Coder",Protocols=new[]{"chat_completions"}},
        };
        private readonly JArray keys = new JArray(
            new JObject { ["id"] = 1, ["label"] = "日常开发", ["api_key"] = Key, ["last4"] = "7392", ["active"] = true, ["status"] = "active", ["token_limit_enable"] = false, ["usage_count"] = 128, ["created_at"] = "2026-09-01" },
            new JObject { ["id"] = 2, ["label"] = "自动化测试", ["api_key"] = "yc-demo-only-not-a-real-key-2086", ["last4"] = "2086", ["active"] = true, ["status"] = "active", ["token_limit_enable"] = true, ["usage_count"] = 24, ["created_at"] = "2026-09-02" });
        private double remaining = 128.6;
        private JObject User => new JObject { ["id"] = 1, ["display_name"] = "示例账户", ["avatar_url"] = "", ["public_uuid"] = "demo-public-user" };
        public Task<JObject> Get(string path, string key = null, string cookie = null)
        {
            JObject result;
            switch (path)
            {
                case "/api/health": result = new JObject { ["status"] = "ok" }; break;
                case "/api/auth/me": result = new JObject { ["user"] = User, ["staff_session"] = false }; break;
                case "/api/user/account": result = User; result["wechat_bound"] = true; break;
                case "/api/user/dashboard": result = new JObject { ["user"] = User, ["ai_service_credit"] = new JObject { ["status"] = "ok", ["token_limit"] = 1500000000, ["token_remaining"] = remaining * 10000000, ["token_used"] = 1500000000 - remaining * 10000000, ["weighted_tokens_per_rmb"] = 10000000, ["token_limit_enable"] = true }, ["api_key_count"] = keys.Count, ["api_key_limit"] = 20, ["gateway_url"] = YakCoolApi.Gateway, ["account_summary"] = new JObject { ["usage_count"] = 152, ["success_rate"] = 99.3, ["active_days"] = 12 } }; break;
                case "/api/user/api-keys": result = new JObject { ["keys"] = keys.DeepClone(), ["api_key_limit"] = 20, ["sync_status"] = "ok" }; break;
                case "/api/user/models": result = new JObject { ["models"] = new JArray(Models.Select(m => new JObject { ["model_id"] = m.Id, ["display_name"] = m.Name, ["provider"] = m.Id.Split('-')[0], ["summary"] = "用于界面和协议验证的示例模型" })) }; break;
                case "/api/key/info":
                    if (key == null || !key.StartsWith("yc-demo-")) throw new InvalidOperationException("演示模式请使用 yc-demo 开头的测试 Key");
                    result = new JObject { ["schema_version"] = 1, ["key"] = new JObject { ["label"] = "演示 API Key", ["last4"] = key.Substring(key.Length - 4), ["status"] = "active" }, ["quota"] = new JObject { ["mode"] = "shared_account", ["follows_account"] = true, ["approximate"] = true, ["remaining_percent_approx"] = 80, ["used_percent_approx"] = 20, ["display"] = "跟随主余额，剩余约 80%" } }; break;
                case "/api/key/models": result = new JObject { ["schema_version"] = 1, ["data"] = new JArray(Models.Select(m => new JObject { ["id"] = m.Id, ["name"] = m.Name, ["protocols"] = new JArray(m.Protocols) })) }; break;
                default: throw new InvalidOperationException("未知演示接口");
            }
            return Task.FromResult(result);
        }
        public Task<JObject> Send(string path, string method, JObject body, string cookie)
        {
            if (path == "/api/user/api-keys" && method == "POST")
            {
                var record = new JObject { ["id"] = DateTime.UtcNow.Ticks, ["label"] = body.Text("label"), ["api_key"] = "yc-demo-created-key-5861", ["last4"] = "5861", ["active"] = true, ["status"] = "active", ["created_at"] = DateTime.Today.ToString("yyyy-MM-dd") }; keys.Add(record); return Task.FromResult(new JObject { ["key"] = record.DeepClone() });
            }
            if (path.StartsWith("/api/user/api-keys/") && method == "DELETE") foreach (var record in keys.Where(k => k.Text("id") == path.Split('/').Last()).ToArray()) record.Remove();
            if (path == "/api/user/redeem") { remaining += 10; return Task.FromResult(new JObject { ["status"] = "applied", ["amount_cents"] = 1000 }); }
            return Task.FromResult(new JObject { ["status"] = "ok" });
        }
        public Task<string> Probe(string key, string model, string protocol) => Task.FromResult("OK（本地模拟响应，未调用模型）");
    }
}
