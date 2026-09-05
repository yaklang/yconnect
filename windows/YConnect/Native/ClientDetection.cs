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
            var executable = id == "claude-code" ? "claude" : id == "grok-build" ? "grok" : id == "gemini-cli" ? "gemini" : id;
            foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';').Where(p => !string.IsNullOrWhiteSpace(p)))
            {
                try { if (new[] { ".exe", ".cmd", ".bat", ".ps1" }.Any(ext => File.Exists(Path.Combine(directory.Trim('"'), executable + ext)))) return true; } catch { }
            }
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var candidates = new[] { Path.Combine(home, ".local", "bin", executable + ".exe"), Path.Combine(local, "Programs", executable, executable + ".exe") };
            if (id == "claude-desktop") candidates = new[] { Path.Combine(local, "Claude-3p", "Claude.exe"), Path.Combine(local, "Programs", "Claude-3p", "Claude.exe") };
            if (candidates.Any(File.Exists)) return true;
            try
            {
                foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
                using (var key = hive.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths\" + executable + ".exe"))
                    if (key?.GetValue("") is string path && File.Exists(path.Trim('"'))) return true;
            }
            catch { }
            return false;
        }
    }
}
