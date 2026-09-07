using System;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    // One account-bound checkout. QR payloads and cookies are never persisted or logged.
    public sealed class RechargeSession
    {
        public const string OrderIdPattern = @"YC[A-Z0-9_-]{14,64}";
        private readonly IYakCoolApi api;
        private readonly string cookie;
        private readonly Func<bool> currentAccount;
        private readonly Func<DateTime> clock;
        private bool busy;
        private long? returnedAmount;
        public bool IsCurrent => currentAccount();
        public string AccountName { get; }
        public string OrderNumber { get; private set; }
        public string CodeUrl { get; private set; }
        public string Channel { get; private set; } = "wechat";
        public long AmountCents { get; private set; }
        public string State { get; private set; } = "new";
        public DateTime CreatedAt { get; private set; }
        public bool Paid => State == "paid";
        public bool HasOrder => OrderNumber != null;
        public bool NeedsPolling => HasOrder && (State == "pending" || State == "verifying");
        public int SecondsLeft => Math.Max(0, (int)Math.Ceiling((CreatedAt.AddSeconds(120) - clock()).TotalSeconds));
        public bool CanShowQr => IsCurrent && State == "pending" && SecondsLeft > 0 && CodeUrl != null;
        public string Amount => (AmountCents / 100m).ToString("0.00", CultureInfo.InvariantCulture);
        public RechargeSession(IYakCoolApi api, string cookie, string accountName, Func<bool> currentAccount, Func<DateTime> clock = null)
        { this.api = api; this.cookie = YakCoolApi.ValidateCookie(cookie); AccountName = accountName; this.currentAccount = currentAccount; this.clock = clock ?? (() => DateTime.UtcNow); }

        public static long ParseAmount(string text)
        {
            text = text?.Trim();
            if (text == null || !Regex.IsMatch(text, @"\A[0-9]{1,5}(?:\.[0-9]{1,2})?\z") ||
                !decimal.TryParse(text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var amount) || amount < 1 || amount > 10000)
                throw new InvalidOperationException("请输入 ¥1–¥10,000 的金额，最多两位小数。");
            return (long)(amount * 100);
        }
        public static string ValidateOrderNumber(string value)
        {
            if (value == null || !Regex.IsMatch(value, "\\A" + OrderIdPattern + "\\z")) throw new InvalidOperationException("订单编号无效，请勿付款，稍后重试。");
            return value;
        }
        private void RequireCurrent() { if (!IsCurrent) { CodeUrl = null; throw new InvalidOperationException("充值账户已变更，请重新打开充值窗口。"); } }
        public async Task Create(long cents, string channel)
        {
            if (busy) throw new InvalidOperationException("正在处理此订单，请稍候。");
            RequireCurrent();
            if (cents < 100 || cents > 1000000 || !(channel == "wechat" || channel == "alipay")) throw new InvalidOperationException("充值金额或支付方式无效。");
            busy = true;
            try
            {
                // Check the previous order before replacing a QR: it may have just been paid.
                if (HasOrder)
                {
                    // A reused order may have a different old amount. Reconcile that order
                    // before allowing an explicit retry with another channel or amount.
                    if (State == "mismatch" && returnedAmount.HasValue) AmountCents = returnedAmount.Value;
                    await QueryCore(); if (Paid) return;
                    if (State == "mismatch" || State == "verifying") throw new InvalidOperationException("上一笔付款仍需核验，请先查询结果或到官网核对，不要重复付款。");
                }
                CodeUrl = null;
                var created = await api.Send("/api/payments/orders", "POST", new JObject { ["amount_cents"] = cents, ["channel"] = channel }, cookie);
                RequireCurrent();
                var id = ValidateOrderNumber(created.Text("order_no"));
                CreatedAt = clock(); // Only an explicit QR request renews the display window; polling never does.
                OrderNumber = id; AmountCents = cents; Channel = channel; State = "verifying";
                if (created.Text("channel") != channel) { State = "mismatch"; throw new InvalidOperationException("支付方式与订单不一致，请勿付款。"); }
                var url = created.Text("code_url");
                if (string.IsNullOrWhiteSpace(url) || url.Length > 2048 || url.Any(char.IsControl) || !Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
                    !(uri.Scheme == "https" || channel == "wechat" && uri.Scheme == "weixin" || channel == "alipay" && uri.Scheme == "alipay"))
                { State = "invalid"; throw new InvalidOperationException("服务未返回有效支付码，请勿付款，稍后重试。"); }
                // POST does not echo the amount. Verify it via the authenticated GET before showing a QR.
                CodeUrl = url; // Still hidden while State is verifying; a failed GET may be retried safely.
                await QueryCore();
            }
            finally { busy = false; }
        }
        public async Task Query()
        {
            RequireCurrent();
            if (busy || !HasOrder) return;
            busy = true; try { await QueryCore(); } finally { busy = false; }
        }
        private async Task QueryCore()
        {
            RequireCurrent();
            if (Paid) return;
            var data = await api.Get("/api/payments/orders/" + ValidateOrderNumber(OrderNumber), cookie: cookie);
            RequireCurrent();
            returnedAmount = null;
            if (data.Text("order_no") != OrderNumber || data["amount_cents"]?.Type != JTokenType.Integer || (long)data["amount_cents"] != AmountCents)
            {
                if (data.Text("order_no") == OrderNumber && data["amount_cents"]?.Type == JTokenType.Integer && (long)data["amount_cents"] >= 100 && (long)data["amount_cents"] <= 1000000) returnedAmount = (long)data["amount_cents"];
                State = "mismatch"; CodeUrl = null;
                throw new InvalidOperationException("服务返回的订单金额不一致，已隐藏支付码。" + (returnedAmount.HasValue ? "旧订单为 ¥" + (returnedAmount.Value / 100m).ToString("0.00", CultureInfo.InvariantCulture) + "，可返回修改金额或支付方式。" : "") + "若已付款，请勿重复支付，请到官网核对订单。");
            }
            var status = data.Text("status"); var verification = data.Text("verification_status");
            if (verification == "mismatch") State = "mismatch";
            else if (status == "paid") State = verification == "verified" ? "paid" : "verifying";
            else if (status == "pending" || status == "failed" || status == "closed") State = status;
            else { CodeUrl = null; State = "invalid"; throw new InvalidOperationException("订单状态无法识别，请稍后查询，不要重复付款。"); }
            if (State != "pending") CodeUrl = null;
        }
    }
}
