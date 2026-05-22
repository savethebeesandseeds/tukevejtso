@echo off
setlocal

set "TOOLKIT_ROOT=%~dp0.."
for %%I in ("%TOOLKIT_ROOT%") do set "TOOLKIT_ROOT=%%~fI"

echo %PATH% | find /I "%TOOLKIT_ROOT%" >nul
if errorlevel 1 (
    endlocal & set "PATH=%PATH%;%TOOLKIT_ROOT%"
    echo Added toolkit to this Command Prompt session:
    echo %TOOLKIT_ROOT%
) else (
    echo Toolkit is already available in this Command Prompt session.
    endlocal
)
