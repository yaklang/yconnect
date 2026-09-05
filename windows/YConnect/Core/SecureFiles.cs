using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Newtonsoft.Json.Linq;

namespace YConnect.Core
{
    public static class SecureFiles
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("io.yaklang.yconnect.windows.v1");
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfoNative
        {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfoNative info);
        public static void AssertPlainPath(string target)
        {
            var current = Path.GetFullPath(target);
            while (!string.IsNullOrEmpty(current))
            {
                if (File.Exists(current) || Directory.Exists(current))
                    if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("拒绝链接或重解析路径：" + current);
                var parent = Path.GetDirectoryName(current); if (parent == current) break; current = parent;
            }
            if (File.Exists(target))
            {
                using (var file = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    if (!GetFileInformationByHandle(file.SafeFileHandle, out var info) || info.Links > 1) throw new IOException("文件具有硬链接或无法验证：" + target);
            }
        }
        public static byte[] Read(string target)
        {
            AssertPlainPath(target); if (!File.Exists(target)) return null;
            if (new FileInfo(target).Length > 5 * 1024 * 1024) throw new IOException("配置文件过大：" + target);
            return File.ReadAllBytes(target);
        }
        public static string ReadText(string path)
        {
            var bytes = Read(path); if (bytes == null) return null;
            var offset = bytes.Length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
            return new UTF8Encoding(false, true).GetString(bytes, offset, bytes.Length - offset);
        }
        public static string Hash(byte[] bytes)
        {
            if (bytes == null) return null;
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        public static void ProtectDirectory(string directory)
        {
            AssertPlainPath(directory); Directory.CreateDirectory(directory);
            var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            foreach (var user in new[] { WindowsIdentity.GetCurrent().User, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                acl.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(directory, acl);
        }
        public static void ProtectFile(string file)
        {
            var acl = new FileSecurity(); acl.SetAccessRuleProtection(true, false);
            foreach (var user in new[] { WindowsIdentity.GetCurrent().User, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                acl.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
            File.SetAccessControl(file, acl);
        }
        public static void AtomicWrite(string target, byte[] data, bool secure = false)
        {
            AssertPlainPath(target); var directory = Path.GetDirectoryName(target); Directory.CreateDirectory(directory);
            if (secure) ProtectDirectory(directory);
            var temporary = Path.Combine(directory, ".yconnect-" + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(data, 0, data.Length); file.Flush(true); }
                if (secure) ProtectFile(temporary);
                AssertPlainPath(target);
                if (File.Exists(target)) File.Replace(temporary, target, null); else File.Move(temporary, target);
                if (secure) ProtectFile(target);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        public static void WriteText(string target, string text, bool secure = false) => AtomicWrite(target, new UTF8Encoding(false).GetBytes(text), secure);
        public static byte[] Encrypt(byte[] data) => ProtectedData.Protect(data, Entropy, DataProtectionScope.CurrentUser);
        public static byte[] Decrypt(byte[] data) => ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
        public static JObject LoadSession(EnvironmentPaths env)
        {
            var data = Read(Path.Combine(env.DataRoot, "Credentials", "session.bin"));
            return data == null ? null : Json.Parse(Encoding.UTF8.GetString(Decrypt(data)));
        }
        public static void SaveSession(EnvironmentPaths env, JObject auth) => AtomicWrite(Path.Combine(env.DataRoot, "Credentials", "session.bin"), Encrypt(Encoding.UTF8.GetBytes(auth.ToString())), true);
        public static void ClearSession(EnvironmentPaths env)
        {
            var file = Path.Combine(env.DataRoot, "Credentials", "session.bin"); AssertPlainPath(file); if (File.Exists(file)) File.Delete(file);
        }
    }
    public sealed class FileChange
    {
        public string Path { get; set; }
        public string Role { get; set; } = "configuration";
        public byte[] Before { get; set; }
        public byte[] After { get; set; }
        public string BeforeHash => SecureFiles.Hash(Before);
        public string AfterHash => SecureFiles.Hash(After);
        public string Action => BeforeHash == AfterHash ? "无需更改" : Before == null ? "创建" : "更新";
    }
    public sealed class ConfigurationPlan
    {
        public string Id { get; } = Guid.NewGuid().ToString("N");
        public DateTime Created { get; } = DateTime.UtcNow;
        public string Client { get; set; }
        public List<FileChange> Changes { get; } = new List<FileChange>();
        public void Add(string file, string text, string role = "configuration") => Add(file, new UTF8Encoding(false).GetBytes(text), role);
        public void Add(string file, byte[] data, string role)
        {
            file = Path.GetFullPath(file);
            if (Changes.Any(c => c.Path.Equals(file, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("配置目标重复");
            Changes.Add(new FileChange { Path = file, Role = role, Before = SecureFiles.Read(file), After = data });
        }
    }
    public sealed class Transactions
    {
        private readonly string root;
        public Action<int, FileChange> BeforeWrite { get; set; }
        public Action<ConfigurationPlan> ValidateWritten { get; set; }
        public Transactions(EnvironmentPaths env) { root = Path.Combine(env.DataRoot, "Backups"); }
        private IEnumerable<(string Directory, JObject Manifest)> History(string client)
        {
            var directory = Path.Combine(root, client); SecureFiles.AssertPlainPath(directory);
            if (!Directory.Exists(directory)) yield break;
            foreach (var item in Directory.GetDirectories(directory).OrderByDescending(p => p, StringComparer.Ordinal))
            {
                JObject manifest = null;
                try { manifest = Json.Parse(SecureFiles.ReadText(Path.Combine(item, "manifest.json"))); } catch { }
                if (manifest != null) yield return (item, manifest);
            }
        }
        public JObject Latest(string client) => History(client).Select(h => h.Manifest).FirstOrDefault(m => m.Text("status") == "applied");
        public string Apply(ConfigurationPlan plan)
        {
            if (DateTime.UtcNow - plan.Created > TimeSpan.FromMinutes(5)) throw new InvalidOperationException("预览已过期，请重新预览");
            foreach (var f in plan.Changes) if (SecureFiles.Hash(SecureFiles.Read(f.Path)) != f.BeforeHash) throw new IOException("配置已被其他程序修改，请重新预览");
            var changes = plan.Changes.Where(c => c.BeforeHash != c.AfterHash).ToList();
            if (changes.Count == 0) return "配置已是目标状态，无需重复写入";
            var directory = Path.Combine(root, plan.Client, DateTime.UtcNow.ToString("yyyyMMddHHmmssffff") + "-" + plan.Id);
            SecureFiles.ProtectDirectory(directory);
            var files = new JArray();
            for (var i = 0; i < changes.Count; i++)
            {
                var f = changes[i]; var blob = f.Before == null ? null : i + ".bin";
                if (blob != null) SecureFiles.AtomicWrite(Path.Combine(directory, blob), SecureFiles.Encrypt(f.Before), true);
                files.Add(new JObject { ["path"] = f.Path, ["role"] = f.Role, ["beforeHash"] = f.BeforeHash, ["afterHash"] = f.AfterHash, ["blob"] = blob });
            }
            var manifest = new JObject { ["version"] = 1, ["client"] = plan.Client, ["status"] = "prepared", ["created"] = DateTime.UtcNow.ToString("o"), ["files"] = files };
            Action save = () => SecureFiles.WriteText(Path.Combine(directory, "manifest.json"), Json.Stringify(manifest), true);
            save(); var written = new List<FileChange>();
            try
            {
                for (var i = 0; i < changes.Count; i++)
                {
                    var f = changes[i]; BeforeWrite?.Invoke(i, f);
                    if (SecureFiles.Hash(SecureFiles.Read(f.Path)) != f.BeforeHash) throw new IOException("写入前检测到外部修改");
                    SecureFiles.AtomicWrite(f.Path, f.After, f.Role != "configuration"); written.Add(f);
                }
                foreach (var f in changes) if (SecureFiles.Hash(SecureFiles.Read(f.Path)) != f.AfterHash) throw new IOException("写后校验失败");
                ValidateWritten?.Invoke(plan); manifest["status"] = "applied"; save();
            }
            catch (Exception error)
            {
                var conflict = false;
                foreach (var f in Enumerable.Reverse(written))
                {
                    if (SecureFiles.Hash(SecureFiles.Read(f.Path)) != f.AfterHash) { conflict = true; continue; }
                    if (f.Before == null) File.Delete(f.Path); else SecureFiles.AtomicWrite(f.Path, f.Before, f.Role != "configuration");
                }
                manifest["status"] = conflict ? "recovery-required" : "rolled-back"; save();
                throw new IOException(error.Message + (conflict ? "；外部修改已保留，恢复快照位于 " + directory : "；本次写入已回滚"), error);
            }
            foreach (var old in History(plan.Client).Where(h => new[] { "applied", "restored", "rolled-back" }.Contains(h.Manifest.Text("status"))).Skip(20))
            {
                if (!Path.GetFullPath(old.Directory).StartsWith(Path.GetFullPath(Path.Combine(root, plan.Client)) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("备份目录无效");
                SecureFiles.AssertPlainPath(old.Directory); Directory.Delete(old.Directory, true);
            }
            return "配置已应用，原文件已加密备份。请重启目标客户端会话。";
        }
        public string Restore(string client, IEnumerable<string> allowedPaths)
        {
            var item = History(client).FirstOrDefault(h => h.Manifest.Text("status") == "applied");
            if (item.Manifest == null) throw new InvalidOperationException("还没有可恢复的备份");
            var allowed = new HashSet<string>(allowedPaths.Select(Path.GetFullPath), StringComparer.OrdinalIgnoreCase);
            var changes = new List<FileChange>();
            foreach (var f in item.Manifest.Array("files"))
            {
                var file = f.Text("path"); if (!allowed.Contains(Path.GetFullPath(file))) throw new IOException("备份包含非本适配器目标");
                var current = SecureFiles.Read(file); if (SecureFiles.Hash(current) != f.Text("afterHash", null)) throw new IOException("配置在应用后被其他程序修改，已停止恢复以保护你的更改");
                var blob = f.Text("blob", null); byte[] original = null;
                if (blob != null)
                {
                    if (!System.Text.RegularExpressions.Regex.IsMatch(blob, @"\A\d+\.bin\z")) throw new IOException("备份文件名无效");
                    original = SecureFiles.Decrypt(SecureFiles.Read(Path.Combine(item.Directory, blob)));
                }
                if (SecureFiles.Hash(original) != f.Text("beforeHash", null)) throw new IOException("备份完整性校验失败");
                changes.Add(new FileChange { Path = file, Before = current, After = original, Role = f.Text("role") });
            }
            var written = new List<FileChange>();
            try
            {
                foreach (var f in changes)
                {
                    if (SecureFiles.Hash(SecureFiles.Read(f.Path)) != f.BeforeHash) throw new IOException("恢复过程中检测到外部修改");
                    if (f.After == null) File.Delete(f.Path); else SecureFiles.AtomicWrite(f.Path, f.After, f.Role != "configuration"); written.Add(f);
                }
                foreach (var f in changes) if (SecureFiles.Hash(SecureFiles.Read(f.Path)) != f.AfterHash) throw new IOException("恢复后的校验失败");
            }
            catch
            {
                foreach (var f in Enumerable.Reverse(written)) if (SecureFiles.Hash(SecureFiles.Read(f.Path)) == f.AfterHash) SecureFiles.AtomicWrite(f.Path, f.Before, f.Role != "configuration");
                throw;
            }
            item.Manifest["status"] = "restored"; SecureFiles.WriteText(Path.Combine(item.Directory, "manifest.json"), Json.Stringify(item.Manifest), true);
            return "最近备份已恢复，内容与原文件一致。请重启目标客户端。";
        }
    }
}
