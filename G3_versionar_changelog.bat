@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0G3_versionar_changelog.ps1"
echo.
pause
