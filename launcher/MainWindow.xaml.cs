using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace KappaSweepLauncher;

public partial class MainWindow : Window
{
    private const string Version = "1.3.0";
    private const long WorkingSetLimitBytes = 1536L * 1024 * 1024;
    private static readonly HttpClient UpdateClient = new() { Timeout = TimeSpan.FromSeconds(8) };

    private readonly string _engineRoot;
    private readonly string _configPath;
    private readonly string _powerShellPath;
    private readonly DispatcherTimer _monitorTimer;
    private readonly List<Button> _actionButtons = new();
    private readonly Dictionary<string, CheckBox> _cacheCheckboxes = new(StringComparer.OrdinalIgnoreCase);

    private JsonObject _config = new();
    private Process? _activeProcess;
    private ActionGuard? _activeGuard;
    private DateTime _activeStartedAt;
    private string? _activeTitle;
    private string? _activeRunLogPath;
    private string? _latestReleaseUrl;
    private int _runLogReadChars;

    public MainWindow(string engineRoot)
    {
        _engineRoot = engineRoot;
        _configPath = Path.Combine(_engineRoot, "kappasweep-config.json");
        _powerShellPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(_powerShellPath))
        {
            throw new FileNotFoundException("Windows PowerShell 5.1 was not found.", _powerShellPath);
        }

        InitializeComponent();
        Icon = LoadWindowIcon();
        _monitorTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _monitorTimer.Tick += MonitorTimer_Tick;
        RegisterActionButtons();
        RefreshAll(showLog: false);
        AppendLog($"Control Center v{Version} готов. Интерфейс работает нативно на .NET 8.");
    }

    public static bool RunSmokeTest(string engineRoot)
    {
        var expected = new[]
        {
            "cleanup-windows.ps1", "kappasweep-config.json", "space-hog-report.ps1",
            "system-maintenance-check.ps1", "install-scheduled-cleanup.ps1"
        };
        var engineIsValid = expected.All(file => File.Exists(Path.Combine(engineRoot, file)))
            && GetActionGuard("cleanup-windows.ps1", new[] { "-Profile", "Safe" }).Timeout == TimeSpan.FromMinutes(12)
            && GetActionGuard("cleanup-windows.ps1", new[] { "-Profile", "Deep" }).Timeout == TimeSpan.FromMinutes(45)
            && GetActionGuard("space-hog-report.ps1", Array.Empty<string>()).Timeout == TimeSpan.FromMinutes(15)
            && WorkingSetLimitBytes == 1536L * 1024 * 1024;
        if (!engineIsValid)
        {
            return false;
        }

        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        try
        {
            var window = new MainWindow(engineRoot);
            var uiIsValid = window.Title == "KappaSweep Control Center" && window._cacheCheckboxes.Count == 10;
            window.Close();
            return uiIsValid;
        }
        finally
        {
            application.Shutdown();
        }
    }

    public static bool RunRenderSmokeTest(string engineRoot, string? renderOutput = null)
    {
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var rendered = false;
        var failed = false;
        application.DispatcherUnhandledException += (_, eventArgs) =>
        {
            failed = true;
            eventArgs.Handled = true;
            application.Shutdown(1);
        };

        try
        {
            var window = new MainWindow(engineRoot)
            {
                Left = -10000,
                Top = -10000,
                Opacity = 0.01,
                ShowInTaskbar = false
            };
            window.Loaded += (_, _) =>
            {
                rendered = true;
                var closeTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
                closeTimer.Tick += (_, _) =>
                {
                    closeTimer.Stop();
                    if (!string.IsNullOrWhiteSpace(renderOutput))
                    {
                        var content = (FrameworkElement)window.Content;
                        content.UpdateLayout();
                        var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(
                            (int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight),
                            96, 96, PixelFormats.Pbgra32);
                        bitmap.Render(content);
                        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                        using var stream = File.Create(renderOutput);
                        encoder.Save(stream);
                    }
                    window.Close();
                    application.Shutdown();
                };
                closeTimer.Start();
            };
            application.Run(window);
            return rendered && !failed;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (!failed)
            {
                application.Shutdown();
            }
        }
    }

    private ImageSource? LoadWindowIcon()
    {
        var iconPath = Path.Combine(_engineRoot, "kappasweep-icon.png");
        if (!File.Exists(iconPath))
        {
            return null;
        }

        try
        {
            var bitmap = new System.Windows.Media.Imaging.BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(iconPath, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    private void RegisterActionButtons()
    {
        _actionButtons.AddRange(new[]
        {
            RecommendedCleanupButton, AnalyzeButton, SafeCleanupButton, SmartCleanupButton,
            SpaceHogButton, OpenReportButton, HistoryButton, SystemStatusButton,
            AnalyzeComponentStoreButton, DeepMaintenanceButton, DisableHibernationButton,
            EnableHibernationButton, LogEncodingButton, InstallScheduleButton,
            RepairShortcutButton, SpaceReportButton, OpenLatestReportButton, ShowHistoryButton
        });
    }

    private void RefreshAll(bool showLog = true)
    {
        try
        {
            LoadConfig();
            RefreshDrives();
            RefreshCacheControls();
            RefreshSummary();
            RefreshSystemSummary();
            RefreshHistorySummary();
            if (showLog)
            {
                AppendLog("Данные обновлены.");
            }
        }
        catch (Exception exception)
        {
            AppendLog("ОШИБКА обновления: " + exception.Message);
        }
    }

    private void LoadConfig()
    {
        if (!File.Exists(_configPath))
        {
            throw new FileNotFoundException("kappasweep-config.json was not found.", _configPath);
        }

        _config = JsonNode.Parse(File.ReadAllText(_configPath, Encoding.UTF8)) as JsonObject
            ?? throw new InvalidDataException("kappasweep-config.json must contain an object.");
    }

    private void RefreshDrives()
    {
        DrivePanel.Children.Clear();
        foreach (var drive in DriveInfo.GetDrives()
                     .Where(drive => drive.DriveType == DriveType.Fixed && drive.IsReady && drive.TotalSize > 0)
                     .OrderBy(drive => drive.Name, StringComparer.OrdinalIgnoreCase))
        {
            var freePercent = Math.Round(drive.AvailableFreeSpace * 100d / drive.TotalSize, 1);
            var accent = freePercent < 10 ? "#C2413D" : freePercent < 20 ? "#C47A22" : "#147D78";
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock
            {
                Text = drive.Name.TrimEnd('\\'), FontSize = 20, FontWeight = FontWeights.SemiBold,
                Foreground = BrushFrom(accent)
            });
            stack.Children.Add(new TextBlock
            {
                Text = $"{FormatBytes(drive.AvailableFreeSpace)} свободно из {FormatBytes(drive.TotalSize)}",
                Foreground = BrushFrom("#344B52"), Margin = new Thickness(0, 5, 0, 0)
            });
            stack.Children.Add(new TextBlock
            {
                Text = $"{freePercent:N1}% свободно", Foreground = BrushFrom("#5A6B72"), Margin = new Thickness(0, 3, 0, 0)
            });
            DrivePanel.Children.Add(new Border
            {
                Background = Brushes.White, BorderBrush = BrushFrom("#D3DEE1"), BorderThickness = new Thickness(1),
                Padding = new Thickness(16), Margin = new Thickness(0, 0, 12, 0), Width = 220, Child = stack
            });
        }
    }

    private void RefreshCacheControls()
    {
        CachePanel.Children.Clear();
        _cacheCheckboxes.Clear();
        var features = GetObject(_config, "features");
        var labels = new (string Key, string Label)[]
        {
            ("spotifyCache", "Spotify (автоочистка отключена)"), ("discordCache", "Discord"), ("telegramCache", "Telegram Desktop"),
            ("slackCache", "Slack"), ("teamsCache", "Microsoft Teams"), ("zoomCache", "Zoom"),
            ("browserCaches", "Браузеры (только когда закрыты)"), ("developerCaches", "Инструменты разработки"),
            ("gameCaches", "Игровые лаунчеры"), ("notifyOnPressure", "Уведомления с итогом очистки")
        };

        foreach (var (key, label) in labels)
        {
            var checkBox = new CheckBox
            {
                Content = label, Tag = key, Width = 280,
                IsChecked = GetBool(features, key, false)
            };
            if (string.Equals(key, "spotifyCache", StringComparison.OrdinalIgnoreCase))
            {
                checkBox.IsChecked = false;
                checkBox.IsEnabled = false;
                checkBox.ToolTip = "Spotify исключён из автоматической очистки: Store-версия смешивает кэш с данными интерфейса.";
            }
            CachePanel.Children.Add(checkBox);
            _cacheCheckboxes[key] = checkBox;
        }
    }

    private void RefreshSummary()
    {
        var thresholds = GetObject(_config, "thresholds");
        var paths = GetObject(_config, "paths");
        var schedule = GetObject(_config, "schedule");
        var guardDriveName = GetString(paths, "guardDrive", "C:").TrimEnd('\\');
        var minimumGb = GetInt(thresholds, "minFreeGB", 35);
        var minimumPercent = GetInt(thresholds, "minFreePercent", 18);
        var perDrive = GetObject(thresholds, "perDrive");
        if (perDrive[guardDriveName] is JsonObject perDriveThreshold)
        {
            minimumGb = GetInt(perDriveThreshold, "minFreeGB", minimumGb);
            minimumPercent = GetInt(perDriveThreshold, "minFreePercent", minimumPercent);
        }

        var drive = DriveInfo.GetDrives().FirstOrDefault(item =>
            item.IsReady && string.Equals(item.Name.TrimEnd('\\'), guardDriveName, StringComparison.OrdinalIgnoreCase));
        if (drive is null)
        {
            ProtectionText.Foreground = BrushFrom("#C2413D");
            ProtectionText.Text = $"{guardDriveName} недоступен.";
        }
        else
        {
            var freePercent = Math.Round(drive.AvailableFreeSpace * 100d / drive.TotalSize, 1);
            var belowTarget = drive.AvailableFreeSpace < minimumGb * 1024L * 1024 * 1024 || freePercent < minimumPercent;
            ProtectionText.Foreground = BrushFrom(belowTarget ? "#C47A22" : "#147D78");
            ProtectionText.Text = $"{guardDriveName}: {FormatBytes(drive.AvailableFreeSpace)} свободно ({freePercent:N1}%). Цель: {minimumGb} ГБ / {minimumPercent}%{(belowTarget ? " · Pressure Guard включён" : " · запас в норме")}.";
        }

        var enabled = _cacheCheckboxes.Values.Count(checkBox => checkBox.IsChecked == true);
        OverviewText.Text = $"Профиль: {GetString(_config, "defaultProfile", "Safe")}. Включено переключателей: {enabled}. Все операции выполняются в отдельном контролируемом процессе.";
        var automation = GetObject(_config, "automation");
        var standardFreeGb = GetInt(automation, "standardFreeGB", 50);
        var emergencyFreeGb = GetInt(automation, "emergencyFreeGB", 30);
        var lightAge = GetInt(automation, "lightCacheOlderThanDays", 7);
        var standardAge = GetInt(automation, "standardCacheOlderThanDays", 3);
        AutomationText.Text = $"Автополитика: до {standardFreeGb} ГБ - кэш старше {lightAge} дн.; до {emergencyFreeGb} ГБ - старше {standardAge} дн.; ниже {emergencyFreeGb} ГБ - экстренный режим.";
        ScheduleText.Text = $"Pressure Guard: каждые {GetInt(schedule, "guardEveryHours", 3)} ч. с {GetString(schedule, "guardStart", "00:15")}. Deep Weekly: {GetString(schedule, "deepDay", "Sunday")} в {GetString(schedule, "deepWeekly", "03:20")}.";
        LastRunText.Text = GetLatestCleanupText();
    }

    private void RefreshSystemSummary()
    {
        var hiberPath = Path.Combine(Environment.GetEnvironmentVariable("SystemDrive") ?? "C:", "hiberfil.sys");
        string hiberText;
        try
        {
            hiberText = File.Exists(hiberPath) ? FormatBytes(new FileInfo(hiberPath).Length) : "не найден";
        }
        catch
        {
            hiberText = "проверяется с правами администратора";
        }

        SystemSafetyText.Text = $"Файл гибернации: {hiberText}. Отключение освобождает место, но выключает гибернацию и Fast Startup. Анализ компонентного хранилища ничего не меняет.";
    }

    private string GetLatestCleanupText()
    {
        var logRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CodexWindowsCleanup", "Logs");
        if (!Directory.Exists(logRoot))
        {
            return "Запусков очистки в системном журнале пока нет.";
        }

        var latest = new DirectoryInfo(logRoot).GetFiles("cleanup-*.log")
            .OrderByDescending(file => file.LastWriteTime)
            .FirstOrDefault();
        if (latest is null)
        {
            return "Запусков очистки в системном журнале пока нет.";
        }

        try
        {
            var lines = File.ReadAllLines(latest.FullName, Encoding.UTF8);
            var finish = lines.LastOrDefault(line => line.Contains("Windows cleanup finished", StringComparison.OrdinalIgnoreCase));
            if (string.IsNullOrWhiteSpace(finish))
            {
                return $"Последний журнал: {latest.LastWriteTime:dd.MM HH:mm}.";
            }

            var match = Regex.Match(finish, @"Removed (?<items>\d+) item\(s\), reclaimed about (?<size>[\d.,]+\s+(?:GB|MB|KB|bytes)), blocked: (?<blocked>\d+), errors: (?<errors>\d+)\.", RegexOptions.IgnoreCase);
            if (!match.Success)
            {
                return $"Последняя очистка: {latest.LastWriteTime:dd.MM HH:mm}.";
            }

            var categories = lines
                .Where(line => line.Contains(" Cleaned ", StringComparison.OrdinalIgnoreCase))
                .Select(line => Regex.Match(line, @"Cleaned (?<label>.+): \d+ item\(s\), about [^.]+\.", RegexOptions.IgnoreCase))
                .Where(item => item.Success)
                .Select(item => item.Groups["label"].Value)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Take(3)
                .ToArray();
            var categoryText = categories.Length == 0 ? string.Empty : $" Очищено: {string.Join(", ", categories)}.";
            return $"{latest.LastWriteTime:dd.MM HH:mm}: освобождено {match.Groups["size"].Value}, удалено {match.Groups["items"].Value} объектов.{categoryText}";
        }
        catch
        {
            return $"Последний журнал: {latest.LastWriteTime:dd.MM HH:mm}.";
        }
    }

    private void RefreshHistorySummary()
    {
        HistoryBarsPanel.Children.Clear();
        var now = DateTime.Today;
        var history = ReadCleanupHistory()
            .Where(entry => entry.Time.Date >= now.AddDays(-29))
            .ToArray();
        var lastSevenDays = history.Where(entry => entry.Time.Date >= now.AddDays(-6)).ToArray();
        var totalSeven = lastSevenDays.Sum(entry => entry.ReclaimedBytes);
        var totalThirty = history.Sum(entry => entry.ReclaimedBytes);
        if (history.Length == 0)
        {
            HistorySummaryText.Text = "За последние 30 дней завершённых очисток пока нет.";
            HistoryCategoriesText.Text = string.Empty;
            return;
        }

        HistorySummaryText.Text = $"За 7 дней: {FormatBytes(totalSeven)} за {lastSevenDays.Length} запуск(ов). За 30 дней: {FormatBytes(totalThirty)} за {history.Length} запуск(ов).";
        var days = Enumerable.Range(0, 7)
            .Select(offset => now.AddDays(-6 + offset))
            .Select(day => new HistoryDay(day, lastSevenDays.Where(entry => entry.Time.Date == day).Sum(entry => entry.ReclaimedBytes)))
            .ToArray();
        var maximum = Math.Max(1, days.Max(day => day.ReclaimedBytes));
        foreach (var day in days)
        {
            var cell = new Grid { Width = 52, Height = 92, Margin = new Thickness(0, 0, 5, 0) };
            var barHeight = day.ReclaimedBytes == 0 ? 3 : Math.Max(6, Math.Round(day.ReclaimedBytes * 64d / maximum));
            var bar = new Border
            {
                Width = 30,
                Height = barHeight,
                Background = BrushFrom(day.ReclaimedBytes == 0 ? "#D3DEE1" : "#147D78"),
                VerticalAlignment = VerticalAlignment.Bottom,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 0, 0, 20),
                ToolTip = $"{day.Date:dd.MM}: {FormatBytes(day.ReclaimedBytes)}"
            };
            var label = new TextBlock
            {
                Text = day.Date.ToString("dd.MM"),
                FontSize = 11,
                Foreground = BrushFrom("#5A6B72"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Bottom
            };
            cell.Children.Add(bar);
            cell.Children.Add(label);
            HistoryBarsPanel.Children.Add(cell);
        }

        var categories = history
            .SelectMany(entry => entry.Categories)
            .GroupBy(category => category.Label, StringComparer.OrdinalIgnoreCase)
            .Select(group => new HistoryCategory(group.Key, group.Sum(item => item.ReclaimedBytes)))
            .OrderByDescending(category => category.ReclaimedBytes)
            .Take(3)
            .Select(category => $"{category.Label}: {FormatBytes(category.ReclaimedBytes)}")
            .ToArray();
        HistoryCategoriesText.Text = categories.Length == 0
            ? "Крупных категорий в истории пока нет."
            : "Больше всего освобождалось: " + string.Join(", ", categories) + ".";
    }

    private IEnumerable<CleanupHistoryEntry> ReadCleanupHistory()
    {
        var logRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CodexWindowsCleanup", "Logs");
        if (!Directory.Exists(logRoot))
        {
            yield break;
        }

        foreach (var log in new DirectoryInfo(logRoot).GetFiles("cleanup-*.log").OrderByDescending(file => file.LastWriteTime).Take(180))
        {
            string[] lines;
            try
            {
                lines = File.ReadAllLines(log.FullName, Encoding.UTF8);
            }
            catch
            {
                continue;
            }

            var finish = lines.LastOrDefault(line => line.Contains("Windows cleanup finished", StringComparison.OrdinalIgnoreCase));
            var summary = finish is null
                ? Match.Empty
                : Regex.Match(finish, @"reclaimed about (?<size>[\d.,]+\s+(?:GB|MB|KB|bytes)), blocked", RegexOptions.IgnoreCase);
            if (!summary.Success)
            {
                continue;
            }

            var categories = lines
                .Select(line => Regex.Match(line, @"Cleaned (?<label>.+): \d+ item\(s\), about (?<size>[\d.,]+\s+(?:GB|MB|KB|bytes))\.", RegexOptions.IgnoreCase))
                .Where(match => match.Success)
                .Select(match => new HistoryCategory(match.Groups["label"].Value, ParseByteSize(match.Groups["size"].Value)))
                .Where(category => category.ReclaimedBytes > 0)
                .ToArray();
            yield return new CleanupHistoryEntry(log.LastWriteTime, ParseByteSize(summary.Groups["size"].Value), categories);
        }
    }

    private static long ParseByteSize(string text)
    {
        var match = Regex.Match(text, @"(?<amount>[\d.,]+)\s*(?<unit>GB|MB|KB|bytes)", RegexOptions.IgnoreCase);
        if (!match.Success)
        {
            return 0;
        }

        var normalized = match.Groups["amount"].Value.Replace(',', '.');
        if (!double.TryParse(normalized, NumberStyles.Float, CultureInfo.InvariantCulture, out var amount))
        {
            return 0;
        }

        var multiplier = match.Groups["unit"].Value.ToUpperInvariant() switch
        {
            "GB" => 1L << 30,
            "MB" => 1L << 20,
            "KB" => 1L << 10,
            _ => 1L
        };
        return (long)Math.Max(0, amount * multiplier);
    }

    private void StartAction(string title, string fileName, bool elevated = false, params string[] arguments)
    {
        if (_activeProcess is { HasExited: false })
        {
            AppendLog("Действие уже выполняется. Дождись завершения текущего запуска.");
            return;
        }

        var scriptPath = Path.Combine(_engineRoot, fileName);
        if (!File.Exists(scriptPath))
        {
            AppendLog("Файл не найден: " + scriptPath);
            return;
        }

        try
        {
            _activeRunLogPath = CreateRunLogPath();
            _runLogReadChars = 0;
            OpenRunLogButton.IsEnabled = true;
            var command = BuildInvocationCommand(scriptPath, arguments, _activeRunLogPath);
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
            var startInfo = new ProcessStartInfo
            {
                FileName = _powerShellPath,
                Arguments = $"-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}",
                WorkingDirectory = _engineRoot,
                UseShellExecute = elevated,
                CreateNoWindow = !elevated,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            if (elevated)
            {
                startInfo.Verb = "runas";
            }

            _activeProcess = Process.Start(startInfo) ?? throw new InvalidOperationException("Процесс не был запущен.");
            _activeTitle = title;
            _activeGuard = GetActionGuard(fileName, arguments);
            _activeStartedAt = DateTime.UtcNow;
            SetActionState(true, elevated
                ? $"Выполняется: {title}. Подтверди UAC, прогресс останется здесь."
                : $"Выполняется: {title}. Не закрывай KappaSweep.");
            AppendLog(elevated ? $"Запущено с правами администратора: {fileName}" : $"Запуск: {title}");
            _monitorTimer.Start();
        }
        catch (Exception exception)
        {
            _activeProcess = null;
            SetActionState(false, $"Не удалось запустить: {title}.");
            AppendLog("ОШИБКА запуска: " + exception.Message);
        }
    }

    private static string BuildInvocationCommand(string scriptPath, IEnumerable<string> arguments, string logPath)
    {
        var invocationArguments = string.Join(" ", arguments.Select(FormatPowerShellArgument));
        return $$"""
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            $global:OutputEncoding = [Console]::OutputEncoding
            $ErrorActionPreference = 'Stop'
            try {
                & {{QuotePowerShellLiteral(scriptPath)}} {{invocationArguments}} *>&1 | Out-File -LiteralPath {{QuotePowerShellLiteral(logPath)}} -Encoding UTF8
                if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
                exit 0
            }
            catch {
                ($_ | Out-String -Width 240).TrimEnd() | Out-File -LiteralPath {{QuotePowerShellLiteral(logPath)}} -Append -Encoding UTF8
                exit 1
            }
            """;
    }

    private static string FormatPowerShellArgument(string value) =>
        value.StartsWith("-", StringComparison.Ordinal) ? value : QuotePowerShellLiteral(value);

    private static string QuotePowerShellLiteral(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";

    private void MonitorTimer_Tick(object? sender, EventArgs e)
    {
        if (_activeProcess is null || _activeGuard is null || _activeTitle is null)
        {
            _monitorTimer.Stop();
            return;
        }

        AppendNewRunOutput();
        try
        {
            if (_activeProcess.HasExited)
            {
                CompleteAction(_activeProcess.ExitCode);
                return;
            }

            _activeProcess.Refresh();
            if (DateTime.UtcNow - _activeStartedAt > _activeGuard.Timeout)
            {
                StopActiveAction($"Превышен лимит времени {(int)_activeGuard.Timeout.TotalMinutes} мин.");
                return;
            }

            if (_activeProcess.WorkingSet64 > WorkingSetLimitBytes)
            {
                StopActiveAction($"Память процесса достигла {Math.Round(_activeProcess.WorkingSet64 / 1024d / 1024 / 1024, 2):N2} ГБ.");
            }
        }
        catch (Exception exception)
        {
            AppendLog("ОШИБКА мониторинга: " + exception.Message);
        }
    }

    private void StopActiveAction(string reason)
    {
        if (_activeProcess is null || _activeTitle is null)
        {
            return;
        }

        AppendLog($"ПРЕДОХРАНИТЕЛЬ: {_activeTitle} остановлен. {reason}");
        try
        {
            using var killer = Process.Start(new ProcessStartInfo
            {
                FileName = "taskkill.exe", Arguments = $"/PID {_activeProcess.Id} /T /F",
                UseShellExecute = false, CreateNoWindow = true
            });
            killer?.WaitForExit(5000);
        }
        catch (Exception exception)
        {
            AppendLog("Не удалось остановить дерево процесса: " + exception.Message);
        }

        CompleteAction(124);
    }

    private void CompleteAction(int exitCode)
    {
        AppendNewRunOutput();
        var title = _activeTitle ?? "Действие";
        _monitorTimer.Stop();
        _activeProcess?.Dispose();
        _activeProcess = null;
        _activeGuard = null;
        _activeTitle = null;
        var result = exitCode == 0
            ? $"Готово: {title}."
            : $"{title} завершено с кодом {exitCode}. Проверь журнал ниже.";
        SetActionState(false, result);
        AppendLog(result);
        RefreshAll(showLog: false);
    }

    private void AppendNewRunOutput()
    {
        if (string.IsNullOrWhiteSpace(_activeRunLogPath) || !File.Exists(_activeRunLogPath))
        {
            return;
        }

        try
        {
            using var stream = new FileStream(_activeRunLogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            var content = reader.ReadToEnd();
            if (content.Length < _runLogReadChars)
            {
                _runLogReadChars = 0;
            }
            if (content.Length > _runLogReadChars)
            {
                AppendRawLog(content[_runLogReadChars..]);
                _runLogReadChars = content.Length;
            }
        }
        catch (IOException)
        {
            // The writer may have the log open for a moment; the next timer tick retries it.
        }
    }

    private string CreateRunLogPath()
    {
        var runDirectory = Path.Combine(_engineRoot, "KappaSweepRuns");
        Directory.CreateDirectory(runDirectory);
        foreach (var oldLog in new DirectoryInfo(runDirectory).GetFiles("run-*.log")
                     .OrderByDescending(file => file.LastWriteTime)
                     .Skip(24))
        {
            oldLog.Delete();
        }

        var path = Path.Combine(runDirectory, $"run-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.log");
        File.WriteAllText(path, string.Empty, new UTF8Encoding(false));
        return path;
    }

    private void SetActionState(bool running, string message)
    {
        ActivityProgress.IsIndeterminate = running;
        ActivityStatusText.Text = running ? "Выполняется" : "Готово";
        ActivitySummaryText.Text = message;
        ActivitySummaryText.Foreground = BrushFrom(running ? "#C47A22" : "#147D78");
        foreach (var button in _actionButtons)
        {
            button.IsEnabled = !running;
        }
    }

    private static ActionGuard GetActionGuard(string fileName, IEnumerable<string> arguments)
    {
        var values = arguments.ToArray();
        if (string.Equals(fileName, "cleanup-windows.ps1", StringComparison.OrdinalIgnoreCase))
        {
            var deep = values.Contains("-Deep", StringComparer.OrdinalIgnoreCase)
                || values.Zip(values.Skip(1)).Any(pair =>
                    string.Equals(pair.First, "-Profile", StringComparison.OrdinalIgnoreCase)
                    && string.Equals(pair.Second, "Deep", StringComparison.OrdinalIgnoreCase));
            return new ActionGuard(deep ? TimeSpan.FromMinutes(45) : TimeSpan.FromMinutes(12));
        }
        if (string.Equals(fileName, "space-hog-report.ps1", StringComparison.OrdinalIgnoreCase))
        {
            return new ActionGuard(TimeSpan.FromMinutes(15));
        }
        if (string.Equals(fileName, "system-maintenance-check.ps1", StringComparison.OrdinalIgnoreCase)
            && values.Contains("-AnalyzeComponentStore", StringComparer.OrdinalIgnoreCase))
        {
            return new ActionGuard(TimeSpan.FromMinutes(20));
        }
        if (string.Equals(fileName, "install-scheduled-cleanup.ps1", StringComparison.OrdinalIgnoreCase))
        {
            return new ActionGuard(TimeSpan.FromMinutes(3));
        }
        return new ActionGuard(TimeSpan.FromMinutes(5));
    }

    private void AppendLog(string text) => AppendRawLog($"[{DateTime.Now:HH:mm:ss}] {text.Trim()}{Environment.NewLine}");

    private void AppendRawLog(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }
        LogBox.AppendText(text);
        if (LogBox.Text.Length > 150_000)
        {
            LogBox.Text = LogBox.Text[^100_000..];
        }
        LogBox.ScrollToEnd();
    }

    private void SaveSettings()
    {
        var features = GetObject(_config, "features");
        foreach (var (key, checkBox) in _cacheCheckboxes)
        {
            features[key] = checkBox.IsChecked == true;
        }
        File.WriteAllText(_configPath, _config.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
        AppendLog("Настройки сохранены: " + _configPath);
        RefreshSummary();
    }

    private void OpenExternalPath(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }
        catch (Exception exception)
        {
            AppendLog("Не удалось открыть путь: " + exception.Message);
        }
    }

    private async void CheckForUpdatesButton_Click(object sender, RoutedEventArgs e)
    {
        CheckForUpdatesButton.IsEnabled = false;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/kappapr1der/kappasweep/releases/latest");
            request.Headers.TryAddWithoutValidation("User-Agent", "KappaSweep-Control-Center");
            using var response = await UpdateClient.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var release = JsonNode.Parse(await response.Content.ReadAsStringAsync()) as JsonObject
                ?? throw new InvalidDataException("GitHub returned an invalid release response.");
            var tag = release["tag_name"]?.GetValue<string>()?.Trim() ?? string.Empty;
            var url = release["html_url"]?.GetValue<string>()?.Trim() ?? string.Empty;
            if (IsNewerRelease(tag))
            {
                _latestReleaseUrl = url;
                OpenLatestReleaseButton.IsEnabled = !string.IsNullOrWhiteSpace(_latestReleaseUrl);
                ActivitySummaryText.Text = $"Доступно обновление {tag}. Открой релиз, чтобы скачать portable-версию.";
                ActivitySummaryText.Foreground = BrushFrom("#147D78");
                AppendLog("Доступно обновление: " + tag);
            }
            else
            {
                _latestReleaseUrl = string.Empty;
                OpenLatestReleaseButton.IsEnabled = false;
                ActivitySummaryText.Text = $"Установлена актуальная версия v{Version}.";
                ActivitySummaryText.Foreground = BrushFrom("#147D78");
                AppendLog("Проверка обновлений: установлена актуальная версия.");
            }
        }
        catch (Exception exception)
        {
            ActivitySummaryText.Text = "Не удалось проверить обновление. Проверь подключение к GitHub.";
            ActivitySummaryText.Foreground = BrushFrom("#C47A22");
            AppendLog("ОШИБКА проверки обновлений: " + exception.Message);
        }
        finally
        {
            CheckForUpdatesButton.IsEnabled = true;
        }
    }

    private void OpenLatestReleaseButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(_latestReleaseUrl))
        {
            OpenExternalPath(_latestReleaseUrl);
        }
    }

    private static bool IsNewerRelease(string tag)
    {
        var candidate = tag.Trim().TrimStart('v', 'V');
        return System.Version.TryParse(candidate, out var latest)
            && System.Version.TryParse(Version, out var installed)
            && latest > installed;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (_activeProcess is { HasExited: false })
        {
            e.Cancel = true;
            AppendLog("Операция ещё выполняется. KappaSweep останется открыт, чтобы контролировать её завершение.");
        }
        base.OnClosing(e);
    }

    private static JsonObject GetObject(JsonObject parent, string name)
    {
        if (parent[name] is JsonObject objectValue)
        {
            return objectValue;
        }
        objectValue = new JsonObject();
        parent[name] = objectValue;
        return objectValue;
    }

    private static string GetString(JsonObject parent, string name, string fallback) =>
        parent[name]?.GetValue<string>() ?? fallback;

    private static int GetInt(JsonObject parent, string name, int fallback) =>
        parent[name]?.GetValue<int>() ?? fallback;

    private static bool GetBool(JsonObject parent, string name, bool fallback) =>
        parent[name]?.GetValue<bool>() ?? fallback;

    private static string FormatBytes(long bytes) => bytes switch
    {
        >= 1L << 40 => $"{bytes / (double)(1L << 40):N1} ТБ",
        >= 1L << 30 => $"{bytes / (double)(1L << 30):N1} ГБ",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):N1} МБ",
        _ => $"{Math.Max(0, bytes / 1024):N0} КБ"
    };

    private static Brush BrushFrom(string color) => (Brush)new BrushConverter().ConvertFromString(color)!;

    private sealed record ActionGuard(TimeSpan Timeout);
    private sealed record HistoryDay(DateTime Date, long ReclaimedBytes);
    private sealed record HistoryCategory(string Label, long ReclaimedBytes);
    private sealed record CleanupHistoryEntry(DateTime Time, long ReclaimedBytes, IReadOnlyList<HistoryCategory> Categories);

    private void RefreshButton_Click(object sender, RoutedEventArgs e) => RefreshAll();
    private void OpenFolderButton_Click(object sender, RoutedEventArgs e) => OpenExternalPath(_engineRoot);
    private void RecommendedCleanupButton_Click(object sender, RoutedEventArgs e) => StartAction("Очистка", "cleanup-windows.ps1", false, "-Profile", "Safe", "-SmartGuard", "-OpenReport", "-ConfigPath", _configPath);
    private void AnalyzeButton_Click(object sender, RoutedEventArgs e) => StartAction("Анализ очистки", "cleanup-windows.ps1", false, "-Analyze", "-Profile", "Emergency", "-OpenReport", "-ConfigPath", _configPath);
    private void SafeCleanupButton_Click(object sender, RoutedEventArgs e) => StartAction("Безопасная очистка", "cleanup-windows.ps1", false, "-Profile", "Safe", "-OpenReport", "-ConfigPath", _configPath);
    private void SmartCleanupButton_Click(object sender, RoutedEventArgs e) => StartAction("Умная очистка", "cleanup-windows.ps1", false, "-SmartGuard", "-AggressiveSafe", "-CleanDeveloperCaches", "-CleanRegistry", "-ConfigPath", _configPath);
    private void SpaceHogButton_Click(object sender, RoutedEventArgs e) => StartAction("Анализ места", "space-hog-report.ps1", false, "-Top", "12", "-OpenReport");
    private void OpenReportButton_Click(object sender, RoutedEventArgs e) => StartAction("Последний отчёт", "open-latest-report.ps1");
    private void HistoryButton_Click(object sender, RoutedEventArgs e) => StartAction("История", "show-cleanup-history.ps1");
    private void SaveSettingsButton_Click(object sender, RoutedEventArgs e) => SaveSettings();
    private void OpenConfigButton_Click(object sender, RoutedEventArgs e) => OpenExternalPath(_configPath);
    private void SystemStatusButton_Click(object sender, RoutedEventArgs e) => StartAction("Проверка системы", "system-maintenance-check.ps1");
    private void AnalyzeComponentStoreButton_Click(object sender, RoutedEventArgs e) => StartAction("Анализ хранилища компонентов", "system-maintenance-check.ps1", true, "-AnalyzeComponentStore");
    private void DeepMaintenanceButton_Click(object sender, RoutedEventArgs e) => StartAction("Глубокое обслуживание", "cleanup-windows.ps1", true, "-Profile", "Deep", "-OpenReport", "-ConfigPath", _configPath);
    private void DisableHibernationButton_Click(object sender, RoutedEventArgs e) => StartAction("Отключение гибернации", "system-tweaks.ps1", true, "-DisableHibernation");
    private void EnableHibernationButton_Click(object sender, RoutedEventArgs e) => StartAction("Включение гибернации", "system-tweaks.ps1", true, "-EnableHibernation");
    private void LogEncodingButton_Click(object sender, RoutedEventArgs e) => StartAction("Проверка кодировки", "check-log-encoding.ps1");
    private void InstallScheduleButton_Click(object sender, RoutedEventArgs e) => StartAction("Настройка Планировщика", "install-scheduled-cleanup.ps1", true, "-ConfigPath", _configPath);
    private void RepairShortcutButton_Click(object sender, RoutedEventArgs e) => StartAction("Починка ярлыков", "repair-powershell-shortcut.ps1");
    private void SpaceReportButton_Click(object sender, RoutedEventArgs e) => StartAction("Диагностика места", "space-hog-report.ps1", false, "-Top", "12", "-OpenReport");
    private void OpenLatestReportButton_Click(object sender, RoutedEventArgs e) => StartAction("Последний HTML", "open-latest-report.ps1");
    private void ShowHistoryButton_Click(object sender, RoutedEventArgs e) => StartAction("История", "show-cleanup-history.ps1");
    private void OpenLogsButton_Click(object sender, RoutedEventArgs e) => OpenExternalPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CodexWindowsCleanup", "Logs"));
    private void OpenRunLogButton_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(_activeRunLogPath) && File.Exists(_activeRunLogPath))
        {
            OpenExternalPath(_activeRunLogPath);
        }
    }
}
