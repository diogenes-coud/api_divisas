@echo off
REM Abrir PowerShell en la carpeta del proyecto y activar .venv

cd /d "%~dp0"

IF NOT EXIST ".venv\Scripts\Activate.ps1" (
    echo ERROR: No existe el entorno virtual .venv
    echo Ejecuta primero setup_entorno.bat
    pause
    exit /b 1
)

start powershell -NoExit -ExecutionPolicy Bypass -Command ".\.venv\Scripts\Activate.ps1; Write-Host '✅ Entorno .venv activado en api_so'"
