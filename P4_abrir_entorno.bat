@echo off
REM ============================================
REM ABRIR ENTORNO - Abre PowerShell con el entorno activado
REM ============================================

cd /d "%~dp0"

for %%I in ("%CD%") do set PROJECT_NAME=%%~nxI

start "Python - %PROJECT_NAME%" powershell -NoExit -ExecutionPolicy Bypass -Command ^
"Clear-Host; ^
Write-Host '============================================' -ForegroundColor Cyan; ^
Write-Host '  ENTORNO PYTHON - %PROJECT_NAME%' -ForegroundColor Cyan; ^
Write-Host '============================================' -ForegroundColor Cyan; ^
Write-Host ''; ^
cd '%CD%'; ^
& '%CD%\P4_open_env.ps1'"
