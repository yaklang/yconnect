using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    public sealed class ModelProbeResult
    {
        public string Status { get; set; } = "passed";
        public string Result { get; set; }
        public string Detail { get; set; }
        public string Output { get; set; }
        public string Reasoning { get; set; }
        public int ToolCalls { get; set; }
        public bool ToolSchemaValid { get; set; }
        public long Milliseconds { get; set; }
    }
    public interface IYakCoolApi
    {
        Task<JObject> Get(string path, string key = null, string cookie = null);
        Task<JObject> Send(string path, string method, JObject body, string cookie);
        Task<ModelProbeResult> Probe(string key, string model, string protocol, string check, CancellationToken cancellation = default);
    }
    public sealed class ApiRequestException : InvalidOperationException
    {
        public int StatusCode { get; }
        public ApiRequestException(int status, string message) : base(message) { StatusCode = status; }
    }
    public sealed class YakCoolApi : IYakCoolApi, IDisposable
    {
        public const string Origin = "https://yakcool.com";
        public const string Gateway = "https://aibalance.yaklang.com";
        public static readonly string[] Protocols = { "responses", "anthropic_messages", "chat_completions" };
        private readonly HttpClient http;
        public YakCoolApi(HttpMessageHandler handler = null, bool useSystemProxy = true)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            http = new HttpClient(handler ?? new HttpClientHandler { UseProxy = useSystemProxy, AllowAutoRedirect = false, UseCookies = false, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate }) { Timeout = Timeout.InfiniteTimeSpan };
        }
        public static string ValidateKey(string value)
        {
            value = value?.Trim();
            if (string.IsNullOrEmpty(value) || Encoding.UTF8.GetByteCount(value) > 512 || value.Any(c => char.IsWhiteSpace(c) || char.IsControl(c))) throw new InvalidOperationException("请输入有效的 YakCool API Key（不含空格，最多 512 字节）");
            return value;
        }
        public static string ValidateCookie(string value)
        {
            if (value == null || !Regex.IsMatch(value, @"\A[A-Za-z0-9._~-]{8,4096}\z")) throw new InvalidOperationException("YakCool 公开用户会话无效");
            return value;
        }
        public static string ValidateModel(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 200 || value.Any(c => char.IsControl(c) || char.IsWhiteSpace(c))) throw new InvalidOperationException("模型 ID 无效");
            return value;
        }
        public static string ValidateGateway(string value)
        {
            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "https" || !uri.IsDefaultPort || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) || uri.AbsolutePath.Trim('/').Length > 0 || !(uri.Host == "aibalance.yaklang.com" || uri.Host.EndsWith(".yaklang.com", StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("只允许受信任的 Yaklang HTTPS 网关");
            return uri.GetLeftPart(UriPartial.Authority);
        }
        public static string Redact(string message, params string[] secrets)
        {
            var result = message ?? "请求失败";
            foreach (var secret in secrets.Where(s => !string.IsNullOrEmpty(s))) result = result.Replace(secret, "[已隐藏]");
            result = Regex.Replace(result, @"(?:Bearer\s+|sk-)[A-Za-z0-9_.-]+", "[已隐藏]", RegexOptions.IgnoreCase);
            return result.Length > 600 ? result.Substring(0, 600) : result;
        }
        public Task<JObject> Get(string path, string key = null, string cookie = null) => Request(Origin, path, "GET", null, key, cookie);
        public Task<JObject> Send(string path, string method, JObject body, string cookie) => Request(Origin, path, method, body, null, cookie);
        private async Task<JObject> Request(string origin, string path, string method, JObject body, string key, string cookie, CancellationToken cancellation = default)
        {
            var paymentPath = method == "POST" && path == "/api/payments/orders" || method == "GET" && Regex.IsMatch(path, "\\A/api/payments/orders/" + RechargeSession.OrderIdPattern + "\\z");
            if (!paymentPath && !Regex.IsMatch(path, @"\A/api/[a-z0-9/-]+\z") && !Regex.IsMatch(path, @"\A/v1/(responses|messages|chat/completions)\z")) throw new InvalidOperationException("请求路径无效");
            if (key != null && cookie != null) throw new InvalidOperationException("不能混用账户会话与业务 Key");
            if (path.StartsWith("/api/payments/") && (!paymentPath || cookie == null || key != null)) throw new InvalidOperationException("充值仅支持账户登录和指定订单接口");
            if (cookie != null && (origin != Origin || !(paymentPath || path.StartsWith("/api/user/") || path == "/api/auth/me" || path == "/api/auth/logout"))) throw new InvalidOperationException("此接口不接收账户会话");
            using (var request = new HttpRequestMessage(new HttpMethod(method), origin + path))
            using (var cancel = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
            {
                cancel.CancelAfter(TimeSpan.FromSeconds(origin == Gateway ? 120 : 20));
                request.Headers.TryAddWithoutValidation("Accept", "application/json");
                request.Headers.TryAddWithoutValidation("User-Agent", "YConnect/0.2.0 (Windows; WPF)");
                if (key != null) request.Headers.TryAddWithoutValidation(path == "/v1/messages" ? "x-api-key" : "Authorization", path == "/v1/messages" ? ValidateKey(key) : "Bearer " + ValidateKey(key));
                if (path == "/v1/messages") request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
                if (cookie != null) request.Headers.TryAddWithoutValidation("Cookie", "yakcool_user_session=" + ValidateCookie(cookie));
                if (body != null) request.Content = new StringContent(body.ToString(), Encoding.UTF8, "application/json");
                try
                {
                    using (var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel.Token).ConfigureAwait(false))
                    using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    using (var buffer = new MemoryStream())
                    {
                        var chunk = new byte[8192]; int read;
                        while ((read = await stream.ReadAsync(chunk, 0, chunk.Length, cancel.Token).ConfigureAwait(false)) > 0)
                        {
                            if (buffer.Length + read > 5 * 1024 * 1024) throw new InvalidOperationException("服务响应过大");
                            buffer.Write(chunk, 0, read);
                        }
                        if (response.StatusCode == HttpStatusCode.Unauthorized) throw new ApiRequestException(401, "登录凭证已失效，请重新连接");
                        JObject data;
                        try { data = Json.Parse(Encoding.UTF8.GetString(buffer.ToArray())); }
                        catch { throw new InvalidOperationException("服务响应格式无效（HTTP " + (int)response.StatusCode + "）"); }
                        if (!response.IsSuccessStatusCode) throw new ApiRequestException((int)response.StatusCode, Redact(data.Text("message", data["error"] is JObject error ? error.Text("message") : data.Text("error", "HTTP " + (int)response.StatusCode)), key, cookie));
                        return data;
                    }
                }
                catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { throw new InvalidOperationException(origin == Gateway ? "模型请求超过 120 秒，可能仍在排队或思考，请稍后重试" : "服务请求超过 20 秒，请检查网络或代理后重试"); }
                catch (HttpRequestException) { throw new InvalidOperationException("网络连接失败，请检查网络或代理后重试"); }
            }
        }
        public async Task<ModelProbeResult> Probe(string key, string model, string protocol, string check, CancellationToken cancellation = default)
        {
            ValidateModel(model); if (!Protocols.Contains(protocol)) throw new InvalidOperationException("不支持此调用协议");
            var path = protocol == "responses" ? "/v1/responses" : protocol == "anthropic_messages" ? "/v1/messages" : "/v1/chat/completions";
            var marker = check == "vision" || check == "tools_roundtrip" ? RandomMarker() + (check == "tools_roundtrip" ? RandomMarker() : "") : null;
            var body = BuildProbeBody(model, protocol, check, marker);
            var watch = Stopwatch.StartNew();
            var response = await Request(Gateway, path, "POST", body, key, null, cancellation);
            watch.Stop();
            var output = ExtractOutput(response, protocol).Trim();
            var reasoning = ExtractReasoning(response, protocol).Trim();
            var tools = ExtractToolCalls(response, protocol);
            var result = new ModelProbeResult { Output = Preview(output), Reasoning = Preview(reasoning), ToolCalls = tools.Count, ToolSchemaValid = ToolSchemaValid(tools), Milliseconds = watch.ElapsedMilliseconds };
            var finish = response.Array("choices").FirstOrDefault().Text("finish_reason", response.Text("stop_reason"));
            if (finish == "length" || finish == "max_tokens" || response.Text("status") == "incomplete")
            {
                result.Status = "warning"; result.Result = "输出达到测试上限"; result.Detail = "请求已返回，但输出或思考被截断，不能据此判断模型不可用。"; return result;
            }
            if (response.Text("status") == "failed" || response["error"] is JObject)
            { result.Status = "failed"; result.Result = "模型返回错误"; result.Detail = Redact(response["error"].Text("message", "响应标记为失败"), key); return result; }
            if (string.IsNullOrWhiteSpace(output) && tools.Count == 0)
            { result.Status = string.IsNullOrWhiteSpace(reasoning) ? "failed" : "warning"; result.Result = string.IsNullOrWhiteSpace(reasoning) ? "响应中没有正文或工具调用" : "仅返回思考，尚无最终答案"; result.Detail = "检查响应证据或重试其他协议；这不等同于网络不通。"; return result; }
            Evaluate(check, marker, output, reasoning, tools, result);
            return result;
        }

        private static JObject BuildProbeBody(string model, string protocol, string check, string marker)
        {
            var body = new JObject { ["model"] = model, ["stream"] = false };
            var prompt = "Reply with exactly YCONNECT_OK and no other text.";
            var maxTokens = 1024;
            if (check == "vision") prompt = "Read the two uppercase letters in this image. Reply with only " + marker + ".";
            else if (check == "tools_auto" || check == "tools_forced") prompt = "Call yconnect_probe_ping now with an empty object and output nothing else.";
            else if (check == "tools_roundtrip") prompt = "Summarize the supplied tool result by replying with exactly YCONNECT_PONG.";
            else if (check == "thinking_on" || check == "thinking_off" || check.StartsWith("effort_")) { prompt = "Calculate 37 * 19. Reply with only the final integer."; maxTokens = 4096; }

            SetPrompt(body, protocol, prompt, maxTokens);
            if (check == "connectivity" && protocol == "chat_completions") body["enable_thinking"] = false;
            if (check == "vision") AddImage(body, protocol, ProbeImage(marker));
            if (check == "tools_auto" || check == "tools_forced") AddTools(body, protocol, check == "tools_forced");
            if (check == "tools_roundtrip") SetToolRoundtrip(body, protocol, marker);
            if (check == "thinking_on") SetThinking(body, protocol, true, "low");
            if (check == "thinking_off") SetThinking(body, protocol, false, "none");
            if (check.StartsWith("effort_")) SetThinking(body, protocol, true, check.Substring("effort_".Length));
            return body;
        }

        private static void SetPrompt(JObject body, string protocol, string prompt, int maxTokens)
        {
            if (protocol == "responses") { body["input"] = prompt; body["max_output_tokens"] = maxTokens; }
            else { body["messages"] = new JArray(new JObject { ["role"] = "user", ["content"] = prompt }); body["max_tokens"] = maxTokens; }
        }

        private static void SetThinking(JObject body, string protocol, bool enabled, string effort)
        {
            if (protocol == "responses")
            {
                var reasoning = new JObject { ["effort"] = effort }; if (enabled) reasoning["summary"] = "auto"; body["reasoning"] = reasoning;
            }
            else if (protocol == "anthropic_messages")
            {
                body["thinking"] = enabled ? new JObject { ["type"] = "enabled", ["budget_tokens"] = 1024 } : new JObject { ["type"] = "disabled" };
                if (enabled && !string.IsNullOrEmpty(effort)) body["output_config"] = new JObject { ["effort"] = effort };
            }
            else { body["enable_thinking"] = enabled; body["reasoning_effort"] = effort; }
        }

        private static JObject ToolSchema() => new JObject { ["type"] = "object", ["properties"] = new JObject(), ["additionalProperties"] = false };
        private static void AddTools(JObject body, string protocol, bool forced)
        {
            if (protocol == "responses")
            {
                body["tools"] = new JArray(new JObject { ["type"] = "function", ["name"] = "yconnect_probe_ping", ["description"] = "Return a deterministic ping", ["parameters"] = ToolSchema(), ["strict"] = true });
                body["tool_choice"] = forced ? (JToken)new JObject { ["type"] = "function", ["name"] = "yconnect_probe_ping" } : "auto";
            }
            else if (protocol == "anthropic_messages")
            {
                body["tools"] = new JArray(new JObject { ["name"] = "yconnect_probe_ping", ["description"] = "Return a deterministic ping", ["input_schema"] = ToolSchema() });
                body["tool_choice"] = forced ? (JToken)new JObject { ["type"] = "tool", ["name"] = "yconnect_probe_ping" } : new JObject { ["type"] = "auto" };
            }
            else
            {
                body["tools"] = new JArray(new JObject { ["type"] = "function", ["function"] = new JObject { ["name"] = "yconnect_probe_ping", ["description"] = "Return a deterministic ping", ["parameters"] = ToolSchema(), ["strict"] = true } });
                body["tool_choice"] = forced ? (JToken)new JObject { ["type"] = "function", ["function"] = new JObject { ["name"] = "yconnect_probe_ping" } } : "auto";
            }
        }

        private static void SetToolRoundtrip(JObject body, string protocol, string marker)
        {
            const string callId = "yconnect_probe_call";
            var output = new JObject { ["status"] = "ok", ["echo"] = marker }.ToString(Newtonsoft.Json.Formatting.None);
            const string instruction = "Reply with only the exact echo value from the tool result.";
            if (protocol == "responses")
            {
                body["input"] = new JArray(
                    new JObject { ["role"] = "user", ["content"] = "Call the ping tool, then summarize its result." },
                    new JObject { ["type"] = "function_call", ["call_id"] = callId, ["name"] = "yconnect_probe_ping", ["arguments"] = "{}" },
                    new JObject { ["type"] = "function_call_output", ["call_id"] = callId, ["output"] = output },
                    new JObject { ["role"] = "user", ["content"] = instruction });
            }
            else if (protocol == "anthropic_messages")
            {
                body["messages"] = new JArray(
                    new JObject { ["role"] = "user", ["content"] = "Call the ping tool, then summarize its result." },
                    new JObject { ["role"] = "assistant", ["content"] = new JArray(new JObject { ["type"] = "tool_use", ["id"] = callId, ["name"] = "yconnect_probe_ping", ["input"] = new JObject() }) },
                    new JObject { ["role"] = "user", ["content"] = new JArray(new JObject { ["type"] = "tool_result", ["tool_use_id"] = callId, ["content"] = output }, new JObject { ["type"] = "text", ["text"] = instruction }) });
            }
            else
            {
                body["messages"] = new JArray(
                    new JObject { ["role"] = "user", ["content"] = "Call the ping tool, then summarize its result." },
                    new JObject { ["role"] = "assistant", ["content"] = "", ["tool_calls"] = new JArray(new JObject { ["id"] = callId, ["type"] = "function", ["function"] = new JObject { ["name"] = "yconnect_probe_ping", ["arguments"] = "{}" } }) },
                    new JObject { ["role"] = "tool", ["tool_call_id"] = callId, ["name"] = "yconnect_probe_ping", ["content"] = output },
                    new JObject { ["role"] = "user", ["content"] = instruction });
            }
        }

        private static void AddImage(JObject body, string protocol, string dataUrl)
        {
            if (protocol == "responses") body["input"] = new JArray(new JObject { ["role"] = "user", ["content"] = new JArray(new JObject { ["type"] = "input_text", ["text"] = "Read the two uppercase letters. Reply with only them." }, new JObject { ["type"] = "input_image", ["image_url"] = dataUrl }) });
            else if (protocol == "anthropic_messages") body["messages"] = new JArray(new JObject { ["role"] = "user", ["content"] = new JArray(new JObject { ["type"] = "text", ["text"] = "Read the two uppercase letters. Reply with only them." }, new JObject { ["type"] = "image", ["source"] = new JObject { ["type"] = "base64", ["media_type"] = "image/png", ["data"] = dataUrl.Substring(dataUrl.IndexOf(',') + 1) } }) });
            else body["messages"] = new JArray(new JObject { ["role"] = "user", ["content"] = new JArray(new JObject { ["type"] = "text", ["text"] = "Read the two uppercase letters. Reply with only them." }, new JObject { ["type"] = "image_url", ["image_url"] = new JObject { ["url"] = dataUrl } }) });
        }

        private static string RandomMarker()
        {
            const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ";
            var bytes = Guid.NewGuid().ToByteArray();
            return new string(new[] { alphabet[bytes[0] % alphabet.Length], alphabet[bytes[1] % alphabet.Length] });
        }

        private static string ProbeImage(string marker)
        {
            using (var bitmap = new System.Drawing.Bitmap(128, 80))
            using (var graphics = System.Drawing.Graphics.FromImage(bitmap))
            using (var font = new System.Drawing.Font("Segoe UI", 34, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Pixel))
            using (var stream = new MemoryStream())
            {
                graphics.Clear(System.Drawing.Color.White);
                graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                var size = graphics.MeasureString(marker, font);
                graphics.DrawString(marker, font, System.Drawing.Brushes.Black, (128 - size.Width) / 2, (80 - size.Height) / 2);
                bitmap.Save(stream, System.Drawing.Imaging.ImageFormat.Png);
                return "data:image/png;base64," + Convert.ToBase64String(stream.ToArray());
            }
        }

        private static string ExtractOutput(JObject response, string protocol)
        {
            if (protocol == "responses")
            {
                var direct = response.Text("output_text");
                if (!string.IsNullOrWhiteSpace(direct)) return direct;
                return string.Concat(response.Array("output").Where(x => x.Text("type") != "reasoning").SelectMany(x => x.Array("content")).Select(x => x.Text("text", x.Text("output_text"))));
            }
            if (protocol == "anthropic_messages") return string.Concat(response.Array("content").Where(x => x.Text("type") == "text" || x["type"] == null).Select(x => x.Text("text")));
            var content = response.Array("choices").FirstOrDefault()?["message"]?["content"];
            return content?.Type == JTokenType.String ? (string)content : string.Concat((content as JArray ?? new JArray()).Select(x => x.Text("text")));
        }

        private static string ExtractReasoning(JObject response, string protocol)
        {
            if (protocol == "responses") return string.Concat(response.Array("output").Where(x => x.Text("type") == "reasoning").SelectMany(x => x.Array("summary").Concat(x.Array("content"))).Select(x => x.Text("text", x.Text("summary_text"))));
            if (protocol == "anthropic_messages") return string.Concat(response.Array("content").Where(x => x.Text("type") == "thinking").Select(x => x.Text("thinking", x.Text("text"))));
            var message = response.Array("choices").FirstOrDefault()?["message"];
            return message.Text("reasoning_content", message.Text("reasoning"));
        }

        private static JArray ExtractToolCalls(JObject response, string protocol)
        {
            if (protocol == "responses") return new JArray(response.Array("output").Where(x => x.Text("type") == "function_call"));
            if (protocol == "anthropic_messages") return new JArray(response.Array("content").Where(x => x.Text("type") == "tool_use"));
            return response.Array("choices").FirstOrDefault()?["message"]?["tool_calls"] as JArray ?? new JArray();
        }

        private static bool ToolSchemaValid(JArray tools)
        {
            return tools.Count > 0 && tools.All(tool =>
            {
                var name = tool.Text("name", tool["function"].Text("name"));
                var id = tool.Text("id", tool.Text("call_id"));
                var arguments = tool.Text("arguments", tool["function"].Text("arguments", tool["input"]?.ToString()));
                if (name != "yconnect_probe_ping" || string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(arguments)) return false;
                try { return JToken.Parse(arguments) is JObject obj && !obj.Properties().Any(); } catch { return false; }
            });
        }

        private static void Evaluate(string check, string marker, string output, string reasoning, JArray tools, ModelProbeResult result)
        {
            if (check == "connectivity")
            {
                result.Status = output.Trim() == "YCONNECT_OK" ? "passed" : "warning";
                result.Result = output.Trim() == "YCONNECT_OK" ? "可访问 · 指令准确" : "可访问 · 指令有偏差";
                result.Detail = output.Trim() == "YCONNECT_OK" ? "模型按要求返回了固定标记。" : "模型有响应，但没有严格遵循仅返回固定标记的要求。";
            }
            else if (check == "vision")
            {
                var matched = NormalizeEvidence(output + reasoning).Contains(marker);
                result.Status = matched ? "passed" : "unsupported"; result.Result = matched ? "支持图片理解" : "未识别探测图"; result.Detail = matched ? "正确读出随机标记 " + marker + "。" : "响应中没有出现随机标记 " + marker + "。";
            }
            else if (check == "tools_auto" || check == "tools_forced")
            {
                var supported = tools.Any(x => x.Text("name", x["function"].Text("name")) == "yconnect_probe_ping");
                result.Status = supported ? "passed" : "unsupported"; result.Result = supported ? (check == "tools_forced" ? "支持指定工具" : "返回结构化工具调用") : "未返回结构化工具调用"; result.Detail = supported ? "观察到 yconnect_probe_ping，工具结构将在下一项校验。" : "请求成功，但模型返回了普通文本或空工具列表。";
            }
            else if (check == "tools_roundtrip")
            {
                var ok = output.Trim() == marker;
                result.Status = ok ? "passed" : "unsupported"; result.Result = ok ? "支持工具结果回灌" : "未确认回灌语义"; result.Detail = ok ? "模型正确读出仅出现在工具结果中的随机标记。" : "没有返回工具结果中的随机标记；不以普通 pong 回复判定通过。";
            }
            else if (check == "thinking_on")
            {
                var visible = !string.IsNullOrWhiteSpace(reasoning); result.Status = visible ? output.Trim() == "703" ? "passed" : "warning" : "unsupported"; result.Result = visible ? "返回可见思考" + (result.Status == "warning" ? " · 答案待核实" : " · 答案正确") : "未返回可见思考"; result.Detail = visible ? "响应包含 " + reasoning.Length + " 个思考字符。" : "网关接受了打开思考的请求，但本次响应没有可见 reasoning；模型可能隐藏思考。";
            }
            else if (check == "thinking_off")
            {
                var off = string.IsNullOrWhiteSpace(reasoning) && output.Trim() == "703"; result.Status = off ? "passed" : "unsupported"; result.Result = off ? "关闭后返回正确答案" : "未确认关闭思考效果"; result.Detail = off ? "本次只观察到正确最终答案；无法推断隐藏的内部思考。" : "最终答案或可见思考与预期不符，请查看响应证据。";
            }
            else if (check.StartsWith("effort_"))
            {
                var effort = check.Substring("effort_".Length); result.Status = output.Trim() == "703" ? "passed" : "warning"; result.Result = "已接受 " + effort + (result.Status == "passed" ? " · 答案正确" : " · 答案待核实"); result.Detail = "可见思考 " + reasoning.Length + " 字，正文 " + output.Length + " 字。参数被接受不代表模型实际切换了内部思考强度。";
            }
        }

        private static string NormalizeEvidence(string value) => new string((value ?? "").Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        private static string Preview(string value) => string.IsNullOrWhiteSpace(value) ? "" : value.Trim().Length <= 240 ? value.Trim() : value.Trim().Substring(0, 240) + "…";
        public void Dispose() => http.Dispose();
    }
}
