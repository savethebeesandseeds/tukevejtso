@echo off
setlocal

set "ROOT=%~dp0"

:menu
if not "%~1"=="" goto args
set "TOOLKIT_FROM_MENU=1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\menu.ps1"
set "TOOLKIT_CHOICE=%ERRORLEVEL%"

if "%TOOLKIT_CHOICE%"=="20" goto cuwacunu_dev
if "%TOOLKIT_CHOICE%"=="21" goto robotics_learning_dev
if "%TOOLKIT_CHOICE%"=="22" goto terminal_transparency
if "%TOOLKIT_CHOICE%"=="23" goto enchanted_transcription
if "%TOOLKIT_CHOICE%"=="24" goto openai_key
if "%TOOLKIT_CHOICE%"=="25" goto password_manager
if "%TOOLKIT_CHOICE%"=="26" goto enhanced_typing

goto done

:args
set "TOOLKIT_FROM_MENU="
if /I "%~1"=="password" goto password_manager
if /I "%~1"=="robotics-learning" goto robotics_learning_dev
if /I "%~1"=="terminal-transparency" goto terminal_transparency
if /I "%~1"=="openai-key" goto openai_key
if /I "%~1"=="enchanted-transcription" goto enchanted_transcription
if /I "%~1"=="enchance-transcription" goto enchanted_transcription
if /I "%~1"=="transcription" goto enchanted_transcription
if /I "%~1"=="typing" goto enhanced_typing
if /I "%~1"=="enhanced-typing" goto enhanced_typing
if /I "%~1"=="enchanted-typing" goto enhanced_typing
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
echo   tk password                Generate passwords with length/complexity options
echo   tk robotics-learning       Open the robotics-learning dev container
echo   tk terminal-transparency   Set opacity for the current terminal window
echo   tk openai-key              Store or update the OpenAI API key
echo   tk openai-key -Status      Show whether the OpenAI API key is stored
echo   tk transcription           Start the local Whisper transcription agent
echo   tk enchanted-transcription Start the Enchanted transcription agent
echo   tk enhanced-typing         Dictate, refine, and copy text with OpenAI
echo   tk demo                    Show terminal interface primitives
echo   tk reboot                  Open the reboot guard toggle
echo   tk reboot status           Show Windows Update auto-reboot guard state
echo   tk reboot toggle           Toggle the auto-reboot guard
echo   tk reboot disable          Disable auto-reboots while logged in
echo   tk reboot enable           Allow auto-reboots again
goto done

:cuwacunu_dev
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\docker-cuwacunu-shell.ps1"
goto done

:robotics_learning_dev
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\docker-robotics-learning-shell.ps1"
goto done

:terminal_transparency
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\terminal-transparency.ps1"
goto done

:openai_key
if /I "%~1"=="openai-key" shift /1
set "OPENAI_KEY_ARGS="
:ok_args
if "%~1"=="" goto ok_run
set OPENAI_KEY_ARGS=%OPENAI_KEY_ARGS% "%~1"
shift /1
goto ok_args
:ok_run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\openai-api-key.ps1" %OPENAI_KEY_ARGS%
if "%TOOLKIT_FROM_MENU%"=="1" (
    echo.
    pause
    set "TOOLKIT_CHOICE="
    goto menu
)
goto done

:password_manager
if /I "%~1"=="password" shift /1
set "PASSWORD_ARGS="
:pw_args
if "%~1"=="" goto pw_run
set PASSWORD_ARGS=%PASSWORD_ARGS% "%~1"
shift /1
goto pw_args
:pw_run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\password-manager.ps1" %PASSWORD_ARGS%
if "%TOOLKIT_FROM_MENU%"=="1" (
    echo.
    pause
    set "TOOLKIT_CHOICE="
    goto menu
)
goto done

:enchanted_transcription
if /I "%~1"=="transcription" shift /1
if /I "%~1"=="enchanted-transcription" shift /1
if /I "%~1"=="enchance-transcription" shift /1
set "TRANSCRIPTION_ARGS="
:et_args
if "%~1"=="" goto et_run
set TRANSCRIPTION_ARGS=%TRANSCRIPTION_ARGS% "%~1"
shift /1
goto et_args
:et_run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%agents\enchanted-transcription\run.ps1" %TRANSCRIPTION_ARGS%
goto done

:enhanced_typing
if /I "%~1"=="typing" shift /1
if /I "%~1"=="enhanced-typing" shift /1
if /I "%~1"=="enchanted-typing" shift /1
set "TYPING_ARGS="
:typing_args
if "%~1"=="" goto typing_run
set TYPING_ARGS=%TYPING_ARGS% "%~1"
shift /1
goto typing_args
:typing_run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%agents\enhanced-typing\run.ps1" %TYPING_ARGS%
goto done

:done
endlocal
