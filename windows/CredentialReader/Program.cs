using System;
using System.IO;
using System.Reflection;
using System.Text;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 0) return 2;
            var exe = Assembly.GetExecutingAssembly().Location;
            var file = Path.Combine(Path.GetDirectoryName(exe), Path.GetFileNameWithoutExtension(exe) + "-yakcool-key");
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) return 3;
            var info = new FileInfo(file);
            if (info.Length == 0 || info.Length > 512) return 4;
            var key = File.ReadAllText(file, Encoding.UTF8).Trim();
            foreach (var ch in key) if (char.IsWhiteSpace(ch) || char.IsControl(ch)) return 4;
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.Write(key);
            return 0;
        }
        catch { return 1; }
    }
}
