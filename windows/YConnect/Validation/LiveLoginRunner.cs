using System;
using System.IO;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using YConnect.Core;
using YConnect.Views;

namespace YConnect.Validation
{
    public static class LiveLoginRunner
    {
        // No credentials are supplied, extracted, logged or simulated here.
        public static async Task<bool> Run(AppController app, string output)
        {
            Directory.CreateDirectory(output); var report = new JObject(); WebLoginWindow login = null;
            try
            {
                report["bypassProxy"] = app.Store.Environment.BypassProxy; report["health"] = await app.Store.Api.Get("/api/health");
                login = new WebLoginWindow(app); login.Show();
                var completed = await Task.WhenAny(login.Ready, Task.Delay(45000));
                if (completed != login.Ready || !await login.Ready) throw new InvalidOperationException(login.StatusText);
                var until = DateTime.UtcNow.AddSeconds(30); JObject page = null;
                do
                {
                    page = JObject.Parse(JsonConvert.DeserializeObject<string>(await login.PageReadiness()));
                    if (page.Flag("loginFrame")) break;
                    await Task.Delay(500);
                } while (DateTime.UtcNow < until);
                await Task.Delay(2000); report["page"] = page; report["url"] = login.PageAddress;
                using (var file = File.Create(Path.Combine(output, "official-login-webview.png"))) await login.CapturePage(file);
                await NativeCapture.Save(login, Path.Combine(output, "official-login-native.png"));
                report["qrFrameLoaded"] = page?.Flag("loginFrame") ?? false;
                report["accountAuthorized"] = app.Store.Authenticated;
                report["note"] = "Official login page and WeChat frame loading only; real authorization requires the user's scan.";
                report["pass"] = page?.Flag("loginFrame") ?? false;
            }
            catch (Exception e) { report["pass"] = false; report["error"] = YakCoolApi.Redact(e.Message); }
            finally { login?.Close(); File.WriteAllText(Path.Combine(output, "live-login-results.json"), report.ToString()); }
            return report.Flag("pass");
        }
    }
}
