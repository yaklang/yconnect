using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using Tomlyn;
using YamlDotNet.RepresentationModel;

namespace YConnect.Core
{
    public static class ConfigurationEditors
    {
        public static void ValidateToml(string source)
        {
            var syntax = Toml.Parse(source); if (syntax.HasErrors) throw new InvalidOperationException("TOML 配置格式无效，已停止写入");
        }
        public static void ValidateYaml(string source)
        {
            var yaml = new YamlStream(); yaml.Load(new StringReader(source));
            if (yaml.Documents.Count > 1) throw new InvalidOperationException("只支持单文档 YAML 配置");
            if (yaml.Documents.Count == 1 && !(yaml.Documents[0].RootNode is YamlMappingNode)) throw new InvalidOperationException("YAML 根节点必须是对象");
        }
        private static string Literal(JToken value)
        {
            if (value.Type == JTokenType.Object) return "{ " + string.Join(", ", ((JObject)value).Properties().Select(p => '"' + p.Name + "\" = " + Literal(p.Value))) + " }";
            return value.ToString(Newtonsoft.Json.Formatting.None);
        }
        public static string EditToml(string source, JObject rootValues, IDictionary<string, JObject> tables)
        {
            source = source ?? ""; ValidateToml(source);
            var output = new List<string>(); var table = ""; var remove = false; string triple = null;
            foreach (var line in Regex.Split(source, "\r?\n"))
            {
                if (triple == null)
                {
                    var header = Regex.Match(line, @"^\s*(\[\[?.+?\]\]?)\s*(?:#.*)?$");
                    if (header.Success)
                    {
                        // Parse the header through Tomlyn so quoted table segments
                        // cannot silently evade ownership matching.
                        var probe = Toml.ToModel(header.Groups[1].Value + "\n__yconnect_probe = true");
                        object node = probe; var keys = new List<string>();
                        while (node != null)
                        {
                            if (node is Tomlyn.Model.TomlTableArray array) { node = array[0]; continue; }
                            if (!(node is Tomlyn.Model.TomlTable map)) break;
                            var key = map.Keys.First(); if (key == "__yconnect_probe") break;
                            keys.Add(key); node = map[key];
                        }
                        table = string.Join(".", keys);
                        remove = tables.Keys.Any(k => table == k || table.StartsWith(k + ".", StringComparison.Ordinal));
                    }
                    if (table == "" && rootValues.Properties().Any(p => Regex.IsMatch(line, @"^\s*(?:" + Regex.Escape(p.Name) + "|\"" + Regex.Escape(p.Name) + "\"|'" + Regex.Escape(p.Name) + @"')\s*=")))
                    {
                        if (line.Contains("\"\"\"") || line.Contains("'''")) throw new InvalidOperationException("受管理的顶层字段使用多行 TOML，请先改为单行");
                        continue;
                    }
                }
                if (!remove) output.Add(line);
                char? quote = null;
                for (var i = 0; i < line.Length; i++)
                {
                    var next = line.Substring(i, Math.Min(3, line.Length - i));
                    if (triple != null)
                    {
                        if (next == triple && (triple == "'''" || i == 0 || line[i - 1] != '\\')) { triple = null; i += 2; }
                    }
                    else if (quote != null) { if (line[i] == quote && (quote == '\'' || i == 0 || line[i - 1] != '\\')) quote = null; }
                    else if (line[i] == '#') break;
                    else if (next == "\"\"\"" || next == "'''") { triple = next; i += 2; }
                    else if (line[i] == '\'' || line[i] == '"') quote = line[i];
                }
            }
            while (output.Count > 0 && string.IsNullOrWhiteSpace(output[output.Count - 1])) output.RemoveAt(output.Count - 1);
            var roots = rootValues.Properties().Select(p => p.Name + " = " + Literal(p.Value));
            var blocks = tables.Select(t => "[" + t.Key + "]\n" + string.Join("\n", t.Value.Properties().Select(p => p.Name + " = " + Literal(p.Value))));
            var newline = source.Contains("\r\n") ? "\r\n" : "\n";
            var result = string.Join(newline, roots.Concat(output).Concat(new[] { "" }).Concat(blocks)) + newline;
            ValidateToml(result); return result;
        }
        public static string SetYamlBlock(string source, string[] path, string[] body)
        {
            source = source ?? ""; if (source.Trim().Length > 0) ValidateYaml(source);
            var lines = Regex.Split(source, "\r?\n").ToList();
            while (lines.Count > 0 && string.IsNullOrWhiteSpace(lines[lines.Count - 1])) lines.RemoveAt(lines.Count - 1);
            var start = 0; var end = lines.Count; var indent = 0;
            for (var level = 0; level < path.Length; level++)
            {
                var candidates = Enumerable.Range(start, end - start).Where(i => Regex.IsMatch(lines[i], "^" + new string(' ', indent) + "(?:" + Regex.Escape(path[level]) + "|\"" + Regex.Escape(path[level]) + "\"|'" + Regex.Escape(path[level]) + "'):")).ToArray();
                if (candidates.Length > 1) throw new InvalidOperationException("YAML 含有重复管理字段");
                if (candidates.Length == 0)
                {
                    lines.Insert(end, new string(' ', indent) + path[level] + ":"); start = end + 1; end = start;
                }
                else
                {
                    var index = candidates[0]; var tail = lines[index].Substring(lines[index].IndexOf(':') + 1).Trim();
                    if (tail.Length > 0 && !tail.StartsWith("#") && level != path.Length - 1) throw new InvalidOperationException("受管理的 YAML 祖先必须使用块映射");
                    start = index + 1;
                    end = start;
                    while (end < lines.Count && (string.IsNullOrWhiteSpace(lines[end]) || lines[end].TrimStart().StartsWith("#") || lines[end].TakeWhile(c => c == ' ').Count() > indent)) end++;
                    if (level == path.Length - 1) { lines[index] = new string(' ', indent) + path[level] + ":"; }
                }
                indent += 2;
                if (level == path.Length - 1)
                {
                    lines.RemoveRange(start, end - start);
                    lines.InsertRange(start, body.Select(l => new string(' ', indent) + l));
                }
            }
            var newline = source.Contains("\r\n") ? "\r\n" : "\n";
            var result = string.Join(newline, lines).TrimEnd('\r', '\n') + newline; ValidateYaml(result); return result;
        }
        public static string RedactPreview(string source)
        {
            // Redact unowned providers too. This is a display-only transformation.
            return Regex.Replace(source, "(?im)^([^\\n]*(?:api.?key|token|secret|password|authorization|cookie)[^:=\\n]*[:=]\\s*)([^\\n]*)", m => Regex.IsMatch(m.Groups[1].Value, "helper|key_cmd", RegexOptions.IgnoreCase) ? m.Value : m.Groups[1].Value + "\"[已隐藏]\"");
        }
    }
}
