@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0G1_ServerToLocal.ps1"
echo.
pause
