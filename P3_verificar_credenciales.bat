@echo off
REM ============================================
REM VERIFICAR CREDENCIALES
REM ============================================

cd /d "%~dp0"

echo.
echo ============================================
echo  VERIFICACION DE CREDENCIALES
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0P3_check_credentials.ps1"

echo.
pause
