@echo off
setlocal

set "ROOT=%~dp0"

if not "%~1"=="" goto args

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\menu.ps1"
set "TOOLKIT_CHOICE=%ERRORLEVEL%"

if "%TOOLKIT_CHOICE%"=="20" goto cuwacunu_dev

goto done

:args
if /I "%~1"=="reboot" goto reboot_guard
if /I "%~1"=="auto-reboot" goto reboot_guard
if /I "%~1"=="reboots" goto reboot_guard
if /I "%~1"=="demo" goto ui_demo
if /I "%~1"=="ui" goto ui_demo
if /I "%~1"=="help" goto help
if /I "%~1"=="--help" goto help
if /I "%~1"=="-h" goto help

echo Unknown toolkit command: %~1
echo.
goto help

:reboot_guard
set "REBOOT_ACTION=%~2"
if "%REBOOT_ACTION%"=="" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\windows-update-reboots.ps1"
if "%REBOOT_ACTION%"=="" goto done
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\windows-update-reboots.ps1" -Action "%REBOOT_ACTION%"
goto done

:ui_demo
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\ui-demo.ps1"
goto done

:help
echo tukevejtso for Windows
echo.
echo Usage:
echo   tk                         Open the interactive menu
echo   tk demo                    Show terminal interface primitives
echo   tk reboot                  Open the reboot guard toggle
echo   tk reboot status           Show Windows Update auto-reboot guard state
echo   tk reboot toggle           Toggle the auto-reboot guard
echo   tk reboot disable          Disable auto-reboots while logged in
echo   tk reboot enable           Allow auto-reboots again
goto done

:cuwacunu_dev
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\docker-cuwacunu-shell.ps1"

:done
endlocal
