[CmdletBinding()]
param(
    [switch]$Test,
    [ValidateRange(0, 60)]
    [int]$AutoCloseSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$encodingHelper = Join-Path $PSScriptRoot "kappasweep-encoding.ps1"
if (Test-Path -LiteralPath $encodingHelper -PathType Leaf) {
    . $encodingHelper
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:KappaSweepVersion = "1.3.0"
$script:PowerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$script:ConfigPath = Join-Path $PSScriptRoot "kappasweep-config.json"
$script:ActiveProcess = $null
$script:ActiveAction = ""
$script:ActiveRunLogPath = ""
$script:ActiveRunLineCount = 0
$script:ActionTimer = $null
$script:ActiveActionStartedAt = $null
$script:ActiveActionGuard = $null
$script:CacheCheckboxes = @{}
$script:Config = $null

if (-not (Test-Path -LiteralPath $script:PowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 was not found: $script:PowerShellPath"
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="KappaSweep Control Center"
        Width="1120" Height="840" MinWidth="900" MinHeight="700"
        WindowStartupLocation="CenterScreen"
        Background="#F4F7F8"
        FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="{x:Type Button}">
            <Setter Property="Margin" Value="0,0,10,10"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="MinHeight" Value="38"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#147D78"/>
            <Setter Property="BorderBrush" Value="#0E5E5A"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="{x:Type Button}">
            <Setter Property="Margin" Value="0,0,10,10"/>
            <Setter Property="Padding" Value="14,9"/>
            <Setter Property="MinHeight" Value="36"/>
            <Setter Property="Foreground" Value="#1E2933"/>
            <Setter Property="Background" Value="#E4ECEE"/>
            <Setter Property="BorderBrush" Value="#B8C8CC"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style TargetType="{x:Type TabItem}">
            <Setter Property="Padding" Value="16,9"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
        <Style TargetType="{x:Type CheckBox}">
            <Setter Property="Margin" Value="0,5,16,5"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
    </Window.Resources>
    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="220"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,20">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="KappaSweep" FontSize="30" FontWeight="SemiBold" Foreground="#172B32"/>
                <TextBlock Text="Control Center · одна кнопка для безопасной очистки, места и настроек" FontSize="14" Foreground="#5A6B72" Margin="0,4,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="RefreshButton" Content="Обновить" Style="{StaticResource SecondaryButton}"/>
                <Button x:Name="OpenFolderButton" Content="Открыть папку" Style="{StaticResource SecondaryButton}"/>
            </StackPanel>
        </Grid>

        <ScrollViewer Grid.Row="1" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled" Margin="0,0,0,20">
            <StackPanel x:Name="DrivePanel" Orientation="Horizontal"/>
        </ScrollViewer>

        <TabControl Grid.Row="2" x:Name="MainTabs">
            <TabItem Header="Обзор">
                <Grid Margin="18">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="Быстрые действия" FontSize="20" FontWeight="SemiBold" Foreground="#172B32" Margin="0,0,0,14"/>
                    <WrapPanel Grid.Row="1">
                        <Button x:Name="RecommendedCleanupButton" Content="Очистить безопасно" FontWeight="SemiBold" Padding="20,11"/>
                        <Button x:Name="AnalyzeButton" Content="Анализ очистки"/>
                        <Button x:Name="SafeCleanupButton" Content="Безопасная очистка"/>
                        <Button x:Name="SmartCleanupButton" Content="Умная очистка"/>
                        <Button x:Name="SpaceHogButton" Content="Пожиратели места"/>
                        <Button x:Name="OpenReportButton" Content="Последний отчёт" Style="{StaticResource SecondaryButton}"/>
                        <Button x:Name="HistoryButton" Content="История" Style="{StaticResource SecondaryButton}"/>
                    </WrapPanel>
                    <Border Grid.Row="2" Background="White" BorderBrush="#D3DEE1" BorderThickness="1" Padding="16" Margin="0,8,0,0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock Text="Автозащита" FontSize="16" FontWeight="SemiBold" Foreground="#172B32"/>
                            <TextBlock x:Name="ProtectionStateText" Grid.Row="1" TextWrapping="Wrap" FontWeight="SemiBold" Foreground="#147D78" Margin="0,7,0,0"/>
                            <Grid Grid.Row="2" Margin="0,14,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Margin="0,0,16,0">
                                    <TextBlock Text="C: и порог" FontSize="12" Foreground="#5A6B72"/>
                                    <TextBlock x:Name="ProtectionCapacityText" TextWrapping="Wrap" FontWeight="SemiBold" Foreground="#172B32" Margin="0,3,0,0"/>
                                </StackPanel>
                                <StackPanel Grid.Column="1" Margin="8,0,16,0">
                                    <TextBlock Text="Последний автозапуск" FontSize="12" Foreground="#5A6B72"/>
                                    <TextBlock x:Name="ProtectionLastRunText" TextWrapping="Wrap" FontWeight="SemiBold" Foreground="#172B32" Margin="0,3,0,0"/>
                                </StackPanel>
                                <StackPanel Grid.Column="2" Margin="8,0,0,0">
                                    <TextBlock Text="Освобождено" FontSize="12" Foreground="#5A6B72"/>
                                    <TextBlock x:Name="ProtectionSavingsText" TextWrapping="Wrap" FontWeight="SemiBold" Foreground="#172B32" Margin="0,3,0,0"/>
                                </StackPanel>
                            </Grid>
                            <TextBlock x:Name="OverviewText" Grid.Row="3" TextWrapping="Wrap" Foreground="#5A6B72" Margin="0,16,0,0"/>
                            <TextBlock x:Name="LockedAppsText" Grid.Row="4" TextWrapping="Wrap" Foreground="#5A6B72" Margin="0,8,0,0"/>
                            <WrapPanel Grid.Row="5" Margin="0,10,0,0">
                                <Button x:Name="RetryLockedCleanupButton" Content="Повторить после закрытия программ" Style="{StaticResource SecondaryButton}"/>
                            </WrapPanel>
                            <TextBlock x:Name="ActivitySummaryText" Grid.Row="6" Text="Готово к запуску действия." TextWrapping="Wrap" FontWeight="SemiBold" Foreground="#147D78" Margin="0,8,0,0"/>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Кэши и правила">
                <Grid Margin="18">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="Что разрешено очищать" FontSize="20" FontWeight="SemiBold" Foreground="#172B32" Margin="0,0,0,6"/>
                    <TextBlock Grid.Row="1" Text="Переключатели сохраняются в kappasweep-config.json и применяются планировщиком." Foreground="#5A6B72" Margin="0,0,0,10"/>
                    <ScrollViewer Grid.Row="1" Margin="0,34,0,10" VerticalScrollBarVisibility="Auto">
                        <WrapPanel x:Name="CachePanel"/>
                    </ScrollViewer>
                    <StackPanel Grid.Row="2" Orientation="Horizontal">
                        <Button x:Name="SaveSettingsButton" Content="Сохранить настройки"/>
                        <Button x:Name="OpenConfigButton" Content="Открыть JSON" Style="{StaticResource SecondaryButton}"/>
                    </StackPanel>
                </Grid>
            </TabItem>
            <TabItem Header="Система">
                <StackPanel Margin="18">
                    <TextBlock Text="Системное обслуживание" FontSize="20" FontWeight="SemiBold" Foreground="#172B32"/>
                    <TextBlock Text="Обратимые действия и диагностика. Системные изменения запускаются с подтверждением UAC." TextWrapping="Wrap" Foreground="#5A6B72" Margin="0,8,0,18"/>
                    <WrapPanel>
                        <Button x:Name="SystemStatusButton" Content="Состояние системы" Style="{StaticResource SecondaryButton}"/>
                        <Button x:Name="AnalyzeComponentStoreButton" Content="Анализ хранилища компонентов" Style="{StaticResource SecondaryButton}"/>
                        <Button x:Name="DeepMaintenanceButton" Content="Глубокое обслуживание"/>
                        <Button x:Name="DisableHibernationButton" Content="Отключить гибернацию" Style="{StaticResource SecondaryButton}"/>
                        <Button x:Name="EnableHibernationButton" Content="Включить гибернацию" Style="{StaticResource SecondaryButton}"/>
                        <Button x:Name="LogEncodingButton" Content="Проверить кодировку логов" Style="{StaticResource SecondaryButton}"/>
                    </WrapPanel>
                    <Border Background="#FFF9ED" BorderBrush="#E4C46A" BorderThickness="1" Padding="14" Margin="0,8,0,0">
                        <TextBlock x:Name="SystemSafetyText" TextWrapping="Wrap" Foreground="#604A16"/>
                    </Border>
                </StackPanel>
            </TabItem>
            <TabItem Header="Планировщик">
                <StackPanel Margin="18">
                    <TextBlock Text="Автоматическая уборка" FontSize="20" FontWeight="SemiBold" Foreground="#172B32"/>
                    <TextBlock x:Name="ScheduleText" TextWrapping="Wrap" Foreground="#5A6B72" Margin="0,8,0,18"/>
                    <TextBlock x:Name="ScheduleDiagnosticsText" TextWrapping="Wrap" Foreground="#5A6B72" Margin="0,0,0,14"/>
                    <WrapPanel>
                        <Button x:Name="InstallScheduleButton" Content="Проверить и починить задачи"/>
                        <Button x:Name="RepairShortcutButton" Content="Починить ярлыки PowerShell" Style="{StaticResource SecondaryButton}"/>
                    </WrapPanel>
                    <TextBlock Text="Pressure Guard запускает безопасную очистку только при достижении порогов свободного места. Глубокая еженедельная задача остаётся отдельной." TextWrapping="Wrap" Foreground="#5A6B72" Margin="0,14,0,0"/>
                </StackPanel>
            </TabItem>
            <TabItem Header="Отчёты и история">
                <StackPanel Margin="18">
                    <TextBlock Text="Отчёты" FontSize="20" FontWeight="SemiBold" Foreground="#172B32"/>
                    <TextBlock Text="Все отчёты остаются локальными. HTML открывается в Chrome, если он установлен." Foreground="#5A6B72" Margin="0,8,0,18"/>
                    <WrapPanel>
                        <Button x:Name="SpaceReportButton" Content="Диагностика места"/>
                        <Button x:Name="OpenLatestReportButton" Content="Открыть последний HTML" Style="{StaticResource SecondaryButton}"/>
                        <Button x:Name="ShowHistoryButton" Content="Показать историю" Style="{StaticResource SecondaryButton}"/>
                        <Button x:Name="OpenLogsButton" Content="Открыть логи" Style="{StaticResource SecondaryButton}"/>
                    </WrapPanel>
                </StackPanel>
            </TabItem>
        </TabControl>

        <Border Grid.Row="3" Background="#172B32" Padding="14" Margin="0,18,0,0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <DockPanel LastChildFill="False">
                    <TextBlock Text="Журнал запуска" DockPanel.Dock="Left" Foreground="White" FontSize="15" FontWeight="SemiBold"/>
                    <ProgressBar x:Name="ActivityProgress" DockPanel.Dock="Right" Width="150" Height="10" IsIndeterminate="False" Margin="20,4,0,0"/>
                    <TextBlock x:Name="ActivityStatusText" DockPanel.Dock="Right" Text="Готово" Foreground="#D9F1ED" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <Button x:Name="OpenRunLogButton" Content="Открыть полный журнал" DockPanel.Dock="Right" Style="{StaticResource SecondaryButton}" Padding="10,5" MinHeight="30" Margin="0,0,12,0" IsEnabled="False"/>
                </DockPanel>
                <TextBox Grid.Row="1" x:Name="LogBox" Background="#0E1D22" Foreground="#D9F1ED" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="8" Margin="0,10,0,0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$windowIconPath = Join-Path $PSScriptRoot 'kappasweep-icon.png'
if (Test-Path -LiteralPath $windowIconPath -PathType Leaf) {
    $windowIcon = New-Object Windows.Media.Imaging.BitmapImage
    $windowIcon.BeginInit()
    $windowIcon.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $windowIcon.UriSource = [Uri]::new($windowIconPath, [UriKind]::Absolute)
    $windowIcon.EndInit()
    $windowIcon.Freeze()
    $window.Icon = $windowIcon
}

function Get-Control {
    param([string]$Name)
    $control = $window.FindName($Name)
    if ($null -eq $control) {
        throw "GUI control was not found: $Name"
    }
    return $control
}

$drivePanel = Get-Control "DrivePanel"
$cachePanel = Get-Control "CachePanel"
$overviewText = Get-Control "OverviewText"
$protectionStateText = Get-Control "ProtectionStateText"
$protectionCapacityText = Get-Control "ProtectionCapacityText"
$protectionLastRunText = Get-Control "ProtectionLastRunText"
$protectionSavingsText = Get-Control "ProtectionSavingsText"
$lockedAppsText = Get-Control "LockedAppsText"
$retryLockedCleanupButton = Get-Control "RetryLockedCleanupButton"
$activitySummaryText = Get-Control "ActivitySummaryText"
$scheduleText = Get-Control "ScheduleText"
$scheduleDiagnosticsText = Get-Control "ScheduleDiagnosticsText"
$systemSafetyText = Get-Control "SystemSafetyText"
$logBox = Get-Control "LogBox"
$activityProgress = Get-Control "ActivityProgress"
$activityStatusText = Get-Control "ActivityStatusText"
$openRunLogButton = Get-Control "OpenRunLogButton"

function Add-Log {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }
    $logBox.AppendText(("[{0}] {1}{2}" -f (Get-Date).ToString("HH:mm:ss"), $Text.Trim(), [Environment]::NewLine))
    $logBox.ScrollToEnd()
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        throw "kappasweep-config.json was not found: $script:ConfigPath"
    }
    $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}

function Get-ConfigValue {
    param(
        $Object,
        [string]$Name,
        $Fallback = $null
    )
    if ($null -eq $Object) {
        return $Fallback
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Fallback
    }
    return $property.Value
}

function Save-Config {
    foreach ($entry in $script:CacheCheckboxes.GetEnumerator()) {
        $script:Config.features | Add-Member -NotePropertyName $entry.Key -NotePropertyValue ([bool]$entry.Value.IsChecked) -Force
    }
    [IO.File]::WriteAllText($script:ConfigPath, ($script:Config | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Add-Log "Настройки сохранены: $script:ConfigPath"
    $overviewText.Text = "Настройки сохранены. Планировщик использует их при следующем запуске."
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N1} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    return "{0:N0} KB" -f ($Bytes / 1KB)
}

function Refresh-Drives {
    $drivePanel.Children.Clear()
    $driveCount = 0
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady -and $_.TotalSize -gt 0 } | Sort-Object Name) {
        $driveCount++
        $freePercent = [Math]::Round(($drive.AvailableFreeSpace / $drive.TotalSize) * 100, 1)
        $accent = if ($freePercent -lt 10) { '#C2413D' } elseif ($freePercent -lt 20) { '#C47A22' } else { '#147D78' }
        $border = New-Object System.Windows.Controls.Border
        $border.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
        $border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#D3DEE1')
        $border.BorderThickness = New-Object Windows.Thickness(1)
        $border.Padding = New-Object Windows.Thickness(16)
        $border.Margin = New-Object Windows.Thickness(0,0,12,0)
        $border.Width = 220
        $stack = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $drive.Name.TrimEnd('\')
        $title.FontSize = 20
        $title.FontWeight = 'SemiBold'
        $title.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($accent)
        $free = New-Object System.Windows.Controls.TextBlock
        $free.Text = "{0} свободно из {1}" -f (Format-Bytes $drive.AvailableFreeSpace), (Format-Bytes $drive.TotalSize)
        $free.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#344B52')
        $free.Margin = New-Object Windows.Thickness(0,5,0,0)
        $percent = New-Object System.Windows.Controls.TextBlock
        $percent.Text = "{0}% свободно" -f $freePercent
        $percent.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#5A6B72')
        $percent.Margin = New-Object Windows.Thickness(0,3,0,0)
        [void]$stack.Children.Add($title)
        [void]$stack.Children.Add($free)
        [void]$stack.Children.Add($percent)
        $border.Child = $stack
        [void]$drivePanel.Children.Add($border)
    }
    if ($driveCount -eq 0) {
        $overviewText.Text = "Локальные диски не найдены."
    }
}

function Refresh-CacheControls {
    $cachePanel.Children.Clear()
    $script:CacheCheckboxes = @{}
    $labels = [ordered]@{
        spotifyCache = 'Spotify (автоочистка отключена ради сохранности данных)'
        discordCache = 'Discord'
        telegramCache = 'Telegram Desktop'
        slackCache = 'Slack'
        teamsCache = 'Microsoft Teams'
        zoomCache = 'Zoom'
        browserCaches = 'Браузеры (только когда закрыты)'
        developerCaches = 'Инструменты разработки'
        gameCaches = 'Игровые лаунчеры'
        notifyOnPressure = 'Уведомления с итогом очистки'
    }
    foreach ($entry in $labels.GetEnumerator()) {
        $check = New-Object System.Windows.Controls.CheckBox
        $check.Content = $entry.Value
        $check.Tag = $entry.Key
        $check.Width = 280
        $check.IsChecked = [bool](Get-ConfigValue -Object $script:Config.features -Name $entry.Key -Fallback $false)
        if ($entry.Key -eq 'spotifyCache') {
            $check.IsChecked = $false
            $check.IsEnabled = $false
            $check.ToolTip = 'Spotify исключён из автоматической очистки: Store-версия смешивает кэш с данными интерфейса.'
        }
        [void]$cachePanel.Children.Add($check)
        $script:CacheCheckboxes[$entry.Key] = $check
    }
}

function Get-KappaSweepLogDirectories {
    $paths = New-Object System.Collections.ArrayList
    $programDataLog = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { '' } else { Join-Path $env:ProgramData 'CodexWindowsCleanup\Logs' }
    $tempLog = if ([string]::IsNullOrWhiteSpace($env:TEMP)) { '' } else { Join-Path $env:TEMP 'CodexWindowsCleanup\Logs' }
    foreach ($path in @($programDataLog, $tempLog)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue)) {
            [void]$paths.Add($path)
        }
    }
    return @($paths | Select-Object -Unique)
}

function Convert-ReclaimedTextToBytes {
    param([string]$Text)

    $match = [regex]::Match($Text, '^\s*([0-9\s.,]+)\s*(bytes|KB|MB|GB|TB)\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return [int64]0
    }

    $numberText = $match.Groups[1].Value -replace '\s', ''
    $numberText = $numberText.Replace(',', '.')
    [double]$number = 0
    if (-not [double]::TryParse($numberText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return [int64]0
    }

    $multiplier = switch ($match.Groups[2].Value.ToUpperInvariant()) {
        'TB' { 1TB }
        'GB' { 1GB }
        'MB' { 1MB }
        'KB' { 1KB }
        default { 1 }
    }
    return [int64][Math]::Round($number * $multiplier)
}

function Get-CleanupRunSummary {
    param([System.IO.FileInfo]$Log)

    try {
        $lines = @(Get-Content -LiteralPath $Log.FullName -Encoding UTF8 -ErrorAction Stop)
        $start = @($lines | Where-Object { $_ -match 'Windows cleanup started' } | Select-Object -First 1)
        $finish = @($lines | Where-Object { $_ -match 'Windows cleanup finished|Analyze finished|Preview finished' } | Select-Object -Last 1)
        if ($finish.Count -eq 0) {
            return $null
        }

        $finishLine = [string]$finish[0]
        $amount = ''
        $amountMatch = [regex]::Match($finishLine, 'reclaimed about (.*?), (?:blocked|failures|errors)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($amountMatch.Success) {
            $amount = $amountMatch.Groups[1].Value
        }

        [int]$removed = 0
        $removedMatch = [regex]::Match($finishLine, 'Removed ([0-9]+) item', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($removedMatch.Success) {
            $removed = [int]$removedMatch.Groups[1].Value
        }

        [int]$locked = 0
        $lockedMatch = [regex]::Match($finishLine, 'blocked: ([0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($lockedMatch.Success) {
            $locked = [int]$lockedMatch.Groups[1].Value
        }
        else {
            $legacyMatch = [regex]::Match($finishLine, 'failures: ([0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($legacyMatch.Success) {
                $locked = [int]$legacyMatch.Groups[1].Value
            }
        }

        [int]$errors = 0
        $errorMatch = [regex]::Match($finishLine, 'errors: ([0-9]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($errorMatch.Success) {
            $errors = [int]$errorMatch.Groups[1].Value
        }

        $apps = New-Object System.Collections.ArrayList
        foreach ($line in $lines) {
            $appMatch = [regex]::Match([string]$line, 'Preflight open app: ([^;]+);', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($appMatch.Success -and -not $apps.Contains($appMatch.Groups[1].Value)) {
                [void]$apps.Add($appMatch.Groups[1].Value)
            }
        }

        $startLine = if ($start.Count -gt 0) { [string]$start[0] } else { '' }
        return [pscustomobject]@{
            Time = $Log.LastWriteTime
            AmountText = $amount
            ReclaimedBytes = Convert-ReclaimedTextToBytes -Text $amount
            RemovedItems = $removed
            LockedItems = $locked
            Errors = $errors
            OpenApps = @($apps)
            IsSmartGuard = ($startLine -match 'SmartGuard=True')
            LogPath = $Log.FullName
        }
    }
    catch {
        return $null
    }
}

function Get-CleanupRunSummaries {
    $files = New-Object System.Collections.ArrayList
    foreach ($directory in Get-KappaSweepLogDirectories) {
        Get-ChildItem -LiteralPath $directory -Filter 'cleanup-*.log' -File -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$files.Add($_) }
    }

    foreach ($file in @($files | Sort-Object LastWriteTime -Descending | Select-Object -Unique -First 80)) {
        $summary = Get-CleanupRunSummary -Log $file
        if ($null -ne $summary) {
            $summary
        }
    }
}

function Get-ScheduleHealth {
    $taskPath = '\Codex Windows Cleanup\'
    $expectedNames = @('Pressure Guard', 'Startup Guard', 'Deep Weekly')
    $expectedScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'cleanup-windows.ps1'))
    $missing = New-Object System.Collections.ArrayList
    $pathProblems = New-Object System.Collections.ArrayList
    $resultProblems = New-Object System.Collections.ArrayList
    $records = New-Object System.Collections.ArrayList

    foreach ($name in $expectedNames) {
        try {
            $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction Stop
            $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop
            $actionMatches = 0
            foreach ($action in @($task.Actions)) {
                $match = [regex]::Match([string]$action.Arguments, '-File\s+"([^"]+)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $match.Success) {
                    continue
                }
                $actionMatches++
                $actualScript = [IO.Path]::GetFullPath($match.Groups[1].Value)
                if (-not [string]::Equals($actualScript, $expectedScript, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $actualScript -PathType Leaf)) {
                    [void]$pathProblems.Add($name)
                }
            }
            if ($actionMatches -eq 0) {
                [void]$pathProblems.Add($name)
            }

            [int]$result = $info.LastTaskResult
            if ($result -notin @(0, 267009, 267011)) {
                [void]$resultProblems.Add($name)
            }
            [void]$records.Add([pscustomobject]@{
                Name = $name
                LastRun = [datetime]$info.LastRunTime
                NextRun = [datetime]$info.NextRunTime
                LastResult = $result
            })
        }
        catch {
            [void]$missing.Add($name)
        }
    }

    $lastRun = @($records | Where-Object { $_.LastRun.Year -ge 2000 } | Sort-Object LastRun -Descending | Select-Object -First 1)
    $nextRun = @($records | Where-Object { $_.NextRun -gt (Get-Date) } | Sort-Object NextRun | Select-Object -First 1)
    $lastRunValue = if ($lastRun.Count -gt 0) { $lastRun[0].LastRun } else { [datetime]::MinValue }
    $nextRunValue = if ($nextRun.Count -gt 0) { $nextRun[0].NextRun } else { [datetime]::MinValue }

    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ IsHealthy = $false; Summary = 'Не все задачи установлены.'; Detail = 'Нет задач: ' + ($missing -join ', ') + '. Нажми «Проверить и починить задачи».'; LastRun = $lastRunValue; NextRun = $nextRunValue }
    }
    if ($pathProblems.Count -gt 0) {
        return [pscustomobject]@{ IsHealthy = $false; Summary = 'Найден старый или отсутствующий путь.'; Detail = 'Путь движка не совпадает у: ' + (($pathProblems | Select-Object -Unique) -join ', ') + '. Нажми «Проверить и починить задачи».'; LastRun = $lastRunValue; NextRun = $nextRunValue }
    }
    if ($resultProblems.Count -gt 0) {
        return [pscustomobject]@{ IsHealthy = $false; Summary = 'Есть задача с кодом ошибки.'; Detail = 'Проверь журналы и переустанови задачу: ' + (($resultProblems | Select-Object -Unique) -join ', ') + '.'; LastRun = $lastRunValue; NextRun = $nextRunValue }
    }

    return [pscustomobject]@{ IsHealthy = $true; Summary = 'Задачи подключены к текущему движку.'; Detail = 'Путь всех трёх задач совпадает с текущим KappaSweepData.'; LastRun = $lastRunValue; NextRun = $nextRunValue }
}

function Refresh-Summary {
    $enabled = @($script:CacheCheckboxes.GetEnumerator() | Where-Object { $_.Value.IsChecked } | ForEach-Object { $_.Value.Content })
    $profile = [string](Get-ConfigValue -Object $script:Config -Name 'defaultProfile' -Fallback 'Safe')
    $schedule = $script:Config.schedule
    $thresholds = $script:Config.thresholds
    $guardDrive = [string](Get-ConfigValue -Object $script:Config.paths -Name 'guardDrive' -Fallback 'C:')
    $guardDrive = $guardDrive.TrimEnd('\')
    [int]$minFreeGB = Get-ConfigValue -Object $thresholds -Name 'minFreeGB' -Fallback 35
    [int]$minFreePercent = Get-ConfigValue -Object $thresholds -Name 'minFreePercent' -Fallback 18
    $perDrive = Get-ConfigValue -Object $thresholds -Name 'perDrive' -Fallback $null
    $perDriveThreshold = Get-ConfigValue -Object $perDrive -Name $guardDrive -Fallback $null
    if ($null -ne $perDriveThreshold) {
        $minFreeGB = [int](Get-ConfigValue -Object $perDriveThreshold -Name 'minFreeGB' -Fallback $minFreeGB)
        $minFreePercent = [int](Get-ConfigValue -Object $perDriveThreshold -Name 'minFreePercent' -Fallback $minFreePercent)
    }

    $health = Get-ScheduleHealth
    $stateColor = if ($health.IsHealthy) { '#147D78' } else { '#C2413D' }
    $protectionStateText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($stateColor)
    $protectionStateText.Text = $health.Summary

    try {
        $drive = New-Object System.IO.DriveInfo ("{0}\" -f $guardDrive)
        if ($drive.IsReady) {
            $freePercent = [Math]::Round(($drive.AvailableFreeSpace / $drive.TotalSize) * 100, 1)
            $belowTarget = $drive.AvailableFreeSpace -lt ($minFreeGB * 1GB) -or $freePercent -lt $minFreePercent
            $protectionCapacityText.Text = "{0} свободно ({1:N1}%). Цель: {2} GB / {3}%{4}" -f (Format-Bytes $drive.AvailableFreeSpace), $freePercent, $minFreeGB, $minFreePercent, $(if ($belowTarget) { ' · уборка включена' } else { ' · порог не достигнут' })
        }
        else {
            $protectionCapacityText.Text = "$guardDrive недоступен."
        }
    }
    catch {
        $protectionCapacityText.Text = "Не удалось прочитать $guardDrive."
    }

    $runs = @(Get-CleanupRunSummaries)
    $latestRun = @($runs | Sort-Object Time -Descending | Select-Object -First 1)
    $latestRunValue = if ($latestRun.Count -gt 0) { $latestRun[0] } else { $null }
    if ($null -ne $latestRunValue) {
        $amountText = if ([string]::IsNullOrWhiteSpace($latestRunValue.AmountText)) { 'без измеримого объёма' } else { $latestRunValue.AmountText }
        $protectionLastRunText.Text = "{0:dd.MM HH:mm} · {1}" -f $latestRunValue.Time, $amountText
    }
    elseif ($health.LastRun.Year -ge 2000) {
        $protectionLastRunText.Text = "{0:dd.MM HH:mm} · без лога" -f $health.LastRun
    }
    else {
        $protectionLastRunText.Text = 'Запусков пока нет.'
    }

    $weekStart = (Get-Date).AddDays(-7)
    [int64]$weekBytes = 0
    $weekRuns = @($runs | Where-Object { $_.Time -ge $weekStart })
    foreach ($run in $weekRuns) {
        $weekBytes += [int64]$run.ReclaimedBytes
    }
    $protectionSavingsText.Text = "За 7 дней: {0}`nЗапусков: {1}" -f (Format-Bytes $weekBytes), $weekRuns.Count

    if ($null -ne $latestRunValue -and $latestRunValue.Errors -gt 0) {
        $lockedAppsText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#C2413D')
        $lockedAppsText.Text = "Последняя уборка завершилась с ошибками: $($latestRunValue.Errors). Открой полный журнал перед повтором."
        $retryLockedCleanupButton.IsEnabled = $false
    }
    elseif ($null -ne $latestRunValue -and $latestRunValue.LockedItems -gt 0) {
        $lockedAppsText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#C47A22')
        $appsText = if ($latestRunValue.OpenApps.Count -gt 0) { ' Открыты: ' + ($latestRunValue.OpenApps -join ', ') + '.' } else { '' }
        $lockedAppsText.Text = "Пропущено занятых файлов: $($latestRunValue.LockedItems). Это не сбой: закрой приложения и повтори очистку.$appsText"
        $retryLockedCleanupButton.IsEnabled = $true
    }
    else {
        $lockedAppsText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#5A6B72')
        $lockedAppsText.Text = 'Последняя уборка завершилась без занятых файлов.'
        $retryLockedCleanupButton.IsEnabled = $false
    }

    $overviewText.Text = "Профиль: $profile. Включено переключателей: $($enabled.Count). Следующая задача: $($(if ($health.NextRun.Year -ge 2000) { $health.NextRun.ToString('dd.MM HH:mm') } else { 'не определена' }))."
    $scheduleText.Text = "Pressure Guard: каждые $([int](Get-ConfigValue -Object $schedule -Name 'guardEveryHours' -Fallback 3)) ч. с $([string](Get-ConfigValue -Object $schedule -Name 'guardStart' -Fallback '00:15')). Deep Weekly: $([string](Get-ConfigValue -Object $schedule -Name 'deepDay' -Fallback 'Sunday')) в $([string](Get-ConfigValue -Object $schedule -Name 'deepWeekly' -Fallback '03:20')). $($health.Summary)"
    $scheduleDiagnosticsText.Text = $health.Detail
}

function Refresh-SystemSummary {
    $drive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { 'C:' } else { $env:SystemDrive.TrimEnd('\') }
    $hiberFile = Join-Path "$drive\" 'hiberfil.sys'
    $hiberSize = [int64]0
    if (Test-Path -LiteralPath $hiberFile -PathType Leaf) {
        $hiberSize = [int64](Get-Item -LiteralPath $hiberFile).Length
    }
    $hiberText = if ($hiberSize -gt 0) { (Format-Bytes $hiberSize) } else { 'не найден' }
    $systemSafetyText.Text = "Файл гибернации: $hiberText. Отключение освобождает место, но выключает гибернацию и Fast Startup; включение полностью обратимо. Анализ компонентного хранилища ничего не меняет."
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-PowerShellInvocationArgument {
    param([string]$Value)

    # KappaSweep passes only its own fixed parameter names unquoted; all values stay quoted.
    if ($Value -match '^-[A-Za-z][A-Za-z0-9]*$') {
        return $Value
    }
    return ConvertTo-PowerShellLiteral $Value
}

function ConvertTo-ProcessArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
    }) -join ' ')
}

function Get-ActionTitle {
    param([string]$FileName)

    switch ($FileName) {
        'cleanup-windows.ps1' { return 'Очистка' }
        'space-hog-report.ps1' { return 'Анализ места' }
        'system-maintenance-check.ps1' { return 'Проверка системы' }
        'system-tweaks.ps1' { return 'Системное действие' }
        'install-scheduled-cleanup.ps1' { return 'Настройка Планировщика' }
        'check-log-encoding.ps1' { return 'Проверка кодировки' }
        default { return $FileName }
    }
}

function Set-ActionState {
    param(
        [bool]$Running,
        [string]$Message
    )

    $activityProgress.IsIndeterminate = $Running
    if (-not $Running) {
        $activityProgress.Value = 0
    }
    $activityStatusText.Text = $Message
    $activitySummaryText.Text = $Message
    $activitySummaryText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString(
        $(if ($Running) { '#C47A22' } else { '#147D78' }))

    foreach ($name in @($script:ActionControlNames)) {
        $control = $window.FindName($name)
        if ($null -ne $control) {
            $control.IsEnabled = -not $Running
        }
    }
}

function Complete-KappaSweepAction {
    param(
        [int]$ExitCode,
        [string]$ActionTitle,
        [switch]$Elevated
    )

    if ($null -eq $script:ActiveProcess) {
        return
    }

    if ($null -ne $script:ActionTimer) {
        $script:ActionTimer.Stop()
    }
    $script:ActionTimer = $null
    $script:ActiveProcess = $null
    $script:ActiveAction = ''
    $script:ActiveRunLogPath = ''
    $script:ActiveRunLineCount = 0
    $script:ActiveActionStartedAt = $null
    $script:ActiveActionGuard = $null
    $result = if ($ExitCode -eq 0) { "Готово: $ActionTitle." } else { "$ActionTitle завершено с кодом $ExitCode. Проверь журнал ниже." }
    Set-ActionState -Running $false -Message $result
    Add-Log $result
    try {
        Refresh-Drives
        Refresh-Summary
        Refresh-SystemSummary
    }
    catch {
        Add-Log ("Не удалось обновить состояние дисков: " + $_.Exception.Message)
    }
}

function Get-KappaSweepActionGuard {
    param(
        [string]$FileName,
        [string[]]$ScriptArguments = @()
    )

    $timeout = New-TimeSpan -Minutes 5
    if ($FileName -eq 'cleanup-windows.ps1') {
        $isDeep = ($ScriptArguments -contains '-Deep') -or (([string]::Join(' ', $ScriptArguments)) -match '(?i)(^|\s)-Profile\s+Deep(\s|$)')
        $timeout = if ($isDeep) { New-TimeSpan -Minutes 45 } else { New-TimeSpan -Minutes 12 }
    }
    elseif ($FileName -eq 'space-hog-report.ps1') {
        $timeout = New-TimeSpan -Minutes 15
    }
    elseif ($FileName -eq 'system-maintenance-check.ps1' -and $ScriptArguments -contains '-AnalyzeComponentStore') {
        $timeout = New-TimeSpan -Minutes 20
    }
    elseif ($FileName -eq 'install-scheduled-cleanup.ps1') {
        $timeout = New-TimeSpan -Minutes 3
    }

    return [pscustomobject]@{
        Timeout = $timeout
        WorkingSetLimitBytes = [int64]1.5GB
    }
}

function Stop-KappaSweepActionForGuard {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ActionTitle,
        [string]$Reason,
        [switch]$Elevated,
        [string]$RunLogPath = ''
    )

    Add-Log "ПРЕДОХРАНИТЕЛЬ: $ActionTitle остановлен. $Reason"
    try {
        if (-not $Process.HasExited) {
            & taskkill.exe /PID $Process.Id /T /F | Out-Null
            $Process.WaitForExit(5000) | Out-Null
        }
    }
    catch {
        Add-Log ("Не удалось остановить дерево процесса: " + $_.Exception.Message)
    }

    Add-KappaSweepRunLogLines -Path $RunLogPath
    Complete-KappaSweepAction -ExitCode 124 -ActionTitle $ActionTitle -Elevated:$Elevated
}

function New-KappaSweepRunLogPath {
    $runLogDirectory = Join-Path $PSScriptRoot 'KappaSweepRuns'
    New-Item -ItemType Directory -Path $runLogDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $runLogDirectory -Filter 'run-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 24 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return Join-Path $runLogDirectory ("run-{0}-{1}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N'))
}

function Add-KappaSweepRunLogLines {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
    for ($index = $script:ActiveRunLineCount; $index -lt $lines.Count; $index++) {
        Add-Log ([string]$lines[$index])
    }
    $script:ActiveRunLineCount = $lines.Count
}

function Start-KappaSweepProcessMonitor {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ActionTitle,
        [switch]$Elevated,
        [string]$RunLogPath = '',
        [datetime]$StartedAt,
        $Guard
    )

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(180)
    $timer.Add_Tick({
        try {
            Add-KappaSweepRunLogLines -Path $RunLogPath
            if ($Process.HasExited) {
                Add-KappaSweepRunLogLines -Path $RunLogPath
                Complete-KappaSweepAction -ExitCode $Process.ExitCode -ActionTitle $ActionTitle -Elevated:$Elevated
                return
            }

            $Process.Refresh()
            if (((Get-Date) - $StartedAt) -gt $Guard.Timeout) {
                Stop-KappaSweepActionForGuard -Process $Process -ActionTitle $ActionTitle -Reason ("Превышен лимит времени $([int]$Guard.Timeout.TotalMinutes) мин.") -Elevated:$Elevated -RunLogPath $RunLogPath
                return
            }

            if ($Process.WorkingSet64 -gt $Guard.WorkingSetLimitBytes) {
                $memoryGB = [math]::Round($Process.WorkingSet64 / 1GB, 2)
                Stop-KappaSweepActionForGuard -Process $Process -ActionTitle $ActionTitle -Reason ("Память процесса достигла $memoryGB ГБ.") -Elevated:$Elevated -RunLogPath $RunLogPath
            }
        }
        catch {
            Add-Log ("ОШИБКА мониторинга ${ActionTitle}: " + $_.Exception.Message)
            if ($Process.HasExited) {
                Complete-KappaSweepAction -ExitCode $Process.ExitCode -ActionTitle $ActionTitle -Elevated:$Elevated
            }
        }
    }.GetNewClosure())

    $script:ActionTimer = $timer
    $timer.Start()
}

function Start-KappaSweepScript {
    param(
        [string]$FileName,
        [string[]]$ScriptArguments = @(),
        [switch]$Elevated
    )

    if ($null -ne $script:ActiveProcess -and -not $script:ActiveProcess.HasExited) {
        Add-Log "Действие уже выполняется. Дождись завершения текущего запуска."
        return
    }
    $actionTitle = Get-ActionTitle -FileName $FileName
    $guard = Get-KappaSweepActionGuard -FileName $FileName -ScriptArguments $ScriptArguments
    $target = Join-Path $PSScriptRoot $FileName
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        Add-Log "Файл не найден: $target"
        return
    }
    try {
        $runLogPath = New-KappaSweepRunLogPath
        $script:ActiveRunLogPath = $runLogPath
        $script:ActiveRunLineCount = 0
        $openRunLogButton.IsEnabled = $true
    }
    catch {
        Set-ActionState -Running $false -Message ("Не удалось подготовить журнал для $actionTitle.")
        Add-Log ("ОШИБКА подготовки журнала: " + $_.Exception.Message)
        return
    }
    $invocationArguments = @($ScriptArguments | ForEach-Object { ConvertTo-PowerShellInvocationArgument ([string]$_) }) -join ' '
    $commandParts = @(
        '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)'
        '$global:OutputEncoding = [Console]::OutputEncoding'
        '$ErrorActionPreference = ''Stop'''
        'try {'
        ('    & ' + (ConvertTo-PowerShellLiteral $target) + ' ' + $invocationArguments + ' *>&1 | Out-File -LiteralPath ' + (ConvertTo-PowerShellLiteral $runLogPath) + ' -Encoding UTF8')
        '    exit 0'
        '}'
        'catch {'
        ('    ($_ | Out-String -Width 240).TrimEnd() | Out-File -LiteralPath ' + (ConvertTo-PowerShellLiteral $runLogPath) + ' -Append -Encoding UTF8')
        '    exit 1'
        '}'
    )
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($commandParts -join [Environment]::NewLine)))
    $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encodedCommand)
    $startedAt = Get-Date
    $script:ActiveActionStartedAt = $startedAt
    $script:ActiveActionGuard = $guard
    Set-ActionState -Running $true -Message ("Выполняется: $actionTitle. Не закрывай KappaSweep.")
    if ($Elevated) {
        try {
            $process = Start-Process -FilePath $script:PowerShellPath -ArgumentList (ConvertTo-ProcessArguments $args) -Verb RunAs -PassThru -ErrorAction Stop
            $script:ActiveProcess = $process
            $script:ActiveAction = $actionTitle
            Start-KappaSweepProcessMonitor -Process $process -ActionTitle $actionTitle -Elevated -RunLogPath $runLogPath -StartedAt $startedAt -Guard $guard
            Add-Log "Запущено с правами администратора: $FileName. Подтверди UAC, затем прогресс останется здесь."
        }
        catch {
            $script:ActiveProcess = $null
            Set-ActionState -Running $false -Message ("Не удалось запустить $actionTitle.")
            Add-Log ("ОШИБКА запуска с правами администратора: " + $_.Exception.Message)
        }
        return
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:PowerShellPath
    $info.Arguments = ConvertTo-ProcessArguments $args
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) {
            throw "Процесс не был запущен."
        }
        $script:ActiveProcess = $process
        $script:ActiveAction = $actionTitle
        Start-KappaSweepProcessMonitor -Process $process -ActionTitle $actionTitle -RunLogPath $runLogPath -StartedAt $startedAt -Guard $guard
        Add-Log "Запуск: $actionTitle"
    }
    catch {
        $script:ActiveProcess = $null
        Set-ActionState -Running $false -Message ("Не удалось запустить $actionTitle.")
        Add-Log ("ОШИБКА запуска: " + $_.Exception.Message)
    }
}

function Open-ExternalPath {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Start-Process -FilePath $Path | Out-Null
    }
}

function Open-RunLog {
    $path = $script:ActiveRunLogPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $runLogDirectory = Join-Path $PSScriptRoot 'KappaSweepRuns'
        $latest = Get-ChildItem -LiteralPath $runLogDirectory -Filter 'run-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        $path = if ($null -eq $latest) { '' } else { $latest.FullName }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        Add-Log 'Журналов запусков пока нет.'
        return
    }
    Start-Process -FilePath 'notepad.exe' -ArgumentList (ConvertTo-ProcessArguments @($path)) | Out-Null
}

Read-Config
Refresh-Drives
Refresh-CacheControls
Refresh-Summary
Refresh-SystemSummary
Add-Log "Control Center v$script:KappaSweepVersion готов."

$controls = @{
    RefreshButton = { Refresh-Drives; Refresh-Summary; Refresh-SystemSummary; Add-Log "Данные обновлены." }
    OpenFolderButton = { Open-ExternalPath -Path $PSScriptRoot }
    RecommendedCleanupButton = { Start-KappaSweepScript -FileName 'cleanup-windows.ps1' -ScriptArguments @('-Profile','Safe','-SmartGuard','-OpenReport','-ConfigPath',$script:ConfigPath) }
    RetryLockedCleanupButton = { Start-KappaSweepScript -FileName 'cleanup-windows.ps1' -ScriptArguments @('-Profile','Safe','-SmartGuard','-OpenReport','-ConfigPath',$script:ConfigPath) }
    AnalyzeButton = { Start-KappaSweepScript -FileName 'cleanup-windows.ps1' -ScriptArguments @('-Analyze','-Profile','Emergency','-OpenReport','-ConfigPath',$script:ConfigPath) }
    SafeCleanupButton = { Start-KappaSweepScript -FileName 'cleanup-windows.ps1' -ScriptArguments @('-Profile','Safe','-OpenReport','-ConfigPath',$script:ConfigPath) }
    SmartCleanupButton = { Start-KappaSweepScript -FileName 'cleanup-windows.ps1' -ScriptArguments @('-SmartGuard','-AggressiveSafe','-CleanDeveloperCaches','-CleanRegistry','-ConfigPath',$script:ConfigPath) }
    SpaceHogButton = { Start-KappaSweepScript -FileName 'space-hog-report.ps1' -ScriptArguments @('-Top','12','-OpenReport') }
    OpenReportButton = { Start-KappaSweepScript -FileName 'open-latest-report.ps1' }
    HistoryButton = { Start-KappaSweepScript -FileName 'show-cleanup-history.ps1' }
    SaveSettingsButton = { Save-Config; Refresh-Summary }
    OpenConfigButton = { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:ConfigPath) }
    InstallScheduleButton = { Start-KappaSweepScript -FileName 'install-scheduled-cleanup.ps1' -ScriptArguments @('-ConfigPath',$script:ConfigPath) -Elevated }
    RepairShortcutButton = { Start-KappaSweepScript -FileName 'repair-powershell-shortcut.ps1' }
    SystemStatusButton = { Start-KappaSweepScript -FileName 'system-maintenance-check.ps1' }
    AnalyzeComponentStoreButton = { Start-KappaSweepScript -FileName 'system-maintenance-check.ps1' -ScriptArguments @('-AnalyzeComponentStore') -Elevated }
    DeepMaintenanceButton = { Start-KappaSweepScript -FileName 'cleanup-windows.ps1' -ScriptArguments @('-Profile','Deep','-OpenReport','-ConfigPath',$script:ConfigPath) -Elevated }
    DisableHibernationButton = { Start-KappaSweepScript -FileName 'system-tweaks.ps1' -ScriptArguments @('-DisableHibernation') -Elevated; Refresh-SystemSummary }
    EnableHibernationButton = { Start-KappaSweepScript -FileName 'system-tweaks.ps1' -ScriptArguments @('-EnableHibernation') -Elevated; Refresh-SystemSummary }
    LogEncodingButton = { Start-KappaSweepScript -FileName 'check-log-encoding.ps1' }
    SpaceReportButton = { Start-KappaSweepScript -FileName 'space-hog-report.ps1' -ScriptArguments @('-Top','12','-OpenReport') }
    OpenLatestReportButton = { Start-KappaSweepScript -FileName 'open-latest-report.ps1' }
    ShowHistoryButton = { Start-KappaSweepScript -FileName 'show-cleanup-history.ps1' }
    OpenLogsButton = { Open-ExternalPath -Path (Join-Path $env:ProgramData 'CodexWindowsCleanup\Logs') }
    OpenRunLogButton = { Open-RunLog }
}

$script:ActionControlNames = @(
    'RecommendedCleanupButton', 'RetryLockedCleanupButton', 'AnalyzeButton', 'SafeCleanupButton', 'SmartCleanupButton',
    'SpaceHogButton', 'OpenReportButton', 'HistoryButton', 'InstallScheduleButton',
    'RepairShortcutButton', 'SystemStatusButton', 'AnalyzeComponentStoreButton',
    'DeepMaintenanceButton', 'DisableHibernationButton', 'EnableHibernationButton',
    'LogEncodingButton', 'SpaceReportButton', 'OpenLatestReportButton', 'ShowHistoryButton'
)

foreach ($entry in $controls.GetEnumerator()) {
    $control = Get-Control $entry.Key
    $action = $entry.Value
    $control.Add_Click({
        try {
            & $action
        }
        catch {
            $message = $_.Exception.Message
            $script:ActiveProcess = $null
            Set-ActionState -Running $false -Message 'Действие не запустилось. Подробности в журнале.'
            Add-Log ("ОШИБКА интерфейса: " + $message)
        }
    }.GetNewClosure())
}

if ($Test) {
    $safeGuard = Get-KappaSweepActionGuard -FileName 'cleanup-windows.ps1' -ScriptArguments @('-Profile', 'Safe')
    $deepGuard = Get-KappaSweepActionGuard -FileName 'cleanup-windows.ps1' -ScriptArguments @('-Profile', 'Deep')
    $spaceGuard = Get-KappaSweepActionGuard -FileName 'space-hog-report.ps1'
    if ($safeGuard.Timeout.TotalMinutes -ne 12 -or $deepGuard.Timeout.TotalMinutes -ne 45 -or $spaceGuard.Timeout.TotalMinutes -ne 15 -or $safeGuard.WorkingSetLimitBytes -ne [int64]1.5GB) {
        throw 'KappaSweep action guard test failed.'
    }
    Write-Output ("KAPPASWEEP_UI_TEST_OK controls={0} caches={1} version={2} guardMB={3}" -f $controls.Count, $script:CacheCheckboxes.Count, $script:KappaSweepVersion, [math]::Round($safeGuard.WorkingSetLimitBytes / 1MB))
    return
}

if ($AutoCloseSeconds -gt 0) {
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = New-TimeSpan -Seconds $AutoCloseSeconds
    $timer.Add_Tick({ $timer.Stop(); $window.Close() })
    $timer.Start()
}

[void]$window.ShowDialog()
