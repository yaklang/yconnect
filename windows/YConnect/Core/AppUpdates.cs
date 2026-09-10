using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    public sealed class AppRelease
    {
        public const string Base = "https://aliyun-oss.yaklang.com/yconnect";
        public string Version, Notes;
        public static Version StableVersion(string value)
        {
            if (value == null || !Regex.IsMatch(value, @"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z") || !System.Version.TryParse(value, out var version)) throw new InvalidDataException("更新版本号无效");
            return version;
        }
        public static AppRelease Parse(string text, string current)
        {
            if (text.Length > 524288) throw new InvalidDataException("更新信息过大");
            var json = JObject.Parse(text); var value = json.Text("version"); var version = StableVersion(value);
            if (json.Number("schema_version") != 1 || json.Text("product") != "yconnect" || json.Text("release_notes") != "https://github.com/yaklang/yconnect/releases/tag/v" + value) throw new InvalidDataException("更新来源无效");
            var notes = json.Text("release_notes_text", ""); if (notes.Length > 32000) throw new InvalidDataException("更新说明过长");
            var assets = json.Array("assets").Where(a => a.Text("platform") == "windows" && a.Text("architecture") == "amd64" && a.Text("kind") == "setup").ToArray();
            var name = "YConnect-" + value + "-windows-x64-setup.exe";
            if (assets.Length != 1 || assets[0].Text("filename") != name || assets[0].Text("url") != Base + "/" + value + "/" + name || assets[0].Number("size") <= 0 || assets[0].Number("size") >= 536870912 || !Regex.IsMatch(assets[0].Text("sha256"), @"\A[0-9a-f]{64}\z")) throw new InvalidDataException("更新文件信息无效");
            return version > StableVersion(current) ? new AppRelease { Version = value, Notes = notes } : null;
        }
    }

    public sealed class AppUpdates : IDisposable
    {
        public AppRelease Release { get; private set; }
        public bool Checking { get; private set; }
        public bool Installing { get; private set; }
        public string Message { get; private set; }
        public DateTime? LastCheck { get; private set; }
        public bool Enabled { get; }
        public event Action Changed;
        private readonly AppController app;
        private readonly Dispatcher dispatcher;
        private readonly DispatcherTimer timer;
        private readonly HttpClient http;
        private bool initialized, disposed;
        private volatile bool canExit;
        public void RefreshShutdownState() { canExit = !app.Store.Busy && !app.ModalOpen && !app.Quitting && !app.Launches.Attempts.Any(a => a.State == "pending"); }
        // Native callbacks must stay rooted for the DLL's entire lifetime.
        private Callback onError, onShutdown, onCancelled, onNoUpdate;
        private CanShutdown canShutdown;
        public bool Automatic
        {
            get => app.Store.Preferences.CheckUpdates;
            set { app.Store.Preferences.CheckUpdates = value; app.Store.SavePreferences(); Changed?.Invoke(); }
        }
        public AppUpdates(AppController app)
        {
            this.app = app; dispatcher = Application.Current.Dispatcher; Enabled = !app.Store.Environment.Development;
            http = new HttpClient(new HttpClientHandler { UseCookies = false, UseDefaultCredentials = false, AllowAutoRedirect = false })
            { Timeout = TimeSpan.FromSeconds(25), MaxResponseContentBufferSize = 524288 };
            timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            timer.Tick += async (s, e) => { timer.Interval = TimeSpan.FromHours(6); if (Automatic) await Check(); };
            if (!Enabled) Message = "开发与演示环境不检查或安装正式更新。";
        }
        public void Start() { if (Enabled) timer.Start(); }
        public async Task Check()
        {
            if (!Enabled || disposed || Checking || Installing) return;
            Checking = true; Changed?.Invoke();
            try
            {
                using (var request = new HttpRequestMessage(HttpMethod.Get, AppRelease.Base + "/latest.json"))
                {
                    request.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };
                    // Buffer within HttpClient so its timeout also covers a stalled response body.
                    using (var response = await http.SendAsync(request, HttpCompletionOption.ResponseContentRead))
                    {
                        response.EnsureSuccessStatusCode();
                        if (response.Content.Headers.ContentLength > 524288) throw new InvalidDataException("更新信息过大");
                        Release = AppRelease.Parse(await response.Content.ReadAsStringAsync(), BuildInfo.Version);
                    }
                }
                LastCheck = DateTime.Now; Message = Release == null ? "已经是最新版本。" : "新版本已就绪，点击即可下载并更新。";
            }
            catch (Exception) { Message = "暂时无法获取有效更新信息，当前版本仍可使用，请检查网络后重试。"; }
            finally { Checking = false; if (!disposed) Changed?.Invoke(); }
        }
        public void Install()
        {
            if (!Enabled || Installing || disposed) return;
            RefreshShutdownState();
            if (!canExit) { app.Store.SetError("请先完成当前操作或等待 Agent 启动，再更新客户端。"); return; }
            // Portable copies are deliberately migrated through the installer;
            // never silently replace an arbitrary folder with an installed app.
            if (!File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "unins000.exe")) && !app.Confirm("安装新版 Y CONNECT？", "当前为便携版。将安装到本机的应用目录，保留账户数据与客户端配置；旧便携目录不会被删除。", "下载并安装")) return;
            try
            {
                Initialize(); Installing = true; Message = "正在下载并校验，安装完成后会重新打开 Y CONNECT。"; Changed?.Invoke();
                win_sparkle_check_update_with_ui_and_install();
            }
            catch (Exception) { Installing = false; Message = "更新组件暂时不可用，可重试或手动下载。"; Changed?.Invoke(); app.Store.SetError(Message); }
        }
        private void Initialize()
        {
            if (initialized) return;
            win_sparkle_set_app_details("YakLang", "Y CONNECT", BuildInfo.Version);
            win_sparkle_set_appcast_url(AppRelease.Base + "/appcast-windows.xml");
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("YConnect.UpdatePublicKey"))
            using (var reader = new StreamReader(stream)) { if (win_sparkle_set_eddsa_public_key(reader.ReadToEnd().Trim()) != 1) throw new InvalidDataException("更新公钥无效"); }
            win_sparkle_set_lang("zh_CN");
            win_sparkle_set_automatic_check_for_updates(0);
            onError = () => Post(() => { Installing = false; Message = "下载或签名校验失败，未安装更新。请重试或手动下载。"; Changed?.Invoke(); });
            onCancelled = () => Post(() => { Installing = false; Message = "已取消更新，可以继续使用当前版本。"; Changed?.Invoke(); });
            onNoUpdate = () => Post(() => { Installing = false; Release = null; Message = "已经是最新版本。"; Changed?.Invoke(); });
            RefreshShutdownState();
            canShutdown = () => canExit && !disposed ? 1 : 0;
            onShutdown = () => Post(app.Quit);
            win_sparkle_set_error_callback(onError); win_sparkle_set_update_cancelled_callback(onCancelled);
            win_sparkle_set_did_not_find_update_callback(onNoUpdate); win_sparkle_set_can_shutdown_callback(canShutdown);
            win_sparkle_set_shutdown_request_callback(onShutdown); win_sparkle_init(); initialized = true;
        }
        private void Post(Action action) { if (!disposed && !dispatcher.HasShutdownStarted) dispatcher.BeginInvoke(action); }
        public void OpenDownloads()
        {
            var version = Release?.Version ?? BuildInfo.Version;
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AppRelease.Base + "/" + version + "/YConnect-" + version + "-windows-x64-setup.exe") { UseShellExecute = true }); }
            catch (Exception) { app.Store.SetError("无法打开浏览器，请前往 yakcool.com 下载客户端。"); }
        }
        public void Dispose()
        {
            if (disposed) return; disposed = true; timer.Stop(); http.Dispose();
            if (initialized) win_sparkle_cleanup();
        }
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Callback();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int CanShutdown();
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_init();
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_cleanup();
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)] private static extern void win_sparkle_set_app_details(string company, string app, string version);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] private static extern void win_sparkle_set_appcast_url(string url);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] private static extern int win_sparkle_set_eddsa_public_key(string key);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] private static extern void win_sparkle_set_lang(string language);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_automatic_check_for_updates(int value);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_check_update_with_ui_and_install();
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_error_callback(Callback callback);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_update_cancelled_callback(Callback callback);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_did_not_find_update_callback(Callback callback);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_can_shutdown_callback(CanShutdown callback);
        [DllImport("WinSparkle.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void win_sparkle_set_shutdown_request_callback(Callback callback);
    }
}
