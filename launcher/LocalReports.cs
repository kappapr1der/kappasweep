using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace KappaSweepLauncher;

internal sealed record LocalFile(string Label, string? Path, DateTime Time);
internal sealed record ReportRow(string Label, string Size, string Status, string Path, long Bytes = 0);
internal sealed record ReportView(string Summary, IReadOnlyList<ReportRow> Rows, bool IsStorage = false,
    IReadOnlyList<string>? Drives = null, bool IsTruncated = false);

internal static class LocalReports
{
    public static IReadOnlyList<LocalFile> Find(IEnumerable<string> folders, bool reports)
    {
        var files = new List<FileInfo>();
        foreach (var folder in folders.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                if (!Directory.Exists(folder)) continue;
                files.AddRange(new DirectoryInfo(folder).EnumerateFiles(reports ? "*.json" : "*.log")
                    .Where(file => reports
                        ? file.Name.StartsWith("report-", StringComparison.OrdinalIgnoreCase)
                          || file.Name.StartsWith("space-", StringComparison.OrdinalIgnoreCase)
                        : file.Name.StartsWith("run-", StringComparison.OrdinalIgnoreCase)
                          || file.Name.StartsWith("cleanup-", StringComparison.OrdinalIgnoreCase))
                    .OrderByDescending(file => file.LastWriteTime).Take(80));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return files.DistinctBy(file => file.FullName, StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(file => file.LastWriteTime).Take(80)
            .Select(file => new LocalFile($"{file.LastWriteTime:dd.MM.yyyy HH:mm:ss} · {Kind(file.Name)}", file.FullName, file.LastWriteTime))
            .ToArray();
    }

    private static string Kind(string name) => name.StartsWith("space-", StringComparison.OrdinalIgnoreCase)
        ? "Диагностика места" : name.StartsWith("run-", StringComparison.OrdinalIgnoreCase) ? "Запуск" : "Очистка";

    public static string ReadLogTail(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var truncated = stream.Length > 300_000;
        if (truncated) stream.Seek(-300_000, SeekOrigin.End);
        using var reader = new StreamReader(stream, Encoding.UTF8, true);
        var text = reader.ReadToEnd();
        if (text.Length > 100_000) text = text[^100_000..];
        return (truncated ? "Показан конец большого журнала. Полный текст доступен через «Открыть файл».\n\n" : "") + text;
    }

    public static ReportView Read(string path)
    {
        if (Path.GetExtension(path).Equals(".log", StringComparison.OrdinalIgnoreCase))
            return ReadLegacyLog(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        if (stream.Length > 8 * 1024 * 1024) throw new InvalidDataException("Отчёт превышает лимит 8 МБ.");
        var report = JsonNode.Parse(stream) as JsonObject ?? throw new InvalidDataException("Некорректный отчёт.");
        if (report["schemaVersion"]?.GetValue<int>() != 1) throw new InvalidDataException("Неизвестный формат отчёта.");
        var storage = Text(report, "kind") == "storage";
        var results = report["results"] as JsonArray ?? new JsonArray();
        var rows = results.OfType<JsonObject>().Take(2000).Select(row => storage
            ? new ReportRow(Text(row, "Name"), Size(Number(row, "SizeBytes")), Text(row, "Action"), Text(row, "Path"), Math.Max(0, Number(row, "SizeBytes")))
            : new ReportRow(Text(row, "Label"), Size(Number(row, "Bytes")), Status(Text(row, "Status")), Text(row, "Path"), Math.Max(0, Number(row, "Bytes"))))
            .ToArray();
        var mode = Text(report, "mode");
        var summary = storage ? "Диагностика места. Файлы не удалялись."
            : $"{(mode.Equals("Clean", StringComparison.OrdinalIgnoreCase) ? "Очищено" : "Можно освободить")}: {Size(Number(report, "totalBytes"))}. Объектов: {Number(report, "totalItems"):N0}. Профиль: {Text(report, "profile")}.";
        if (!storage && report["after"] is JsonObject after)
            summary += $" Свободно после: {Size(Number(after, "FreeBytes"))}.";
        var tips = (report["tips"] as JsonArray)?.Select(node => node?.GetValue<string>()).Where(tip => !string.IsNullOrWhiteSpace(tip)).Take(5);
        if (tips is not null) summary += "\n" + string.Join("\n", tips);
        var drives = (report["drives"] as JsonArray)?.OfType<JsonObject>()
            .Select(drive => Text(drive, "Drive")).ToArray();
        return new ReportView(summary, rows, storage, drives, results.Count > 2000);
    }

    private static ReportView ReadLegacyLog(string path)
    {
        var text = ReadLogTail(path);
        var rows = Regex.Matches(text, @"(?:Cleaned|Would clean) (?<label>.+): (?<items>\d+) item\(s\), about (?<size>[\d.,]+\s+(?:GB|MB|KB|bytes))\.", RegexOptions.IgnoreCase)
            .Take(2000).Select(match => new ReportRow(match.Groups["label"].Value, match.Groups["size"].Value,
                match.Value.StartsWith("Would", StringComparison.OrdinalIgnoreCase) ? "Предварительный расчёт" : "Очищено", ""))
            .ToArray();
        var finish = text.Split('\n').LastOrDefault(line => line.Contains("finished.", StringComparison.OrdinalIgnoreCase)) ?? "";
        var summary = Regex.Match(finish, @"(?<verb>Removed|Would clean) (?<items>\d+) item\(s\), (?:reclaimed about|about) (?<size>[\d.,]+\s+(?:GB|MB|KB|bytes)), blocked: (?<blocked>\d+), errors: (?<errors>\d+)", RegexOptions.IgnoreCase);
        var description = summary.Success
            ? $"{(summary.Groups["verb"].Value == "Removed" ? "Очищено" : "Можно освободить")}: {summary.Groups["size"].Value}. Объектов: {summary.Groups["items"].Value}; занято: {summary.Groups["blocked"].Value}; ошибок: {summary.Groups["errors"].Value}."
            : "Подробный вывод доступен во вкладке «Журнал».";
        return new ReportView("Архивный запуск. " + description, rows);
    }

    private static string Text(JsonObject value, string key) => value[key]?.GetValue<string>() ?? "";
    private static long Number(JsonObject value, string key) => value[key]?.GetValue<long>() ?? 0;
    private static string Status(string value) => value.ToLowerInvariant() switch
    {
        "cleaned" => "Очищено", "would clean" => "Можно очистить", "empty" => "Нет старых файлов",
        "missing" => "Папка отсутствует", "excluded" => "Исключено", "unsafe" => "Защищено",
        "inaccessible" => "Нет доступа", "partial" => "Частично", "skipped" => "Пропущено",
        _ => value
    };
    internal static string Size(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):N2} ГБ",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):N1} МБ",
        >= 1L << 10 => $"{bytes / 1024d:N1} КБ", _ => $"{bytes} Б"
    };
}
