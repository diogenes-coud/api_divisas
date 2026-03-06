@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0G2_LocalToServer.ps1"
echo.
pause
