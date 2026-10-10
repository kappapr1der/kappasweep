using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace KappaSweepLauncher;

internal sealed record ReleaseUpdate(string Tag, Uri DownloadUrl, long Size, string Sha256)
{
    private const long SizeLimit = 200L * 1024 * 1024;

    public static ReleaseUpdate? Parse(JsonObject release, string installed, bool portable)
    {
        var tag = release["tag_name"]?.GetValue<string>() ?? "";
        if (release["draft"]?.GetValue<bool>() == true || release["prerelease"]?.GetValue<bool>() == true
            || !Regex.IsMatch(tag, @"^v?\d+\.\d+\.\d+$")
            || !Version.TryParse(tag.TrimStart('v'), out var latest)
            || !Version.TryParse(installed, out var current) || latest <= current) return null;
        var name = $"KappaSweep{(portable ? "-Portable" : "")}-v{latest}.zip";
        var asset = (release["assets"] as JsonArray)?.OfType<JsonObject>()
            .FirstOrDefault(item => item["name"]?.GetValue<string>() == name);
        if (asset is null) throw new InvalidDataException($"В релизе {tag} нет архива {name}.");
        var url = asset["browser_download_url"]?.GetValue<string>() ?? "";
        var expectedUrl = $"https://github.com/kappapr1der/kappasweep/releases/download/{tag}/{name}";
        var digest = asset["digest"]?.GetValue<string>() ?? "";
        var size = asset["size"]?.GetValue<long>() ?? 0;
        if (!string.Equals(url, expectedUrl, StringComparison.OrdinalIgnoreCase)
            || !Regex.IsMatch(digest, @"^sha256:[a-fA-F0-9]{64}$") || size <= 0 || size > SizeLimit)
            throw new InvalidDataException("Архив обновления не прошёл проверку источника, размера или SHA-256. Установка отменена.");
        return new ReleaseUpdate(tag, new Uri(url), size, digest[7..]);
    }

    public async Task<string> DownloadAsync(string folder, IProgress<int> progress, HttpClient? client = null)
    {
        Directory.CreateDirectory(folder);
        var zipPath = Path.Combine(folder, "release.zip");
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(4));
        using var ownedClient = client is null ? new HttpClient { Timeout = Timeout.InfiniteTimeSpan } : null;
        var downloadClient = client ?? ownedClient!;
        downloadClient.DefaultRequestHeaders.UserAgent.ParseAdd("KappaSweep-Updater");
        using var response = await downloadClient.GetAsync(DownloadUrl, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is long length && length != Size)
            throw new InvalidDataException("Размер загрузки отличается от опубликованного.");
        await using (var input = await response.Content.ReadAsStreamAsync(timeout.Token))
        await using (var output = new FileStream(zipPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
        {
            var buffer = new byte[81920];
            long received = 0;
            int count;
            while ((count = await input.ReadAsync(buffer, timeout.Token)) > 0)
            {
                received += count;
                if (received > Size) throw new InvalidDataException("Превышен заявленный размер обновления.");
                await output.WriteAsync(buffer.AsMemory(0, count), timeout.Token);
                progress.Report((int)(received * 100 / Size));
            }
            if (received != Size) throw new InvalidDataException("Архив загрузился не полностью.");
        }
        await using (var file = File.OpenRead(zipPath))
        {
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, timeout.Token));
            if (!hash.Equals(Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Контрольная сумма обновления не совпала. Установка отменена.");
        }
        return ExtractExecutable(zipPath, folder, Tag);
    }

    internal static string ExtractExecutable(string zipPath, string folder, string tag)
    {
        using var archive = ZipFile.OpenRead(zipPath);
        var matches = archive.Entries.Where(entry => entry.FullName == "KappaSweep.exe").ToArray();
        if (matches.Length != 1 || matches[0].Length < 1024 || matches[0].Length > SizeLimit)
            throw new InvalidDataException("Архив не содержит единственный корректный KappaSweep.exe.");
        // Only the root executable is extracted; archive paths never become destination paths.
        var executable = Path.Combine(folder, "KappaSweep.exe");
        matches[0].ExtractToFile(executable, overwrite: false);
        using (var file = File.OpenRead(executable))
            if (file.ReadByte() != 'M' || file.ReadByte() != 'Z') throw new InvalidDataException("Некорректный EXE.");
        var version = FileVersionInfo.GetVersionInfo(executable).ProductVersion?.Split('+')[0];
        if (!Version.TryParse(version, out var actual) || !Version.TryParse(tag.TrimStart('v'), out var expected) || actual != expected)
            throw new InvalidDataException("Версия EXE не совпала с релизом.");
        return executable;
    }

    internal static string BuildInstallCommand(int parentId, string source, string target, string folder, bool restart = true)
    {
        static string Quote(string text) => "'" + text.Replace("'", "''", StringComparison.Ordinal) + "'";
        return $$"""
            $ErrorActionPreference = 'Stop'
            $target = {{Quote(target)}}
            $source = {{Quote(source)}}
            $backup = {{Quote(Path.Combine(folder, "previous.exe"))}}
            $log = {{Quote(Path.Combine(folder, "install.log"))}}
            try {
                $parent = Get-Process -Id {{parentId}} -ErrorAction SilentlyContinue
                if ($parent -and -not $parent.WaitForExit(60000)) { throw 'KappaSweep is still running; no files were replaced.' }
                Copy-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
                try {
                    Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
                    $validation = Start-Process -FilePath $target -ArgumentList '--test' -PassThru -WindowStyle Hidden
                    if (-not $validation.WaitForExit(30000)) {
                        Stop-Process -Id $validation.Id -Force -ErrorAction SilentlyContinue
                        throw 'New executable did not pass its startup test within 30 seconds.'
                    }
                    if ($validation.ExitCode -ne 0) { throw 'New executable failed its startup test.' }
                }
                catch { Copy-Item -LiteralPath $backup -Destination $target -Force; throw }
                'Update installed successfully.' | Out-File -LiteralPath $log -Encoding UTF8
                {{(restart ? "Start-Process -FilePath $target -WorkingDirectory (Split-Path -Parent $target)" : "")}}
            }
            catch {
                $_ | Out-String | Out-File -LiteralPath $log -Encoding UTF8
                {{(restart ? "Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show(('Update failed. Previous executable was preserved. Log: ' + $log), 'KappaSweep') | Out-Null" : "exit 1")}}
            }
            """;
    }
}
