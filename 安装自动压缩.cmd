@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage.ps1" -Action Install
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
