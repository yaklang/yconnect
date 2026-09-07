using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using YConnect.Core;

internal static class RechargeChecks
{
    private const string Cookie = "demo-public-session-only", Id = "YC20260906123456AB_C-D";
    private static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
    private static async Task Reject(Func<Task> action) { try { await action(); } catch (InvalidOperationException) { return; } throw new Exception("Unsafe payment operation was accepted"); }
    public static Task Amounts()
    {
        Check(RechargeSession.ParseAmount("1.01") == 101 && RechargeSession.ParseAmount("10000") == 1000000, "cent conversion");
        foreach (var value in new[] { "", "0.99", "10000.01", "50.001", "1e2", "NaN", "-50", "1,000", "50.", "１２" })
        { try { RechargeSession.ParseAmount(value); } catch (InvalidOperationException) { continue; } throw new Exception("Invalid amount accepted: " + value); }
        return Task.CompletedTask;
    }
    public static async Task PaymentStates()
    {
        var fixture = new PaymentApi(); var session = fixture.Session(); await session.Create(1234, "wechat");
        Check(session.CanShowQr && !session.Paid && fixture.Creates == 1 && fixture.Queries == 1 && fixture.Amount == 1234, "unverified QR or incorrect cents");
        fixture.Order["status"] = "paid"; await session.Query(); Check(!session.Paid && !session.CanShowQr && session.State == "verifying", "unverified payment reported paid");
        fixture.Order["verification_status"] = "verified"; await session.Query(); Check(session.Paid && !session.CanShowQr, "verified payment not accepted");
        await session.Create(5000, "alipay"); Check(fixture.Creates == 1, "paid order created a second payment without returning to form");
        foreach (var state in new[] { "failed", "closed" }) { fixture = new PaymentApi(); session = fixture.Session(); await session.Create(1234, "wechat"); fixture.Order["status"] = state; await session.Query(); Check(!session.CanShowQr && !session.Paid && !session.NeedsPolling, "terminal state still payable"); }
    }
    public static async Task Mismatches()
    {
        foreach (var change in new Action<JObject>[] { o => o["amount_cents"] = 9900, o => o["amount_cents"] = "1234", o => o["order_no"] = "YC20260906123456WRONG" })
        { var fixture = new PaymentApi(); change(fixture.Order); var session = fixture.Session(); await Reject(() => session.Create(1234, "wechat")); Check(!session.CanShowQr && !session.Paid, "mismatched QR exposed"); }
        var f = new PaymentApi(); var s = f.Session(); await s.Create(1234, "wechat"); f.Order["verification_status"] = "mismatch"; await s.Query(); Check(!s.CanShowQr && !s.Paid && s.State == "mismatch", "verification mismatch ignored");
        f = new PaymentApi(); s = f.Session(); await s.Create(1234, "wechat"); await Reject(() => s.Create(5000, "wechat")); Check(!s.CanShowQr, "reused order with a different amount was shown");
        await s.Create(1234, "alipay"); Check(s.CanShowQr && s.AmountCents == 1234 && s.Channel == "alipay", "mismatched order could not be safely corrected");
        foreach (var url in new[] { "", "javascript:alert(1)", "file:///c:/secret", "http://untrusted/", "weixin://bad\nvalue" })
        { f = new PaymentApi { Url = url }; s = f.Session(); await Reject(() => s.Create(1234, "wechat")); Check(!s.CanShowQr, "invalid payment payload accepted"); }
    }
    public static async Task ExpiryAndErrors()
    {
        var now = DateTime.UtcNow; var fixture = new PaymentApi(); var session = fixture.Session(() => true, () => now); await session.Create(1234, "wechat");
        now = now.AddSeconds(121); Check(!session.CanShowQr && session.SecondsLeft == 0, "expired QR visible");
        await session.Query(); Check(!session.CanShowQr, "polling silently extended QR display lifetime");
        await session.Create(1234, "wechat"); Check(session.CanShowQr && session.AmountCents == 1234, "explicit QR refresh did not verify and renew display");
        fixture.Order["status"] = "paid"; fixture.Order["verification_status"] = "verified"; await session.Query(); Check(session.Paid, "late payment not reconciled");
        fixture = new PaymentApi(); session = fixture.Session(); await session.Create(1234, "alipay"); fixture.Failure = new ApiRequestException(401, "expired"); await Reject(session.Query); Check(!session.Paid, "network/auth error became success"); fixture.Failure = null; await session.Query(); Check(session.State == "pending", "manual query could not recover");
        fixture = new PaymentApi { Failure = new InvalidOperationException("transient network") }; session = fixture.Session(); await Reject(() => session.Create(1234, "wechat")); Check(!session.CanShowQr, "QR exposed before failed amount validation"); fixture.Failure = null; await session.Query(); Check(session.CanShowQr, "QR did not recover after successful amount validation");
    }
    public static async Task AccountAndConcurrency()
    {
        var current = true; var fixture = new PaymentApi { Gate = new TaskCompletionSource<JObject>() }; var session = fixture.Session(() => current);
        var first = session.Create(1234, "wechat"); await Reject(() => session.Create(1234, "wechat")); Check(fixture.Creates == 1, "double-click duplicated order");
        current = false; fixture.Gate.SetResult(fixture.Created()); await Reject(() => first); Check(!session.CanShowQr, "late QR crossed account boundary"); await Reject(session.Query);
        fixture = new PaymentApi(); session = fixture.Session(() => false); await Reject(() => session.Create(1234, "wechat")); Check(fixture.Creates == 0, "stale account sent payment request");
    }
    public static async Task HttpBoundary()
    {
        var handler = new Handler(); using (var api = new YakCoolApi(handler))
        {
            await api.Send("/api/payments/orders", "POST", new JObject { ["amount_cents"] = 1234, ["channel"] = "wechat" }, Cookie);
            await api.Get("/api/payments/orders/" + Id, cookie: Cookie);
            Check(handler.Count == 2 && handler.Cookie == "yakcool_user_session=" + Cookie && handler.Host == "yakcool.com" && handler.Authorization == null, "public payment credential boundary");
            foreach (var path in new[] { "/api/payments/orders/../user/dashboard", "/api/payments/orders/" + Id + "?evil=1", "/api/payments/orders/" + Id + "%2Ftest", "/api/payments/orders", "/api/payments/admin" }) await Reject(() => api.Get(path, cookie: Cookie));
            await Reject(() => api.Get("/api/payments/orders/" + Id, key: DemoApi.Key));
            await Reject(() => api.Send("/api/payments/orders/" + Id, "DELETE", null, Cookie));
            Check(handler.Count == 2, "rejected route sent request");
        }
    }
    private sealed class PaymentApi : IYakCoolApi
    {
        public int Creates, Queries; public long Amount; public Exception Failure; public TaskCompletionSource<JObject> Gate;
        public string Url = "https://yakcool.com/#yconnect-demo-no-payment";
        public JObject Order = new JObject { ["order_no"] = Id, ["amount_cents"] = 1234, ["status"] = "pending", ["verification_status"] = "" };
        public RechargeSession Session(Func<bool> current = null, Func<DateTime> clock = null) => new RechargeSession(this, Cookie, "Fixture", current ?? (() => true), clock);
        public JObject Created(string channel = "wechat") => new JObject { ["order_no"] = Id, ["channel"] = channel, ["code_url"] = Url };
        public Task<JObject> Get(string path, string key = null, string cookie = null) { Check(cookie == Cookie && key == null, "GET credential leak"); Queries++; if (Failure != null) throw Failure; return Task.FromResult((JObject)Order.DeepClone()); }
        public Task<JObject> Send(string path, string method, JObject body, string cookie) { Check(cookie == Cookie && method == "POST" && path == "/api/payments/orders", "POST boundary"); Creates++; Amount = (long)body["amount_cents"]; return Gate?.Task ?? Task.FromResult(Created(body.Text("channel"))); }
        public Task<ModelProbeResult> Probe(string key, string model, string protocol, string check, CancellationToken cancellation = default) => throw new Exception("Recharge must never invoke model APIs");
    }
    private sealed class Handler : HttpMessageHandler
    {
        public int Count; public string Cookie, Host, Authorization;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { Count++; Host = request.RequestUri.Host; Cookie = request.Headers.GetValues("Cookie").GetEnumerator() is var e && e.MoveNext() ? e.Current : null; Authorization = request.Headers.Authorization?.ToString(); return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{}") }); }
    }
}
