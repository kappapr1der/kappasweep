@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "SCRIPT=%~dp0cleanup-windows.ps1"
set "CONFIG=%~dp0kappasweep-config.json"

if not exist "%SCRIPT%" (
    echo cleanup-windows.ps1 was not found next to this file.
    pause
    exit /b 1
)

if not exist "%CONFIG%" (
    echo kappasweep-config.json was not found next to this file.
    echo The menu can still run, but config defaults will not be loaded.
    echo.
    pause
)

:menu
cls
echo.
echo ==============================
echo KappaSweep
echo ==============================
echo.
echo 1. Scan results (no deletion)
echo 2. Safe cleanup
echo 3. Gaming cleanup
echo 4. Deep cleanup (admin)
echo 5. Emergency cleanup (admin)
echo 6. Space hog report (read-only)
echo 7. Cleanup history
echo 8. Open latest HTML report
echo 9. Open logs
echo A. Install scheduled tasks (admin)
echo B. Edit config
echo C. Cache switches, disk thresholds, and exclusions
echo D. Disk analyzer lite
echo G. Open KappaSweep Control Center
echo P. Repair PowerShell shortcuts
echo M. System maintenance check (no deletion)
echo Q. Quit
echo.
set "PICK="
set /p "PICK=Choose: "

if /i "%PICK%"=="q" exit /b 0

if "%PICK%"=="1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Analyze -Profile Emergency -OpenReport
    goto after
)

if "%PICK%"=="2" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Profile Safe -OpenReport
    goto after
)

if "%PICK%"=="3" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Profile Gaming -OpenReport
    goto after
)

if "%PICK%"=="4" (
    call "%~dp0cleanup-deep-now.bat"
    goto menu
)

if "%PICK%"=="5" (
    call "%~dp0cleanup-emergency-now.bat"
    goto menu
)

if "%PICK%"=="6" (
    call "%~dp0space-hog-report.bat"
    goto menu
)

if "%PICK%"=="7" (
    call "%~dp0show-cleanup-history.bat"
    goto menu
)

if "%PICK%"=="8" (
    call "%~dp0open-latest-report.bat"
    goto menu
)

if "%PICK%"=="9" (
    call "%~dp0open-cleanup-logs.bat"
    goto menu
)

if /i "%PICK%"=="a" (
    call "%~dp0install-scheduled-cleanup.bat"
    goto menu
)

if /i "%PICK%"=="b" (
    start "" notepad.exe "%CONFIG%"
    goto menu
)

if /i "%PICK%"=="c" (
    call "%~dp0manage-kappasweep-settings.bat"
    goto menu
)

if /i "%PICK%"=="d" (
    call "%~dp0disk-analyzer-lite.bat"
    goto menu
)

if /i "%PICK%"=="g" (
    call "%~dp0kappasweep-ui.bat"
    goto menu
)

if /i "%PICK%"=="p" (
    call "%~dp0repair-powershell-shortcut.bat"
    goto menu
)

if /i "%PICK%"=="m" (
    call "%~dp0system-maintenance-check.bat"
    goto menu
)

echo.
echo Unknown choice: %PICK%

:after
echo.
pause
goto menu
