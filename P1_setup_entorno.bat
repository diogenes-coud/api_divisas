@echo off
REM ============================================
REM SETUP ENTORNO - Inicializa el proyecto
REM ============================================

cd /d "%~dp0"

echo.
echo ============================================
echo  INICIALIZANDO PROYECTO
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0P1_init_project.ps1"

if errorlevel 1 (
    echo.
    echo ERROR: Falló la inicialización
    pause
    exit /b 1
)

echo.
echo ============================================
echo  Proyecto inicializado correctamente
echo ============================================
echo.
pause
