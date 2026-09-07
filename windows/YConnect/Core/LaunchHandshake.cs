using System;
using System.ComponentModel;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace YConnect.Core
{
    public sealed class LaunchFailure
    {
        public string Stage { get; set; }
        public string Kind { get; set; }
        public int Code { get; set; }
        public string Message { get; set; }
        public static LaunchFailure From(Exception error, string stage)
        {
            // Deliberately do not serialize exception messages, command lines or environments.
            var text = stage == "read-session" ? "启动会话文件不可读取，请从 Y CONNECT 重新启动。" : stage == "decrypt-session" ? "启动会话无法解密，请确认终端与 Y CONNECT 使用同一个 Windows 账户。" : stage == "check-session" ? "启动请求已过期或无效，请从 Y CONNECT 重新启动。" : stage == "start-shell" ? "系统终端未能启动，请检查 Windows PowerShell / CMD 是否可用。" : "客户端未能启动，请重新检测客户端安装。";
            if (error is DirectoryNotFoundException) text = stage == "read-session" ? "启动会话目录不可读取，请从 Y CONNECT 重新启动；这不代表工作目录不存在。" : "工作目录已不存在，请重新选择文件夹。";
            if (error is FileNotFoundException && stage == "start-client") text = "客户端程序已移动或卸载，请重新检测安装。";
            if (error is UnauthorizedAccessException) text = "Windows 拒绝访问启动文件，请检查文件权限或安全软件记录。";
            if (error is Win32Exception win32 && win32.NativeErrorCode == 193) text = "客户端入口不是有效的 Windows 可执行程序，请重新检测安装。";
            return new LaunchFailure { Stage = stage, Kind = error.GetType().Name, Code = error is Win32Exception native ? native.NativeErrorCode : error.HResult, Message = text };
        }
        public override string ToString() => Message + " [" + Stage + "/" + Kind + "/" + Code + "]";
    }
    public static class LaunchHandshake
    {
        private sealed class ProcessStamp { public int Id; public long Started; }
        public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(2);
        public static void TrackProcess(string receipt, string name, Process process)
        {
            WriteAtomic(Path.Combine(Path.GetDirectoryName(receipt), name + "-process.json"), JsonConvert.SerializeObject(new ProcessStamp { Id = process.Id, Started = process.StartTime.ToUniversalTime().Ticks }));
        }
        public static bool? IsRunning(string directory, string name)
        {
            var file = Path.Combine(directory, name + "-process.json"); AssertPlainPath(file);
            if (!File.Exists(file)) return null;
            if (new FileInfo(file).Length > 256) throw new InvalidDataException("Invalid process receipt");
            var stamp = JsonConvert.DeserializeObject<ProcessStamp>(File.ReadAllText(file));
            if (stamp == null) throw new InvalidDataException("Invalid process receipt");
            try { using (var process = Process.GetProcessById(stamp.Id)) return !process.HasExited && process.StartTime.ToUniversalTime().Ticks == stamp.Started; }
            catch (ArgumentException) { return false; }
        }
        public static string Receipt(string manifest) => Path.Combine(Path.GetDirectoryName(manifest), "started.txt");
        public static void Ready(string receipt) { if (receipt != null) WriteAtomic(receipt, "ready"); }
        public static void Failed(string receipt, LaunchFailure failure)
        {
            if (receipt == null) return;
            WriteAtomic(Path.Combine(Path.GetDirectoryName(receipt), "launch-error.json"), JsonConvert.SerializeObject(failure));
            WriteAtomic(receipt, "failed");
        }
        private static void WriteAtomic(string file, string text)
        {
            AssertPlainPath(file);
            var temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try { File.WriteAllText(temporary, text, new UTF8Encoding(false)); if (File.Exists(file)) File.Replace(temporary, file, null); else File.Move(temporary, file); }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        public static void AssertPlainPath(string path)
        {
            for (var current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked launch path rejected");
        }
        public static string ReadResult(string manifest)
        {
            var receipt = Receipt(manifest); AssertPlainPath(receipt);
            if (!File.Exists(receipt)) return null;
            var value = File.ReadAllText(receipt);
            if (value == "ready") return value;
            if (value == "failed")
            {
                var errorFile = Path.Combine(Path.GetDirectoryName(manifest), "launch-error.json"); AssertPlainPath(errorFile);
                if (File.Exists(errorFile) && new FileInfo(errorFile).Length < 4096)
                {
                    var failure = JsonConvert.DeserializeObject<LaunchFailure>(File.ReadAllText(errorFile));
                    if (failure != null) throw new InvalidOperationException(failure.ToString());
                }
                throw new InvalidOperationException("启动器报告失败，请查看终端错误提示。");
            }
            throw new InvalidOperationException("启动回执无效，请重新打开会话。");
        }
        public static async Task WaitForReady(string manifest, TimeSpan timeout, CancellationToken cancellation = default)
        {
            var watch = System.Diagnostics.Stopwatch.StartNew();
            do
            {
                cancellation.ThrowIfCancellationRequested();
                if (ReadResult(manifest) == "ready") return;
                if (IsRunning(Path.GetDirectoryName(manifest), "bootstrap") == false || IsRunning(Path.GetDirectoryName(manifest), "shell") == false)
                    throw new InvalidOperationException("本次终端已关闭或启动进程已退出。可以立即启动新会话，其他会话不受影响。");
                await Task.Delay(100, cancellation).ConfigureAwait(false);
            } while (watch.Elapsed < timeout);
            throw new TimeoutException("本次终端尚未确认就绪，可以继续启动其他会话。待交接请求保留两分钟，已打开的终端仍可继续完成启动。");
        }
        public static void DeleteExpired(string manifest)
        {
            AssertPlainPath(manifest);
            if (Path.GetFileName(manifest) == "session.bin" && File.Exists(manifest) && DateTime.UtcNow - File.GetLastWriteTimeUtc(manifest) > Lifetime) File.Delete(manifest);
        }
        public static async Task ExpireLater(string manifest)
        {
            await Task.Delay(Lifetime + TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            try { DeleteExpired(manifest); } catch { /* A later launch retries cleanup; never touch a linked or active path. */ }
        }
    }
}
