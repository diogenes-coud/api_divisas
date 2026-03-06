@echo off
REM ============================================
REM CONFIGURAR CREDENCIALES
REM ============================================

cd /d "%~dp0"

echo.
echo ============================================
echo  CONFIGURACION DE CREDENCIALES
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0P2_setup_credentials.ps1"

if errorlevel 1 (
    echo.
    echo ERROR: Falló la configuración
    pause
    exit /b 1
)

echo.
pause
