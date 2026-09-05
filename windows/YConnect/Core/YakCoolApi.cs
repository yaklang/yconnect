using System;
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
    public interface IYakCoolApi
    {
        Task<JObject> Get(string path, string key = null, string cookie = null);
        Task<JObject> Send(string path, string method, JObject body, string cookie);
        Task<string> Probe(string key, string model, string protocol);
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
            http = new HttpClient(handler ?? new HttpClientHandler { UseProxy = useSystemProxy, AllowAutoRedirect = false, UseCookies = false, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate }) { Timeout = TimeSpan.FromSeconds(20) };
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
        private async Task<JObject> Request(string origin, string path, string method, JObject body, string key, string cookie)
        {
            if (!Regex.IsMatch(path, @"\A/api/[a-z0-9/-]+\z") && !Regex.IsMatch(path, @"\A/v1/(responses|messages|chat/completions)\z")) throw new InvalidOperationException("请求路径无效");
            if (key != null && cookie != null) throw new InvalidOperationException("不能混用账户会话与业务 Key");
            if (cookie != null && (origin != Origin || !(path.StartsWith("/api/user/") || path == "/api/auth/me" || path == "/api/auth/logout"))) throw new InvalidOperationException("此接口不接收账户会话");
            using (var request = new HttpRequestMessage(new HttpMethod(method), origin + path))
            using (var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
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
                catch (TaskCanceledException) { throw new InvalidOperationException("请求超时，请检查网络后重试"); }
                catch (HttpRequestException) { throw new InvalidOperationException("网络连接失败，请检查网络或代理后重试"); }
            }
        }
        public async Task<string> Probe(string key, string model, string protocol)
        {
            ValidateModel(model); if (!Protocols.Contains(protocol)) throw new InvalidOperationException("不支持此调用协议");
            var body = new JObject { ["model"] = model, ["stream"] = false };
            var path = protocol == "responses" ? "/v1/responses" : protocol == "anthropic_messages" ? "/v1/messages" : "/v1/chat/completions";
            if (protocol == "responses") { body["input"] = "Reply exactly with OK."; body["max_output_tokens"] = 8; }
            else { body["messages"] = new JArray(new JObject { ["role"] = "user", ["content"] = "Reply exactly with OK." }); body["max_tokens"] = 8; }
            var result = await Request(Gateway, path, "POST", body, key, null);
            var output = protocol == "responses" ? result.Text("output_text", string.Concat(result.Array("output").SelectMany(o => o.Array("content")).Select(c => c.Text("text")))) : protocol == "anthropic_messages" ? string.Concat(result.Array("content").Select(c => c.Text("text"))) : result.Array("choices").FirstOrDefault()?["message"].Text("content");
            if (string.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("模型返回了空内容");
            return output.Trim();
        }
        public void Dispose() => http.Dispose();
    }
}
