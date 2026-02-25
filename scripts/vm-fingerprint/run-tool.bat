@echo off
:: VM Fingerprint Tool Launcher
:: Automatically runs as Administrator

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d \"%~dp0\" && powershell -ExecutionPolicy Bypass -File \"%~dp0vm-fingerprint-tool.ps1\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0vm-fingerprint-tool.ps1"
pause
