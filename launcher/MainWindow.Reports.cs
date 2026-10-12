using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace KappaSweepLauncher;

public partial class MainWindow
{
    private sealed record ReportDrive(string Label, string Drive);
    private ReportView? _loadedReport;
    private ReportPreferences _reportPreferences = new();
    private string _reportDrive = "";
    private bool _refreshingReportView = true;
    private bool _refreshingStorageLegend;
    private string ReportPreferencesPath => Path.Combine(_engineRoot, "ui-preferences.json");

    private void InitializeReportPresentation()
    {
        _reportPreferences = ReportPreferences.Load(ReportPreferencesPath);
        StorageDonut.SliceSelected = slice =>
        {
            StorageLegend.SelectedItem = slice;
            StorageDetailsPanel.BringIntoView();
        };
        _refreshingReportView = false;
    }

    private void ApplyReport(ReportView report)
    {
        _loadedReport = report;
        ReportSummaryText.Text = report.Summary;
        _refreshingReportView = true;
        var drives = new[] { new ReportDrive("Все диски", "") }
            .Concat(StorageChart.Drives(report).Select(drive => new ReportDrive(drive, drive))).ToArray();
        ReportDriveSelector.ItemsSource = drives;
        ReportDriveSelector.SelectedItem = drives.FirstOrDefault(drive => drive.Drive == _reportPreferences.Drive) ?? drives[0];
        _reportDrive = ((ReportDrive)ReportDriveSelector.SelectedItem).Drive;
        _refreshingReportView = false;
        RefreshReportPresentation();
    }

    private void RefreshReportPresentation()
    {
        var storage = _loadedReport?.IsStorage == true;
        var diagram = storage && _reportPreferences.Mode != "list";
        StorageToolbar.Visibility = storage ? Visibility.Visible : Visibility.Collapsed;
        ReportSummaryText.Visibility = storage ? Visibility.Collapsed : Visibility.Visible;
        StoragePanel.Visibility = diagram ? Visibility.Visible : Visibility.Collapsed;
        ReportGrid.Visibility = diagram ? Visibility.Collapsed : Visibility.Visible;
        ReportGrid.ItemsSource = _loadedReport is null ? null : storage
            ? StorageChart.FilterRows(_loadedReport.Rows, _reportDrive) : _loadedReport.Rows;
        _refreshingReportView = true;
        DiagramModeButton.IsChecked = _reportPreferences.Mode != "list";
        ListModeButton.IsChecked = _reportPreferences.Mode == "list";
        _refreshingReportView = false;
        if (!diagram) return;

        var chart = StorageChart.Create(_loadedReport!.Rows, _reportDrive);
        StorageTotalText.Text = LocalReports.Size(chart.TotalBytes);
        StorageCoverageText.Text = "Доли от суммы измеренных целей, не от всего занятого места на диске.";
        if (chart.OverlapCount > 0)
            StorageCoverageText.Text += $" Повторные и вложенные пути: {chart.OverlapCount} (без повторного подсчёта).";
        if (chart.UnmappedCount > 0)
            StorageCoverageText.Text += $" Без определённого диска: {chart.UnmappedCount}; доступны в списке.";
        if (_loadedReport.IsTruncated)
            StorageCoverageText.Text += " Отчёт ограничен первыми 2000 целями.";
        var previous = StorageLegend.SelectedItem as StorageSlice;
        _refreshingStorageLegend = true;
        StorageDonut.SetSlices(chart.Slices);
        StorageLegend.ItemsSource = chart.Slices;
        StorageLegend.SelectedItem = chart.Slices.FirstOrDefault(slice => previous is not null && slice.Label == previous.Label
            && slice.Rows[0].Path == previous.Rows[0].Path) ?? chart.Slices.FirstOrDefault();
        _refreshingStorageLegend = false;
        StorageEmptyText.Visibility = chart.Slices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateStorageDetails();
    }

    private void ReportMode_Checked(object sender, RoutedEventArgs e)
    {
        if (_refreshingReportView || _loadedReport?.IsStorage != true) return;
        _reportPreferences = _reportPreferences with { Mode = ListModeButton.IsChecked == true ? "list" : "diagram" };
        SaveReportPreferences();
        RefreshReportPresentation();
    }

    private void ReportDrive_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_refreshingReportView || ReportDriveSelector.SelectedItem is not ReportDrive drive) return;
        _reportDrive = drive.Drive;
        _reportPreferences = _reportPreferences with { Drive = drive.Drive };
        SaveReportPreferences();
        RefreshReportPresentation();
    }

    private void SaveReportPreferences()
    {
        try { _reportPreferences.Save(ReportPreferencesPath); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            AppendLog("Не удалось сохранить вид отчёта: " + exception.Message);
        }
    }

    private void StorageLegend_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateStorageDetails();
        if (!_refreshingStorageLegend && StorageLegend.SelectedItem is not null) StorageDetailsPanel.BringIntoView();
    }

    private void UpdateStorageDetails()
    {
        var slice = StorageLegend.SelectedItem as StorageSlice;
        StorageDonut.SelectSlice(slice);
        StorageDetailsPanel.Visibility = slice is null ? Visibility.Collapsed : Visibility.Visible;
        if (slice is null) { StorageDetailsGrid.ItemsSource = null; return; }
        StorageDetailTitle.Text = slice.Description;
        var aggregate = slice.Rows.Count > 1;
        StorageDetailStatus.Text = aggregate ? $"Целей: {slice.Rows.Count}. Действия указаны для каждой цели отдельно." : slice.Rows[0].Status;
        StorageDetailPath.Text = aggregate ? "" : slice.Rows[0].Path;
        StorageDetailPath.Visibility = aggregate ? Visibility.Collapsed : Visibility.Visible;
        StorageDetailsGrid.ItemsSource = aggregate ? slice.Rows : null;
        StorageDetailsGrid.Visibility = aggregate ? Visibility.Visible : Visibility.Collapsed;
    }

    private static ReportView StorageTestFixture(bool empty = false)
    {
        ReportRow Row(string label, string path, long gigabytes, string action) =>
            new(label, LocalReports.Size(gigabytes << 30), action, path, gigabytes << 30);
        return new ReportView("Диагностика места. Файлы не удалялись.", empty ? [] :
        [
            Row("Документы", @"C:\Users\Test\Documents", 22, "Только диагностика; не удаляется KappaSweep"),
            Row("Spotify: музыкальный кэш", @"D:\KappaSweep\SpotifyCache\Data", 12, "Отдельный Cache Guard; только при закрытом Spotify"),
            Row("DriverStore", @"C:\Windows\System32\DriverStore", 9, "Только диагностика; не удаляется KappaSweep"),
            Row("Кэш браузера Chrome", @"C:\Users\Test\AppData\Local\Google\Chrome\User Data\Default\Cache", 6, "Переключатель браузеров; только при закрытом Chrome"),
            Row("Загрузки", @"C:\Users\Test\Downloads", 5, "Только диагностика; не удаляется KappaSweep"),
            Row("Временные файлы Windows", @"C:\Windows\Temp", 4, "Доступно в безопасной очистке"),
            Row("Корзина", @"C:\$Recycle.Bin", 3, "Очистка после проверки содержимого"),
            Row("Discord", @"C:\Users\Test\AppData\Roaming\discord\Cache", 2, "Переключатель Discord"),
            Row("Steam HTTP cache", @"D:\Steam\appcache\httpcache", 1, "Переключатель Steam; только при закрытом Steam"),
            Row("Журналы Windows", @"C:\Windows\Logs\CBS", 1, "Только диагностика"),
            Row("Вложенная папка документов", @"C:\Users\Test\Documents\Archive", 7, "Только диагностика")
        ], true, ["C:", "D:", "E:"]);
    }

    private bool VerifyStorageInteraction()
    {
        var configBefore = File.ReadAllText(_configPath);
        _reportPreferences = new();
        var fixture = StorageTestFixture();
        ApplyReport(fixture);
        var valid = StoragePanel.Visibility == Visibility.Visible && ReportGrid.Visibility == Visibility.Collapsed
            && StorageLegend.Items.Count == 8 && StorageCoverageText.Text.Contains("без повторного подсчёта");
        var remainder = (StorageSlice)StorageLegend.Items[7];
        StorageDonut.SliceSelected?.Invoke(remainder);
        valid &= ReferenceEquals(StorageLegend.SelectedItem, remainder) && StorageDetailsGrid.Items.Count == 3
            && StorageDetailPath.Visibility == Visibility.Collapsed;
        ListModeButton.IsChecked = true;
        valid &= ReportGrid.Visibility == Visibility.Visible && ReportGrid.Items.Count == 11
            && StoragePanel.Visibility == Visibility.Collapsed;
        DiagramModeButton.IsChecked = true;
        ReportDriveSelector.SelectedItem = ReportDriveSelector.Items.Cast<ReportDrive>().Single(drive => drive.Drive == "D:");
        valid &= StorageLegend.Items.Count == 2 && StorageDetailPath.Text.StartsWith(@"D:\") && ReferenceEquals(_loadedReport, fixture);
        valid &= ReportPreferences.Load(ReportPreferencesPath) == new ReportPreferences("diagram", "D:");
        ReportDriveSelector.SelectedItem = ReportDriveSelector.Items.Cast<ReportDrive>().Single(drive => drive.Drive == "E:");
        valid &= StorageLegend.Items.Count == 0 && StorageEmptyText.Visibility == Visibility.Visible
            && StorageDetailsPanel.Visibility == Visibility.Collapsed;
        ApplyReport(new ReportView("Очищено: тест.", [new ReportRow("Тест", "1 КБ", "Очищено", @"C:\test", 1024)]));
        valid &= StorageToolbar.Visibility == Visibility.Collapsed && ReportGrid.Visibility == Visibility.Visible
            && File.ReadAllText(_configPath) == configBefore;
        var ring = StorageDonut.Sector(-90, 360);
        valid &= ring.FillContains(new Point(120, 25)) && !ring.FillContains(new Point(120, 120));
        var quarter = StorageDonut.Sector(-90, 90);
        valid &= quarter.FillContains(new Point(185, 55)) && !quarter.FillContains(new Point(55, 55));
        return valid;
    }
}
