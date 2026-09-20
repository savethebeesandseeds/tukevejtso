@echo off
setlocal

call "%~dp0toolkit.cmd" %*

endlocal & exit /b %ERRORLEVEL%
