@echo off
rem SMITE 2 Ping overlay launcher (no install needed)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SMITE2Ping.ps1"
exit /b
