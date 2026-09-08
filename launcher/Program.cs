using System;
using System.IO.Compression;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;

namespace KappaSweepLauncher;

internal static class Program
{
    private const string PayloadResource = "KappaSweepPayload.zip";

    [STAThread]
    private static int Main()
    {
        try
        {
            var engineRoot = GetEngineRoot();
            Directory.CreateDirectory(engineRoot);
            ImportLegacySettings(engineRoot);
            ExtractPayload(engineRoot);

            var commandLine = Environment.GetCommandLineArgs();
            if (commandLine.Any(argument =>
                    string.Equals(argument, "--test", StringComparison.OrdinalIgnoreCase)))
            {
                return MainWindow.RunSmokeTest(engineRoot) ? 0 : 1;
            }
            if (commandLine.Any(argument =>
                    string.Equals(argument, "--render-test", StringComparison.OrdinalIgnoreCase)))
            {
                var outputIndex = Array.IndexOf(commandLine, "--render-output");
                var renderOutput = outputIndex >= 0 && outputIndex + 1 < commandLine.Length
                    ? commandLine[outputIndex + 1] : null;
                return MainWindow.RunRenderSmokeTest(engineRoot, renderOutput) ? 0 : 1;
            }

            var app = new Application
            {
                ShutdownMode = ShutdownMode.OnMainWindowClose
            };
            app.DispatcherUnhandledException += (_, eventArgs) =>
            {
                MessageBox.Show(
                    eventArgs.Exception.Message,
                    "KappaSweep",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                eventArgs.Handled = true;
            };

            app.Run(new MainWindow(engineRoot));
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                exception.Message,
                "KappaSweep",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return 1;
        }
    }

    private static string GetEngineRoot()
    {
#if PORTABLE
        return SelectEngineRoot(AppContext.BaseDirectory, "KappaSweepData", "WinSweepData");
#else
        var localRoot = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return SelectEngineRoot(localRoot, Path.Combine("KappaSweep", "Engine"), Path.Combine("WinSweep", "Engine"));
#endif
    }

    private static string SelectEngineRoot(string parent, string currentName, string legacyName)
    {
        var current = Path.Combine(parent, currentName);
        var legacy = Path.Combine(parent, legacyName);
        // Reuse the existing engine so scheduled task paths and custom files stay valid.
        return Directory.Exists(current) || !Directory.Exists(legacy) ? current : legacy;
    }

    private static void ImportLegacySettings(string engineRoot)
    {
        var current = Path.Combine(engineRoot, "kappasweep-config.json");
        var legacy = Path.Combine(engineRoot, "winsweep-config.json");
        if (!File.Exists(current) && File.Exists(legacy))
        {
            File.Copy(legacy, current, overwrite: false);
        }
    }

    private static void ExtractPayload(string engineRoot)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadResource)
            ?? throw new InvalidOperationException("KappaSweep payload is missing from the executable.");
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read, false);

        var root = Path.GetFullPath(engineRoot) + Path.DirectorySeparatorChar;
        foreach (var entry in archive.Entries)
        {
            var relativePath = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
            var destination = Path.GetFullPath(Path.Combine(engineRoot, relativePath));
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("KappaSweep payload contains an unsafe path.");
            }

            if (string.IsNullOrEmpty(entry.Name))
            {
                Directory.CreateDirectory(destination);
                continue;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            if ((string.Equals(entry.Name, "kappasweep-config.json", StringComparison.OrdinalIgnoreCase)
                 || string.Equals(entry.Name, "extra-cache-paths.txt", StringComparison.OrdinalIgnoreCase))
                && File.Exists(destination))
            {
                continue;
            }

            entry.ExtractToFile(destination, true);
        }
    }
}
