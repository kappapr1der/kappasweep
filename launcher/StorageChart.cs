using System.IO;
using System.Text.Json;

namespace KappaSweepLauncher;

internal sealed record StorageSlice(string Label, long Bytes, double Percent, string Color, IReadOnlyList<ReportRow> Rows)
{
    public string Value => $"{LocalReports.Size(Bytes)} · {Percent:N1}%";
    public string Description => $"{Label}: {Value}";
}

internal sealed record StorageChartView(IReadOnlyList<StorageSlice> Slices, long TotalBytes, int OverlapCount, int UnmappedCount);

internal static class StorageChart
{
    private static readonly string[] Palette = ["#15847B", "#4479D0", "#D2654B", "#9270B5", "#C99A28", "#45884D", "#CB5B85"];

    private static string? CanonicalPath(string path)
    {
        try
        {
            var local = path.Replace('/', '\\');
            if (local.Length < 3 || !char.IsAsciiLetter(local[0]) || local[1] != ':' || local[2] != '\\') return null;
            return Path.GetFullPath(local).TrimEnd('\\');
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }

    internal static string? DriveOf(string path) => CanonicalPath(path)?[..2].ToUpperInvariant();

    public static IReadOnlyList<string> Drives(ReportView report) => report.Rows.Select(row => DriveOf(row.Path))
        .Concat((report.Drives ?? []).Select(drive => DriveOf(drive.TrimEnd('\\') + "\\")))
        .OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToArray();

    public static IReadOnlyList<ReportRow> FilterRows(IReadOnlyList<ReportRow> rows, string drive) => string.IsNullOrEmpty(drive)
        ? rows : rows.Where(row => string.Equals(DriveOf(row.Path), drive, StringComparison.OrdinalIgnoreCase)).ToArray();

    public static StorageChartView Create(IReadOnlyList<ReportRow> rows, string drive = "")
    {
        var candidates = FilterRows(rows, drive).Where(row => row.Bytes > 0).Take(2000)
            .Select(row => (Row: row, Path: CanonicalPath(row.Path))).ToArray();
        var distinct = candidates.Where(item => item.Path is not null)
            .GroupBy(item => item.Path!, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.OrderByDescending(item => item.Row.Bytes).First())
            .OrderBy(item => item.Path!.Length).ThenBy(item => item.Path, StringComparer.OrdinalIgnoreCase).ToArray();
        var roots = new List<(ReportRow Row, string? Path)>();
        // A parent measurement already includes its descendants; keep only disjoint roots.
        foreach (var item in distinct)
            if (!roots.Any(parent => item.Path!.StartsWith(parent.Path + "\\", StringComparison.OrdinalIgnoreCase))) roots.Add(item);
        var sorted = roots.OrderByDescending(item => item.Row.Bytes).ThenBy(item => item.Path, StringComparer.OrdinalIgnoreCase).ToArray();
        long Sum(IEnumerable<ReportRow> items)
        {
            try { return items.Aggregate(0L, (total, row) => checked(total + row.Bytes)); }
            catch (OverflowException) { throw new InvalidDataException("Размеры целей в отчёте превышают допустимый предел."); }
        }
        var total = Sum(sorted.Select(item => item.Row));
        var slices = sorted.Take(7).Select((item, index) => new StorageSlice(item.Row.Label, item.Row.Bytes,
            item.Row.Bytes * 100d / total, Palette[index], [item.Row])).ToList();
        if (sorted.Length > 7)
        {
            var rest = sorted.Skip(7).Select(item => item.Row).ToArray();
            var restBytes = Sum(rest);
            slices.Add(new StorageSlice("Прочее", restBytes, restBytes * 100d / total, "#7A8B92", rest));
        }
        var unmapped = candidates.Count(item => item.Path is null);
        return new StorageChartView(slices, total, candidates.Length - unmapped - roots.Count, unmapped);
    }
}

internal sealed record ReportPreferences(string Mode = "diagram", string Drive = "")
{
    public static ReportPreferences Load(string path)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length > 4096) return new();
            var value = JsonSerializer.Deserialize<ReportPreferences>(File.ReadAllText(path));
            return value is null ? new() : new(value.Mode == "list" ? "list" : "diagram", value.Drive ?? "");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }

    public void Save(string path)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
