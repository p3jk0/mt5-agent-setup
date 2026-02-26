@echo off
:: MT5 Agent Setup — auto-elevate launcher
:: Usage: run.bat  OR  run.bat -PortStart 3100 -SkipStart

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process 'pwsh.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0Setup-MT5Agents.ps1"" %*' -Verb RunAs -Wait"
    exit /b
)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-MT5Agents.ps1" %*
pause
