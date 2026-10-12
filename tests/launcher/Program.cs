using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using System.Net;
using System.Security.Cryptography;
using System.Diagnostics;
using KappaSweepLauncher;

if (args.Length != 2) throw new ArgumentException("Expected test directory and built EXE.");
var root = Path.GetFullPath(args[0]);
var folder = Path.Combine(root, "launcher-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(folder);
var passed = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new Exception("FAIL: " + name);
    passed++;
    Console.WriteLine("PASS: " + name);
}
void Reject(Action action, string name)
{
    try { action(); }
    catch (InvalidDataException) { Check(true, name); return; }
    throw new Exception("FAIL: accepted " + name);
}
async Task RejectAsync(Func<Task> action, string name)
{
    try { await action(); }
    catch (InvalidDataException) { Check(true, name); return; }
    throw new Exception("FAIL: accepted " + name);
}
JsonObject Release(string tag = "v1.3.3", bool portable = true) => new()
{
    ["tag_name"] = tag,
    ["assets"] = new JsonArray(new JsonObject
    {
        ["name"] = $"KappaSweep{(portable ? "-Portable" : "")}-{tag}.zip",
        ["browser_download_url"] = $"https://github.com/kappapr1der/kappasweep/releases/download/{tag}/KappaSweep{(portable ? "-Portable" : "")}-{tag}.zip",
        ["size"] = 1000L, ["digest"] = "sha256:" + new string('a', 64)
    })
};
try
{
    Check(ReleaseUpdate.Parse(Release(), "1.3.2", true)?.Tag == "v1.3.3", "portable update selected");
    Check(ReleaseUpdate.Parse(Release(portable: false), "1.3.2", false) is not null, "regular build selected");
    Check(ReleaseUpdate.Parse(Release("v1.3.2"), "1.3.2", true) is null, "same version ignored");
    Check(ReleaseUpdate.Parse(Release("v1.3.1"), "1.3.2", true) is null, "downgrade ignored");
    var preview = Release(); preview["prerelease"] = true;
    Check(ReleaseUpdate.Parse(preview, "1.3.2", true) is null, "prerelease ignored");
    Reject(() => ReleaseUpdate.Parse(Release(portable: false), "1.3.2", true), "wrong build rejected");
    var external = Release(); external["assets"]![0]!["browser_download_url"] = "https://example.com/file.zip";
    Reject(() => ReleaseUpdate.Parse(external, "1.3.2", true), "external source rejected");
    var digest = Release(); digest["assets"]![0]!["digest"] = null;
    Reject(() => ReleaseUpdate.Parse(digest, "1.3.2", true), "missing digest rejected");
    var size = Release(); size["assets"]![0]!["size"] = 201L * 1024 * 1024;
    Reject(() => ReleaseUpdate.Parse(size, "1.3.2", true), "oversized download rejected");
    var jsonPath = Path.Combine(folder, "report-test.json");
    File.WriteAllText(jsonPath, """
        {"schemaVersion":1,"kind":"cleanup","mode":"Analyze","profile":"Safe","totalBytes":1073741824,"totalItems":2,"results":[{"Label":"Кэш Spotify","Bytes":1073741824,"Status":"would clean","Path":"D:\\Music"}],"tips":["Закрой приложение."]}
        """, new UTF8Encoding(true));
    var report = LocalReports.Read(jsonPath);
    Check(report.Rows.Count == 1 && report.Rows[0].Label == "Кэш Spotify", "UTF-8 BOM report and Cyrillic");
    Check(report.Rows[0].Status == "Можно очистить" && report.Summary.Contains("Можно освободить"), "analysis not presented as deletion");
    Check(report.Summary.Contains("Закрой приложение."), "retry hints shown");
    var storagePath = Path.Combine(folder, "space-hogs-test.json");
    File.WriteAllText(storagePath, """
        {"schemaVersion":1,"kind":"storage","results":[{"Name":"NVIDIA","SizeBytes":1024,"Action":"Проверить","Path":"C:\\Cache"}]}
        """);
    Check(LocalReports.Read(storagePath).Rows[0].Status == "Проверить", "storage report read");
    Check(LocalReports.Read(storagePath).IsStorage && LocalReports.Read(storagePath).Rows[0].Bytes == 1024, "storage retains numeric bytes for charts");
    Check(!report.IsStorage, "cleanup reports remain lists");
    ReportRow Row(string path, long bytes, string label = "Target") => new(label, LocalReports.Size(bytes), "Только диагностика", path, bytes);
    var chartRows = new[]
    {
        Row(@"C:\Cache", 100), Row(@"c:\cache\", 90, "Duplicate"), Row(@"C:\Cache\Music", 40),
        Row(@"C:\Cache-old", 30), Row(@"D:\Music", 70), Row(@"C:/Cache/./Music", 40),
        Row(@"C:\Empty", 0), Row(@"C:\Negative", -2), Row("relative-folder", 20)
    };
    var chart = StorageChart.Create(chartRows);
    Check(chart.TotalBytes == 200 && chart.Slices.Count == 3 && chart.OverlapCount == 3, "duplicate and nested paths counted once; sibling prefix retained");
    Check(chart.UnmappedCount == 1, "unmapped paths excluded from percentages");
    Check(Math.Abs(chart.Slices.Sum(slice => slice.Percent) - 100) < 0.00001, "chart shares sum to 100 percent");
    Check(StorageChart.Create(chartRows, "c:").TotalBytes == 130, "drive filter is case insensitive");
    Check(StorageChart.FilterRows(chartRows, "D:").Count == 1, "list uses same drive filter");
    Check(StorageChart.Create([Row(@"C:\", 1000), Row(@"C:\Cache", 100)]).TotalBytes == 1000, "drive root contains descendants");
    Check(StorageChart.Create([Row(@"Z:\nonexistent\..\folder", 10)]).TotalBytes == 10, "chart uses saved paths without filesystem access");
    var grouped = StorageChart.Create(Enumerable.Range(1, 10).Select(i => Row(@"C:\item" + i, i)).ToArray());
    Check(grouped.Slices.Count == 8 && grouped.Slices[^1].Label == "Прочее" && grouped.Slices[^1].Bytes == 6
        && grouped.Slices[^1].Rows.Count == 3 && grouped.TotalBytes == 55, "top seven and exact remainder retain drilldown targets");
    Check(StorageChart.Create([]).Slices.Count == 0 && StorageChart.Create(chartRows, "E:").TotalBytes == 0, "empty report and empty drive handled");
    Check(StorageChart.Create([Row(@"C:\Only", 10)]).Slices.Single().Percent == 100, "single target uses full ring");
    Check(StorageChart.Create(Enumerable.Range(0, 2100).Select(i => Row(@"C:\bounded" + i, 1)).ToArray()).TotalBytes == 2000,
        "chart computation is bounded to 2000 targets");
    Reject(() => StorageChart.Create([Row(@"C:\One", long.MaxValue), Row(@"D:\Two", 1)]), "overflowing totals rejected");
    var reportDrives = new ReportView("", chartRows, true, ["E:", "c:"]);
    Check(StorageChart.Drives(reportDrives).SequenceEqual(new[] { "C:", "D:", "E:" }), "drive choices combine saved rows and disk snapshots");
    var preferencesPath = Path.Combine(folder, "ui-preferences.json");
    Check(ReportPreferences.Load(preferencesPath).Mode == "diagram", "diagram is default for new users");
    new ReportPreferences("list", "D:").Save(preferencesPath);
    Check(ReportPreferences.Load(preferencesPath) == new ReportPreferences("list", "D:"), "view and drive preferences persist separately");
    File.WriteAllText(preferencesPath, "not-json");
    Check(ReportPreferences.Load(preferencesPath) == new ReportPreferences(), "corrupt preferences do not prevent startup");
    File.WriteAllText(preferencesPath, new string('x', 5000));
    Check(ReportPreferences.Load(preferencesPath) == new ReportPreferences(), "oversized preferences are bounded");
    File.WriteAllText(preferencesPath, "{\"Mode\":\"unknown\",\"Drive\":null}");
    Check(ReportPreferences.Load(preferencesPath) == new ReportPreferences(), "unknown preference values default safely");
    var boundedPath = Path.Combine(folder, "bounded.json");
    File.WriteAllText(boundedPath, new JsonObject
    {
        ["schemaVersion"] = 1, ["kind"] = "storage",
        ["results"] = new JsonArray(Enumerable.Range(0, 2001).Select(i => (JsonNode)new JsonObject
            { ["Name"] = "Target", ["SizeBytes"] = 1, ["Path"] = @"C:\bounded" + i }).ToArray())
    }.ToJsonString());
    var boundedReport = LocalReports.Read(boundedPath);
    Check(boundedReport.Rows.Count == 2000 && boundedReport.IsTruncated, "truncated reports expose their coverage limit");
    File.WriteAllText(Path.Combine(folder, "latest.json"), "{}");
    Check(LocalReports.Find(new[] { folder, folder }, true).Count == 2, "report discovery deduplicates and skips aliases");
    var log = Path.Combine(folder, "cleanup-test.log");
    File.WriteAllText(log, "Cleaned Spotify: 4 item(s), about 1.5 GB.\nWindows cleanup finished.\n");
    Check(LocalReports.Read(log).Rows.Count == 1, "legacy report fallback");
    File.WriteAllText(log, new string('x', 1_000_000) + "\nКонец журнала");
    var tail = LocalReports.ReadLogTail(log);
    Check(tail.Length < 101_000 && tail.EndsWith("Конец журнала"), "large logs bounded and tail preserved");
    File.WriteAllText(jsonPath, "{\"schemaVersion\":9}");
    Reject(() => LocalReports.Read(jsonPath), "unknown schema rejected");
    var zip = Path.Combine(folder, "release.zip");
    using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
    {
        archive.CreateEntryFromFile(Path.GetFullPath(args[1]), "KappaSweep.exe");
        using var writer = new StreamWriter(archive.CreateEntry("../escape.txt").Open());
        writer.Write("not extracted");
    }
    var extract = Path.Combine(folder, "extract"); Directory.CreateDirectory(extract);
    var builtVersion = FileVersionInfo.GetVersionInfo(Path.GetFullPath(args[1])).ProductVersion!.Split('+')[0];
    Check(File.Exists(ReleaseUpdate.ExtractExecutable(zip, extract, "v" + builtVersion)), "built executable version validated");
    Check(!File.Exists(Path.Combine(folder, "escape.txt")), "archive traversal entry never extracted");
    var wrongVersion = Path.Combine(folder, "wrong-version"); Directory.CreateDirectory(wrongVersion);
    Reject(() => ReleaseUpdate.ExtractExecutable(zip, wrongVersion, "v999.0.0"), "mismatched executable rejected");
    var helper = ReleaseUpdate.BuildInstallCommand(123, "C:\\It's\\new.exe", "C:\\App\\old.exe", folder);
    Check(helper.Contains("It''s") && helper.Contains("WaitForExit(60000)") && helper.Contains("-Destination $backup")
        && helper.Contains("Copy-Item -LiteralPath $backup -Destination $target -Force"), "installer quoting, wait, backup and rollback");
    var body = new byte[2048];
    using var http = new HttpClient(new FakeHandler(body));
    var update = new ReleaseUpdate("v1.3.3", new Uri("https://github.com/kappapr1der/kappasweep/releases/download/v1.3.3/test.zip"), body.Length, new string('0', 64));
    await RejectAsync(() => update.DownloadAsync(Path.Combine(folder, "bad-hash"), new Progress<int>(), http), "download SHA-256 mismatch rejected");
    await RejectAsync(() => (update with { Size = body.Length + 1 }).DownloadAsync(Path.Combine(folder, "short-body"), new Progress<int>(), http), "incomplete download rejected");
    await RejectAsync(() => (update with { Size = body.Length - 1 }).DownloadAsync(Path.Combine(folder, "large-body"), new Progress<int>(), http), "unexpected download length rejected");
    var matchingHash = Convert.ToHexString(SHA256.HashData(body));
    await RejectAsync(() => (update with { Sha256 = matchingHash }).DownloadAsync(Path.Combine(folder, "not-zip"), new Progress<int>(), http), "non-archive payload rejected after hash check");
    int Install(string source, string target, string stage)
    {
        var command = ReleaseUpdate.BuildInstallCommand(int.MaxValue, source, target, stage, restart: false);
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command)),
            UseShellExecute = false, CreateNoWindow = true
        }) ?? throw new Exception("Test installer failed to launch.");
        if (!process.WaitForExit(45000)) { process.Kill(entireProcessTree: true); throw new Exception("Test installer timeout."); }
        return process.ExitCode;
    }
    var installFolder = Path.Combine(folder, "install"); Directory.CreateDirectory(installFolder);
    var target = Path.Combine(installFolder, "KappaSweep.exe");
    File.WriteAllText(target, "previous executable");
    Check(Install(Path.GetFullPath(args[1]), target, installFolder) == 0 && File.ReadAllText(Path.Combine(installFolder, "previous.exe")) == "previous executable",
        "real install helper copies, validates startup, and preserves backup");
    var beforeRollback = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(target)));
    var invalidExe = Path.Combine(installFolder, "invalid.exe"); File.WriteAllText(invalidExe, "not an executable");
    Check(Install(invalidExe, target, installFolder) != 0
        && Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(target))) == beforeRollback,
        "real install helper restores previous EXE after failed startup");
    Console.WriteLine($"LAUNCHER_TESTS_OK count={passed}");
}

finally
{
    if (!Path.GetFullPath(folder).StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException("Unsafe test cleanup path.");
    Directory.Delete(folder, recursive: true);
}

internal sealed class FakeHandler(byte[] body) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) });
}
