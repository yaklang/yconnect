using System;
using System.IO;
using System.Linq;
using Microsoft.Win32;
using YConnect.Core;

namespace YConnect.Native
{
    public static class ClientDetection
    {
        public static bool Installed(EnvironmentPaths env, string id)
        {
            if (env.Demo) return env.PreviewClients.Contains(id);
            return Resolve(id) != null;
        }
        public static string ResolveExecutable(string executable)
        {
            foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';').Where(p => !string.IsNullOrWhiteSpace(p)))
            {
                foreach (var ext in new[] { ".exe", ".cmd", ".bat", ".ps1" })
                { try { var path = Path.Combine(directory.Trim('"'), executable + ext); if (Path.IsPathRooted(path) && File.Exists(path)) return Path.GetFullPath(path); } catch { } }
            }
            return null;
        }
        public static string Resolve(string id)
        {
            var executable = id == "claude-code" ? "claude" : id == "grok-build" ? "grok" : id == "gemini-cli" ? "gemini" : id;
            var resolved = ResolveExecutable(executable); if (resolved != null) return resolved;
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var candidates = new[] { Path.Combine(home, ".local", "bin", executable + ".exe"), Path.Combine(local, "Programs", executable, executable + ".exe"), Path.Combine(home, "." + executable, "bin", executable + ".exe"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", executable + ".cmd") };
            if (id == "claude-desktop") candidates = new[] { Path.Combine(local, "Claude-3p", "Claude.exe"), Path.Combine(local, "Programs", "Claude-3p", "Claude.exe") };
            var candidate = candidates.FirstOrDefault(File.Exists); if (candidate != null) return candidate;
            if (id == "codex")
            {
                var bundled = Path.Combine(local, "OpenAI", "Codex", "bin");
                try { if (Directory.Exists(bundled)) { var cli = Directory.GetDirectories(bundled).Select(p => Path.Combine(p, "codex.exe")).Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault(); if (cli != null) return cli; } } catch { }
            }
            try
            {
                foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
                using (var key = hive.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths\" + executable + ".exe"))
                    if (key?.GetValue("") is string path && File.Exists(path.Trim('"'))) return path.Trim('"');
            }
            catch { }
            return null;
        }
    }
}
