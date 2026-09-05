using System;
using System.Linq;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    public sealed class BalancePresentation
    {
        public string Label { get; private set; }
        public string Value { get; private set; }
        public double? Percent { get; private set; }
        public bool Stale { get; private set; }
        public static BalancePresentation From(YConnectStore store, bool privacy = false)
        {
            var result = new BalancePresentation { Label = "连接你的 YakCool", Value = "尚未连接" };
            if (!store.Authenticated) return result;
            result.Stale = !store.LastRefresh.HasValue || DateTime.Now - store.LastRefresh.Value > TimeSpan.FromMinutes(5);
            if (store.Mode == "account")
            {
                var credit = store.Dashboard?["ai_service_credit"];
                if (credit.Number("token_limit") > 0 && Known(credit, "token_remaining")) result.Percent = Clamp(credit.Number("token_remaining") / credit.Number("token_limit") * 100);
                result.Label = privacy ? "账户剩余额度" : "账户可用余额";
                result.Value = privacy ? Percentage(result.Percent) : store.Remaining.HasValue ? "¥" + store.Remaining.Value.ToString("F2") : "暂不可用";
            }
            else
            {
                var quota = store.KeyInfo?["quota"];
                if (Known(quota, "remaining_percent_approx")) result.Percent = Clamp(quota.Number("remaining_percent_approx"));
                else if (Known(quota, "used_percent_approx")) result.Percent = Clamp(100 - quota.Number("used_percent_approx"));
                var shared = quota.Flag("follows_account");
                result.Label = shared ? "共享额度剩余" : "Key 可用额度";
                result.Value = shared || privacy ? Percentage(result.Percent) : Known(quota, "remaining_rmb") ? "¥" + quota.Number("remaining_rmb").ToString("F2") : "暂不可用";
            }
            return result;
        }
        private static double Clamp(double value) => Math.Max(0, Math.Min(100, value));
        private static bool Known(JToken token, string property) => token?[property] != null && token[property].Type != JTokenType.Null;
        private static string Percentage(double? value) => value.HasValue ? "约 " + value.Value.ToString("0") + "%" : "暂不可用";
    }
    public static class StartupPolicy
    {
        public static void Initialize(bool isolated, bool legacyPreferences, Preferences preferences, Func<bool> read, Action<bool> write, Action save)
        {
            if (isolated || preferences.StartupChoice.HasValue) return;
            if (legacyPreferences) { preferences.StartupChoice = read(); save(); return; }
            write(true);
            if (!read()) throw new InvalidOperationException("Windows 暂未保存启动项，可稍后在设置中重试");
            preferences.StartupChoice = true; save();
        }
    }
}
