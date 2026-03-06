@echo off
setlocal
cd /d "%~dp0"

set "PY=.venv\Scripts\python.exe"
set "VPN_NAME=VPNOndiss"
set "CONFIG_FILE=%~dp0config.txt"
set "CRED_FILE=%USERPROFILE%\.api_cuil\vpn_credentials.xml"
set "HOST_NAME=%COMPUTERNAME%"
if "%HOST_NAME%"=="" set "HOST_NAME=unknown"
set "MACRO_FILE=%~dp0forty_ui_macro_%HOST_NAME%.json"
set "MACRO_FALLBACK=%~dp0forty_ui_macro_unknown.json"
set "PLAY_MACRO_FILE=%MACRO_FILE%"
if not exist "%PLAY_MACRO_FILE%" if exist "%MACRO_FALLBACK%" set "PLAY_MACRO_FILE=%MACRO_FALLBACK%"
set "FORTY_EXE="
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$base = $env:ProgramFiles; $hit = Get-ChildItem -Path $base -Recurse -File -Filter '*ortiClient.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName; if ($hit) { $hit }"`) do set "FORTY_EXE=%%A"

if not exist "%PY%" (
  echo [ERROR] No existe %PY%
  echo Ejecuta primero: P1_setup_entorno.bat
  pause
  exit /b 1
)

:menu
echo.
echo ============================================
echo   VPN Forty - Macro UI (api_cuil)
echo ============================================
echo Perfil VPN activo: %VPN_NAME%
echo 1^) Grabar macro UI (finalizar con F8)
echo 2^) Reproducir macro UI y conectar VPN
echo 3^) Abrir entorno completo (P4)
echo 4^) Verificar credenciales (P3)
echo 5^) Configurar credenciales (P2)
echo 6^) Diagnostico rapido
echo 0^) Salir
echo.
choice /c 1234560 /n /m "Elige opcion [1,2,3,4,5,6,0]: "

if errorlevel 7 goto end
if errorlevel 6 goto diag
if errorlevel 5 goto setupcreds
if errorlevel 4 goto checkcreds
if errorlevel 3 goto runp4
if errorlevel 2 goto play
if errorlevel 1 goto record

goto menu

:record
echo.
if not exist "%FORTY_EXE%" (
  echo [WARN] No se encontro FortyClient en:
  echo %FORTY_EXE%
  echo La grabacion puede fallar si FortyClient no esta instalado.
  echo.
)
echo [INFO] Iniciando grabacion UI...
echo [INFO] Si no captura eventos automaticamente, se activara modo guiado por coordenadas.
"%PY%" -m src.vpn_fortytoken --record-ui --record-debug --ui-timeout 60 --record-timeout 120 --macro-file "%MACRO_FILE%"
echo [INFO] Macro esperada: %MACRO_FILE%
echo.
pause
goto menu

:play
echo.
if not exist "%CRED_FILE%" (
  echo [ERROR] No existe archivo de credenciales VPN:
  echo %CRED_FILE%
  echo Ejecuta: P2_configurar_credenciales.bat
  echo O usa la opcion 5 del menu
  pause
  goto menu
)
if not exist "%FORTY_EXE%" (
  echo [WARN] No se encontro FortyClient en:
  echo %FORTY_EXE%
  echo El helper UI puede fallar sin esta instalacion.
  echo.
)
if exist "%MACRO_FILE%" (
  echo [INFO] Macro detectada: %MACRO_FILE%
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Get-Content -Raw '%MACRO_FILE%' | ConvertFrom-Json | Out-Null; exit 0 } catch { Write-Host '[ERROR] Macro JSON invalida: ' $_.Exception.Message -ForegroundColor Red; exit 1 }"
  if errorlevel 1 (
    echo [ERROR] Corrige %MACRO_FILE% antes de reproducir.
    pause
    goto menu
  )
) else if exist "%PLAY_MACRO_FILE%" (
  echo [INFO] Macro fallback detectada: %PLAY_MACRO_FILE%
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Get-Content -Raw '%PLAY_MACRO_FILE%' | ConvertFrom-Json | Out-Null; exit 0 } catch { Write-Host '[ERROR] Macro JSON invalida: ' $_.Exception.Message -ForegroundColor Red; exit 1 }"
  if errorlevel 1 (
    echo [ERROR] Corrige %PLAY_MACRO_FILE% antes de reproducir.
    pause
    goto menu
  )
) else (
  echo [INFO] No hay macro grabada en %MACRO_FILE%. Se usara flujo UI estandar.
)
echo [INFO] Reproduciendo macro y conectando VPN...
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$credPath = Join-Path $env:USERPROFILE '.api_cuil\vpn_credentials.xml'; $c = Import-Clixml $credPath; $c.UserName"`) do set "FORTY_VPN_USER=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$credPath = Join-Path $env:USERPROFILE '.api_cuil\vpn_credentials.xml'; $c = Import-Clixml $credPath; $c.GetNetworkCredential().Password"`) do set "FORTY_VPN_PASSWORD=%%A"
"%PY%" -m src.vpn_fortytoken --vpn-name "%VPN_NAME%" --verify-timeout 180 --play-ui "%PLAY_MACRO_FILE%" --macro-file "%MACRO_FILE%" --manual-2fa
if errorlevel 1 (
  echo [ERROR] Fallo opcion 2. Codigo de salida: %errorlevel%
  echo Revisa si FortyClient esta abierto, si la macro apunta a coordenadas vigentes,
  echo y si las credenciales VPN son correctas.
  echo.
  pause
  goto menu
)
echo.
pause
goto end

:checkcreds
echo.
call .\P3_verificar_credenciales.bat
echo.
pause
goto menu

:setupcreds
echo.
call .\P2_configurar_credenciales.bat
echo.
pause
goto menu

:diag
echo.
echo ============================================
echo   Diagnostico rapido VPN
echo ============================================
echo [INFO] Proyecto: %~dp0
echo [INFO] Python venv: %PY%
if exist "%PY%" (echo        [OK]) else (echo        [FALTA])
echo [INFO] Perfil VPN: %VPN_NAME%
echo [INFO] Credenciales: %CRED_FILE%
if exist "%CRED_FILE%" (echo        [OK]) else (echo        [FALTA])
echo [INFO] Macro UI: %MACRO_FILE%
if exist "%MACRO_FILE%" (echo        [OK]) else (echo        [NO CREADA])
echo [INFO] FortyClient: %FORTY_EXE%
if exist "%FORTY_EXE%" (echo        [OK]) else (echo        [FALTA])
echo ============================================
echo.
pause
goto menu

:runp4
echo.
echo [INFO] Ejecutando P4_abrir_entorno.bat...
call .\P4_abrir_entorno.bat
echo.
pause
goto menu

:end
echo Saliendo...
exit /b 0
