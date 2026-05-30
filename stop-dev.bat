@echo off
REM This wrapper makes the PowerShell shutdown script easy to run by double-click
REM or from the terminal with a single command.
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-dev.ps1" %*
set "exit_code=%ERRORLEVEL%"

if not "%exit_code%"=="0" if "%~1"=="" (
  echo.
  echo Jellyfish dev shutdown failed with exit code %exit_code%.
  pause
)

exit /b %exit_code%
