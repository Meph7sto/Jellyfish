@echo off
REM This wrapper makes the PowerShell dev launcher easy to run by double-clicking
REM from Explorer or by invoking a single batch file from the terminal.
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-dev.ps1" %*
set "exit_code=%ERRORLEVEL%"

if not "%exit_code%"=="0" if "%~1"=="" (
  echo.
  echo Jellyfish dev startup failed with exit code %exit_code%.
  pause
)

exit /b %exit_code%
