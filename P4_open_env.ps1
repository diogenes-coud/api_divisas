# ==========================================
# Open Project Environment
# ==========================================

Write-Host "Activando entorno virtual..."
& "$PSScriptRoot\.venv\Scripts\Activate.ps1"

function Ask-YesNoWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [int]$TimeoutSeconds = 10,
        [ValidateSet("S","N")][string]$Default = "N",
        [switch]$ExitOnTimeout
    )

    $Default = $Default.ToUpper()
    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $endTime) {
        $remaining = [int]([Math]::Ceiling(($endTime - (Get-Date)).TotalSeconds))
        Write-Host -NoNewline ("`r{0} [S/N] [Default={1}] -> {2}s " -f $Prompt, $Default, $remaining)
        Start-Sleep -Milliseconds 200
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $ch = $key.KeyChar.ToString().ToUpper()
            if ($ch -in @("S","N")) {
                Write-Host ("`r{0} [S/N] [Default={1}] -> {2} " -f $Prompt, $Default, $ch)
                return $ch
            }
        }
    }

    Write-Host ("`r{0} [S/N] [Default={1}] -> {1} (timeout)" -f $Prompt, $Default)
    return $Default
}

function Resolve-DbProbeTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    $dbPort = 1433
    $tmpPort = 0
    if ($env:DB_PORT -and [int]::TryParse($env:DB_PORT, [ref]$tmpPort)) {
        $dbPort = $tmpPort
    }

    $serverHost = $Server
    $port = $dbPort

    if ($Server -match "^\s*([^,:\\]+)\s*[,\:]\s*(\d+)\s*$") {
        $serverHost = $matches[1]
        $port = [int]$matches[2]
    } elseif ($Server -match "^\s*([^,:\\]+)") {
        $serverHost = $matches[1]
    }

    return [PSCustomObject]@{
        Host = $serverHost
        Port = $port
    }
}

function Test-DbServerConnectivity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    $probe = Resolve-DbProbeTarget -Server $Server

    $hasTnc = (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) -ne $null
    if ($hasTnc) {
        try {
            $prevProgressPreference = $global:ProgressPreference
            $global:ProgressPreference = 'SilentlyContinue'
            $tcpOk = Test-NetConnection -ComputerName $probe.Host -Port $probe.Port -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($tcpOk) {
                return [PSCustomObject]@{ Ok = $true; Method = "TCP:$($probe.Port)"; Host = $probe.Host; Port = $probe.Port }
            }
        } catch {
        } finally {
            $global:ProgressPreference = $prevProgressPreference
        }
    }

    $pingOk = Test-Connection -ComputerName $probe.Host -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingOk) {
        return [PSCustomObject]@{ Ok = $true; Method = "PING"; Host = $probe.Host; Port = $probe.Port }
    }

    return [PSCustomObject]@{ Ok = $false; Method = "NONE"; Host = $probe.Host; Port = $probe.Port }
}

function Try-ConnectServers {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Candidates,
        [string]$PhaseLabel = ""
    )

    foreach ($candidate in $Candidates) {
        $server = $candidate.Server
        $probe = Resolve-DbProbeTarget -Server $server

        $prefix = if ($PhaseLabel) { "[$PhaseLabel] " } else { "" }
        Write-Host ("{0}Probando DB_SERVER: {1} (host={2}, puerto={3}, requiere_vpn={4})" -f $prefix, $server, $probe.Host, $probe.Port, $candidate.RequiresVpn) -ForegroundColor Gray
        $check = Test-DbServerConnectivity -Server $server
        if ($check.Ok) {
            [System.Environment]::SetEnvironmentVariable("DB_SERVER", $candidate.Server, "Process")
            [System.Environment]::SetEnvironmentVariable("DB_REQUIRES_VPN", ($(if ($candidate.RequiresVpn) { "true" } else { "false" })), "Process")
            Write-Host "✓ DB_SERVER seleccionado automáticamente: $($candidate.Server) (método=$($check.Method))" -ForegroundColor Green
            return $candidate
        }
    }

    return $null
}

function Ensure-VpnCredentialsLoaded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VpnCredFile,
        [int]$TimeoutSeconds = 10
    )

    if (Test-Path $VpnCredFile) {
        $vpnChange = Ask-YesNoWithTimeout -Prompt "¿Quieres cambiar credenciales VPN?" -TimeoutSeconds $TimeoutSeconds -Default "N"
        if ($vpnChange -eq "S") {
            try {
                $vpnCredNew = Get-Credential -Message "Nuevas credenciales VPN"
                if (-not $vpnCredNew) {
                    Write-Host "[INFO] Actualización de credenciales VPN cancelada por el usuario." -ForegroundColor Gray
                    return $false
                }
                $vpnCredNew | Export-Clixml $VpnCredFile -Force
                $env:FORTY_VPN_USER = $vpnCredNew.UserName
                $env:FORTY_VPN_PASSWORD = $vpnCredNew.GetNetworkCredential().Password
                Write-Host "[OK] Credenciales VPN actualizadas: $VpnCredFile" -ForegroundColor Green
                return $true
            } catch {
                Write-Host "[WARN] No se pudieron actualizar credenciales VPN: $_" -ForegroundColor Yellow
                return $false
            }
        } else {
            try {
                $vpnCred = Import-Clixml $VpnCredFile
                if ($vpnCred -and $vpnCred.UserName -and $vpnCred.GetNetworkCredential().Password) {
                    $env:FORTY_VPN_USER = $vpnCred.UserName
                    $env:FORTY_VPN_PASSWORD = $vpnCred.GetNetworkCredential().Password
                    Write-Host "✓ Credenciales VPN cargadas desde XML" -ForegroundColor Green
                    return $true
                } else {
                    Write-Host "[WARN] Credencial VPN inválida en XML: $VpnCredFile" -ForegroundColor Yellow
                    return $false
                }
            } catch {
                Write-Host "[WARN] No se pudieron cargar credenciales VPN desde XML: $_" -ForegroundColor Yellow
                return $false
            }
        }
    }

    # Intentar obtener desde Credential Manager
    $vpnTargets = @("${projectName}_VPN", "${projectName}-vpn")
    $vpnWin = Get-WinCredFor -Targets $vpnTargets
    if ($vpnWin) {
        $env:FORTY_VPN_USER = $vpnWin.Credential.UserName
        $env:FORTY_VPN_PASSWORD = $vpnWin.Credential.GetNetworkCredential().Password
        Write-Host "✓ Credenciales VPN cargadas desde Credential Manager (target: $($vpnWin.Target))." -ForegroundColor Green
        try {
            $securePwd = ConvertTo-SecureString $env:FORTY_VPN_PASSWORD -AsPlainText -Force
            $toSaveV = New-Object System.Management.Automation.PSCredential($env:FORTY_VPN_USER, $securePwd)
            $toSaveV | Export-Clixml $VpnCredFile -Force
            Write-Host "[OK] Credenciales VPN exportadas a: $VpnCredFile" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] No se pudo exportar credencial VPN a XML: $_" -ForegroundColor Yellow
        }
        return $true
    }

    # No hay credenciales: pedir crear (default S)
    $createVpn = Ask-YesNoWithTimeout -Prompt "No se encontraron credenciales VPN. ¿Querés crearlas ahora?" -TimeoutSeconds $TimeoutSeconds -Default "S"
    if ($createVpn -eq "S") {
        try {
            $nv = Get-Credential -Message "Credenciales VPN"
            if (-not $nv) {
                Write-Host "[INFO] Creación de credenciales VPN cancelada por el usuario." -ForegroundColor Gray
                return $false
            }
            $nv | Export-Clixml $VpnCredFile -Force
            $env:FORTY_VPN_USER = $nv.UserName
            $env:FORTY_VPN_PASSWORD = $nv.GetNetworkCredential().Password
            Write-Host "[OK] Credenciales VPN guardadas en: $VpnCredFile" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "[WARN] No se pudieron guardar credenciales VPN: $_" -ForegroundColor Yellow
            return $false
        }
    }

    Write-Host "[INFO] No se crearon credenciales VPN." -ForegroundColor Gray
    return $false
}

function Invoke-VpnConnect {
    $cmdTemplate = $env:FORTY_VPN_CONNECT_CMD
    if (-not $cmdTemplate) {
        Write-Host "[ERROR] Falta FORTY_VPN_CONNECT_CMD para abrir VPN." -ForegroundColor Red
        Write-Host "Define FORTY_VPN_CONNECT_CMD en config.txt del proyecto o en la carpeta de usuario .[proyecto]" -ForegroundColor Yellow
        return $false
    }

    $vpnUser = $env:FORTY_VPN_USER
    $vpnPass = $env:FORTY_VPN_PASSWORD
    if (-not $vpnUser -or -not $vpnPass) {
        Write-Host "[ERROR] Faltan FORTY_VPN_USER/FORTY_VPN_PASSWORD en entorno." -ForegroundColor Red
        return $false
    }

    $resolvedExe = $env:FORTY_CLIENT_EXE
    if (-not $resolvedExe) {
        $resolvedExe = Get-ChildItem -Path $env:ProgramFiles -Recurse -File -Filter '*ortiClient.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($resolvedExe) {
            [System.Environment]::SetEnvironmentVariable("FORTY_CLIENT_EXE", $resolvedExe, "Process")
        }
    }

    $cmd = $cmdTemplate.Replace("{user}", $vpnUser).Replace("{password}", $vpnPass)
    if ($resolvedExe) {
        $cmd = $cmd.Replace("{FORTY_CLIENT_EXE}", $resolvedExe)
    }

    $useUiRaw = $env:FORTY_USE_UI_AUTOMATION
    if (-not $useUiRaw) { $useUiRaw = "true" }
    $useUi = $useUiRaw.Trim().ToLower() -in @("true", "1", "yes", "y", "si", "sí", "s")

    if ($useUi -and $cmdTemplate -match '--name\s+"([^"]+)"') {
        $vpnName = $matches[1]
        $pyExe = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
        if (-not (Test-Path $pyExe)) { $pyExe = "python" }

        $hostName = $env:COMPUTERNAME
        if (-not $hostName) { $hostName = "unknown" }
        $macroFile = Join-Path $PSScriptRoot ("forty_ui_macro_{0}.json" -f $hostName)
        $macroFallback = Join-Path $PSScriptRoot "forty_ui_macro_unknown.json"
        $playMacro = $macroFile
        if (-not (Test-Path $playMacro) -and (Test-Path $macroFallback)) {
            $playMacro = $macroFallback
        }

        $uiTimeout = 60
        $verifyTimeout = 180
        $keyPause = 0.15

        $tmpInt = 0
        $tmpDouble = 0.0
        if ($env:FORTY_UI_TIMEOUT -and [int]::TryParse($env:FORTY_UI_TIMEOUT, [ref]$tmpInt)) {
            $uiTimeout = $tmpInt
        }
        if ($env:FORTY_VERIFY_TIMEOUT -and [int]::TryParse($env:FORTY_VERIFY_TIMEOUT, [ref]$tmpInt)) {
            $verifyTimeout = $tmpInt
        }
        if ($env:FORTY_KEY_PAUSE -and [double]::TryParse($env:FORTY_KEY_PAUSE, [ref]$tmpDouble)) {
            $keyPause = $tmpDouble
        }

        $uiArgs = @(
            "-m", "src.vpn_fortytoken",
            "--vpn-name", $vpnName,
            "--ui-timeout", $uiTimeout.ToString(),
            "--verify-timeout", $verifyTimeout.ToString(),
            "--manual-2fa",
            "--macro-file", $macroFile,
            "--play-ui", $playMacro
        )

        if ($env:FORTY_UI_KEY_SEQUENCE) {
            $uiArgs += @("--key-sequence", $env:FORTY_UI_KEY_SEQUENCE)
            $uiArgs += @("--key-pause", $keyPause.ToString())
        }

        Write-Host "Intentando abrir VPN con helper Python UI (FortyClient/FortyToken)..." -ForegroundColor Cyan
        $helperTimeout = [Math]::Max(30, $uiTimeout + $verifyTimeout + 30)
        if ($env:FORTY_HELPER_TIMEOUT -and [int]::TryParse($env:FORTY_HELPER_TIMEOUT, [ref]$tmpInt) -and $tmpInt -gt 0) {
            $helperTimeout = $tmpInt
        }

        Write-Host ("[VPN_UI] Timeout helper configurado: {0}s" -f $helperTimeout) -ForegroundColor DarkCyan
        Write-Host "[VPN_RETRY] Ventana de reintento SQL: 120s (fija)" -ForegroundColor DarkGray

        $uiProcess = Start-Process -FilePath $pyExe -ArgumentList $uiArgs -PassThru -NoNewWindow
        $startedAt = Get-Date
        $timedOut = $false

        while (-not $uiProcess.HasExited) {
            $elapsed = [int][Math]::Floor(((Get-Date) - $startedAt).TotalSeconds)
            $remaining = $helperTimeout - $elapsed

            if ($remaining -le 0) {
                Write-Host ("`r[VPN_UI] Timeout de helper alcanzado ({0}s). Se continúa con fallback...                 " -f $helperTimeout) -ForegroundColor Yellow
                try {
                    Stop-Process -Id $uiProcess.Id -Force -ErrorAction SilentlyContinue
                } catch {
                }
                $timedOut = $true
                break
            }

            Write-Host -NoNewline ("`r[VPN_UI] Ejecutando macro/2FA... timeout en {0}s " -f $remaining)
            Start-Sleep -Seconds 1
        }
        Write-Host ""

        if ($timedOut) {
            $uiRc = 124
        } else {
            $uiRc = $uiProcess.ExitCode
        }

        if ($uiRc -eq 0) {
            return $true
        }

        Write-Host "[WARN] Helper Python UI finalizó con código $uiRc. Se continúa con fallback CLI." -ForegroundColor Yellow
    }

    $directTried = $false

    if ($cmdTemplate -match 'ortiClient\.exe' -and $cmdTemplate -match '--name\s+"([^"]+)"') {
        $directTried = $true
        $vpnName = $matches[1]
        $fortyExe = Get-ChildItem -Path $env:ProgramFiles -Recurse -File -Filter '*ortiClient.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

        if (Test-Path $fortyExe) {
            Write-Host "Intentando abrir VPN (FortyClient directo) para evitar problemas de parseo de contraseña..." -ForegroundColor Cyan
            Write-Host ("Perfil VPN: {0} | Usuario: {1}" -f $vpnName, $vpnUser) -ForegroundColor DarkGray

            $p = Start-Process -FilePath $fortyExe -ArgumentList @('vpn', 'connect', '--name', $vpnName, '--user', $vpnUser, '--password', $vpnPass) -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) {
                return $true
            }

            Write-Host ("[WARN] FortyClient directo finalizó con código {0}" -f $p.ExitCode) -ForegroundColor Yellow
        }
    }

    # Intento 1: comando configurado
    $safeCmd = $cmd -replace '(--password\s+")[^"]*(")', '$1***$2'
    Write-Host "Intentando abrir VPN (FortyToken)..." -ForegroundColor Cyan
    Write-Host "Comando: $safeCmd" -ForegroundColor DarkGray
    cmd /c $cmd
    $rc = $LASTEXITCODE
    if ($rc -eq 0) {
        return $true
    }

    Write-Host "[WARN] Comando VPN finalizó con código $rc" -ForegroundColor Yellow

    # Intento 2: fallback FortyClient.exe -> FortyClientConsole.exe
    if ($cmd -match "ortiClient\.exe") {
        $fallbackCmd = $cmd -replace "ortiClient\.exe", "ortiClientConsole.exe"
        $safeFallbackCmd = $fallbackCmd -replace '(--password\s+")[^"]*(")', '$1***$2'
        Write-Host "Reintentando con fallback CLI: $safeFallbackCmd" -ForegroundColor Yellow
        cmd /c $fallbackCmd
        $rc2 = $LASTEXITCODE
        if ($rc2 -eq 0) {
            return $true
        }
        Write-Host "[WARN] Fallback VPN finalizó con código $rc2" -ForegroundColor Yellow
    }

    $consoleExe = Get-ChildItem -Path $env:ProgramFiles -Recurse -File -Filter '*ortiClientConsole.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $directTried -and $consoleExe -and (Test-Path $consoleExe) -and $cmdTemplate -match '--name\s+"([^"]+)"') {
        $vpnName = $matches[1]
        Write-Host "Intentando fallback directo con FortyClientConsole.exe..." -ForegroundColor Yellow
        $p3 = Start-Process -FilePath $consoleExe -ArgumentList @('connect', '-s', $vpnName, '-u', $vpnUser, '-p', $vpnPass) -Wait -PassThru -NoNewWindow
        if ($p3.ExitCode -eq 0) {
            return $true
        }
        Write-Host ("[WARN] FortyClientConsole directo finalizó con código {0}" -f $p3.ExitCode) -ForegroundColor Yellow
    }

    return $false
}

function Test-VpnTunnelUp {
    $fortyAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceDescription -match 'ortinet|orti|SSL VPN' -or
            $_.Name -match 'orti|SSL'
        }

    if (-not $fortyAdapters) {
        Write-Host "[WARN] No se detectaron adaptadores Forty para validar túnel." -ForegroundColor Yellow
        return $false
    }

    $up = @($fortyAdapters | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Connected' })
    if ($up.Count -gt 0) {
        Write-Host ("✓ Adaptador VPN activo: {0}" -f (($up | Select-Object -ExpandProperty Name) -join ', ')) -ForegroundColor Green
        return $true
    }

    Write-Host "[WARN] VPN no activa: adaptadores Forty sin estado Up/Connected." -ForegroundColor Yellow
    return $false
}

# ==========================================
# 1. PREPARAR RUTAS DE CREDENCIALES (DPAPI)
# ==========================================


# Usar carpeta de usuario para credenciales
# Carpeta de usuario para credenciales, genérica por proyecto
$projectName = Split-Path $PSScriptRoot -Leaf
$userProjectDir = Join-Path $env:USERPROFILE ("." + $projectName)
if (-not (Test-Path $userProjectDir)) {
    New-Item -ItemType Directory -Path $userProjectDir -Force | Out-Null
}
$credFileNew = Join-Path $userProjectDir "credentials.xml"
$vpnCredFile = Join-Path $userProjectDir "vpn_credentials.xml"
$credFile = $credFileNew

# Mostrar la ruta antes de cargar o pedir credenciales DB
Write-Host ("Ruta de credenciales DB: {0}" -f $credFile) -ForegroundColor Cyan
if (-not (Test-Path $credFile)) {
    $createCred = Ask-YesNoWithTimeout -Prompt "No se encontraron credenciales DB. ¿Quieres crearlas ahora?" -TimeoutSeconds 30 -Default "S"
    if ($createCred -eq "S") {
        Write-Host "Ingresa credenciales DB (se guardarán de forma segura):" -ForegroundColor Yellow
        try {
            $newCred = Get-Credential -Message "Credenciales DB"
            if (-not $newCred) {
                Write-Host "[INFO] Creación de credenciales DB cancelada por el usuario." -ForegroundColor Gray
            } else {
            $newCred | Export-Clixml $credFileNew -Force
            $credFile = $credFileNew
            Write-Host "[OK] Credenciales DB guardadas en: $credFileNew" -ForegroundColor Green
            }
        } catch {
            Write-Host "[WARN] No se pudieron guardar las credenciales: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Continuando sin credenciales DB guardadas." -ForegroundColor Gray
    }
}

# Cargar config local (fallback de DB_SERVER/DB_DATABASE/DB_DRIVER)
$localConfigNew = Join-Path $PSScriptRoot ("." + $projectName + "\config.txt")
$localConfig = $localConfigNew

function Import-KeyValueConfigToEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path $ConfigPath)) { return }

    Get-Content $ConfigPath | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }

        if ($line.Contains("=")) {
            $parts = $line.Split('=', 2)
            if ($parts.Count -ne 2) { return }

            $key = $parts[0].Trim()
            $value = $parts[1].Trim()

            if ($key -and $value) {
                [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
            }
        }
    }

    Write-Host "$Label cargada: $ConfigPath" -ForegroundColor Green
}

Import-KeyValueConfigToEnv -ConfigPath $localConfig -Label "Config local"

$projectConfig = Join-Path $PSScriptRoot "config.txt"
Import-KeyValueConfigToEnv -ConfigPath $projectConfig -Label "Config proyecto"

function Get-ServerCandidatesFromMap {
    param([string]$MapRaw)

    $list = @()
    if (-not $MapRaw) { return $list }

    $MapRaw.Split(';') | ForEach-Object {
        $entry = $_.Trim()
        if (-not $entry) { return }

        $parts = $entry.Split(':', 2)
        if ($parts.Count -ne 2) { return }

        $server = $parts[0].Trim()
        $vpnRaw = $parts[1].Trim().ToLower()
        if (-not $server) { return }

        $requiresVpn = $false
        if ($vpnRaw -in @("true", "1", "yes", "y", "si", "sí", "s")) {
            $requiresVpn = $true
        }

        $list += [PSCustomObject]@{
            Server = $server
            RequiresVpn = $requiresVpn
        }
    }

    return $list
}

function Get-ServerCandidatesFromProjectConfig {
    param([string]$ConfigPath)

    $list = @()
    if (-not (Test-Path $ConfigPath)) { return $list }

    foreach ($raw in Get-Content $ConfigPath) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }

        if ($line -match "^sqlserver\s*[:=]\s*([^,]+)\s*,\s*(true|false)\s*$") {
            $server = $matches[1].Trim().Trim('"').Trim("'")
            $vpnRaw = $matches[2].Trim().ToLower()
            $requiresVpn = $vpnRaw -eq "true"

            $list += [PSCustomObject]@{
                Server = $server
                RequiresVpn = $requiresVpn
            }
        }
    }

    return $list
}

function Import-DbCredentialWithFallback {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if (-not $path -or -not (Test-Path $path)) { continue }
        try {
            $candidate = Import-Clixml $path
            if ($candidate -and $candidate.UserName -and $candidate.GetNetworkCredential().Password) {
                return $candidate
            }
        } catch {
            continue
        }
    }

    return $null
}

# -----------------------------------------
# Intentar obtener credenciales desde Windows Credential Manager
# Requiere el modulo CredentialManager (Get-StoredCredential)
# -----------------------------------------
function Load-CredsFromWindows {
    param(
        [string]$ProjectName
    )

    try {
        Import-Module CredentialManager -ErrorAction SilentlyContinue
    } catch {
    }

    if (-not (Get-Module -Name CredentialManager)) {
        Write-Host "[INFO] Módulo CredentialManager no disponible; usando fallback de archivos XML." -ForegroundColor Gray
        return $null
    }

    $candidates = @()
    $candidates += "${ProjectName}_DB"
    $candidates += "${ProjectName}-db"
    $candidates += "${ProjectName}_VPN"
    $candidates += "${ProjectName}-vpn"
    if ($env:DB_SERVER) { $candidates += $env:DB_SERVER }

    foreach ($t in $candidates | Where-Object { $_ }) {
        try {
            $sc = Get-StoredCredential -Target $t -ErrorAction SilentlyContinue
            if ($sc -and $sc.UserName -and $sc.GetNetworkCredential().Password) {
                Write-Host "✓ Credencial desde Windows Credential Manager encontrada para target: $t" -ForegroundColor Green
                return @{ Target = $t; Credential = $sc }
            }
        } catch {
            continue
        }
    }

    Write-Host "[INFO] No se encontraron credenciales en Windows Credential Manager para proyecto $ProjectName" -ForegroundColor Gray
    return $null
}

# Consultar credencial de Windows para una lista de targets, retorna la primera encontrada
function Get-WinCredFor {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Targets
    )

    try { Import-Module CredentialManager -ErrorAction SilentlyContinue } catch {}
    if (-not (Get-Module -Name CredentialManager)) { return $null }

    foreach ($t in $Targets | Where-Object { $_ }) {
        try {
            $sc = Get-StoredCredential -Target $t -ErrorAction SilentlyContinue
            if ($sc -and $sc.UserName -and $sc.GetNetworkCredential().Password) {
                return @{ Target = $t; Credential = $sc }
            }
        } catch { continue }
    }
    return $null
}

# ==========================================
# 2. CARGAR RUTAS Y CONFIG DEL ONDRIVE
# ==========================================
$projectName = Split-Path $PSScriptRoot -Leaf

# OneDrive fijo según solicitud del proyecto: comprobar ambas variantes y usar la que exista
$oneDrive = $null
$oneDriveCandidates = @('E:\onedrive', 'E:\OneDrive')
foreach ($cand in $oneDriveCandidates) {
    if (Test-Path $cand) { $oneDrive = $cand; break }
}
if (-not $oneDrive) {
    Write-Host "[WARN] No se detectó OneDrive en E:\onedrive ni en E:\OneDrive. Intentando variable de entorno OneDrive..." -ForegroundColor Yellow
    if ($env:OneDrive) {
        $oneDrive = $env:OneDrive
        Write-Host "Usando OneDrive desde variable de entorno: $oneDrive" -ForegroundColor Gray
    } else {
        $oneDrive = $null
        Write-Host "[WARN] No se encontró OneDrive. Variables externas no cargadas." -ForegroundColor Yellow
    }
} else {
    Write-Host "OneDrive detectado: $oneDrive" -ForegroundColor Green
}

if ($oneDrive) {
    $configPath = Join-Path $oneDrive "Python\EnvConfigs\$projectName"
    $envScript = Join-Path $configPath "env.ps1"
    $dbScript = Join-Path $configPath "db.ps1"
    $venvPath = Join-Path $PSScriptRoot ".venv"
    $pythonExe = Join-Path $venvPath "Scripts\python.exe"

    # Mostrar rutas resueltas para verificación
    Write-Host "";
    Write-Host "Rutas resueltas:" -ForegroundColor Cyan
    Write-Host (" PSScriptRoot : {0}" -f $PSScriptRoot)
    Write-Host (" Project name : {0}" -f $projectName)
    Write-Host (" OneDrive     : {0}" -f $oneDrive)
    Write-Host (" Config path  : {0}" -f $configPath)
    Write-Host (" env.ps1      : {0}" -f $envScript)
    Write-Host (" db.ps1       : {0}" -f $dbScript)
    Write-Host (" Venv path    : {0}" -f $venvPath)
    Write-Host (" Python exe   : {0}" -f $pythonExe)
    Write-Host ""
    if (Test-Path $envScript) {
        Write-Host "Cargando env.ps1: $envScript" -ForegroundColor Green
        . $envScript
    } else {
        Write-Host "env.ps1 no encontrado (opcional): $envScript" -ForegroundColor Gray
    }

    $dbScript = Join-Path $configPath "db.ps1"
    if (Test-Path $dbScript) {
        Write-Host "Cargando db.ps1: $dbScript" -ForegroundColor Green
        try {
            . $dbScript
            Write-Host "✓ db.ps1 cargado" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Ocurrió un error al cargar db.ps1: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "db.ps1 no encontrado (opcional): $dbScript" -ForegroundColor Gray
    }
}

# ==========================================
# 2.1 SELECCION AUTOMATICA DE DB_SERVER
# ==========================================
$candidates = @()

if (Test-Path $projectConfig) {
    $candidates = Get-ServerCandidatesFromProjectConfig -ConfigPath $projectConfig
    if ($candidates.Count -gt 0) {
        Write-Host "Usando servidores SQL desde config del proyecto: $projectConfig" -ForegroundColor Gray
    }
}

if ($candidates.Count -eq 0 -and (Test-Path $localConfig)) {
    $candidates = Get-ServerCandidatesFromProjectConfig -ConfigPath $localConfig
    if ($candidates.Count -gt 0) {
        Write-Host "Usando servidores SQL desde config local: $localConfig" -ForegroundColor Gray
    }
}

if ($candidates.Count -eq 0 -and $env:DB_SERVER_VPN_MAP) {
    $candidates = Get-ServerCandidatesFromMap -MapRaw $env:DB_SERVER_VPN_MAP
    if ($candidates.Count -gt 0) {
        Write-Host "Usando servidores SQL desde DB_SERVER_VPN_MAP" -ForegroundColor Gray
    }
}

if ($candidates.Count -gt 0) {
    $ordered = @(
        $candidates |
            Sort-Object @{ Expression = { $_.RequiresVpn }; Ascending = $true }, @{ Expression = { $_.Server }; Ascending = $true }
    )

    $directCandidates = @($ordered | Where-Object { -not $_.RequiresVpn })
    $vpnCandidates = @($ordered | Where-Object { $_.RequiresVpn })

    $selected = $null

    if ($directCandidates.Count -gt 0) {
        Write-Host "Probando primero servidores de conexión directa..." -ForegroundColor Cyan
        $selected = Try-ConnectServers -Candidates $directCandidates -PhaseLabel "DIRECTA"
    }

    if (-not $selected -and $vpnCandidates.Count -gt 0) {
        Write-Host "Sin conexión directa. Probando servidores que requieren VPN (sin abrir VPN aún)..." -ForegroundColor Yellow
        $selected = Try-ConnectServers -Candidates $vpnCandidates -PhaseLabel "VPN_PRE"
    }

    if (-not $selected -and $vpnCandidates.Count -gt 0) {
        if (Ensure-VpnCredentialsLoaded -VpnCredFile $vpnCredFile -TimeoutSeconds 10) {
            if (Invoke-VpnConnect) {
                if (-not (Test-VpnTunnelUp)) {
                    Write-Host "[WARN] El túnel VPN aún no aparece activo. Continuando con reintentos SQL (puede requerir MFA)." -ForegroundColor Yellow
                }

                Write-Host "Reintentando conectividad por 2 minutos..." -ForegroundColor Cyan
                $deadline = (Get-Date).AddMinutes(2)
                while ((Get-Date) -lt $deadline -and -not $selected) {
                    $remainingSeconds = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
                    if ($remainingSeconds -lt 0) { $remainingSeconds = 0 }

                    Write-Host -NoNewline ("`r[VPN_RETRY] Intentando conexión SQL ahora... restante {0}s                      " -f $remainingSeconds)

                    $selected = Try-ConnectServers -Candidates $vpnCandidates -PhaseLabel "VPN_RETRY"
                    if ($selected) {
                        Write-Host ("`r[VPN_RETRY] Conexion SQL OK por VPN. Tiempo restante: {0}s                          " -f $remainingSeconds) -ForegroundColor Green
                        break
                    }

                    $waitSeconds = [Math]::Min(10, $remainingSeconds)
                    for ($s = $waitSeconds; $s -ge 1; $s--) {
                        $left = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
                        if ($left -lt 0) { $left = 0 }
                        Write-Host -NoNewline ("`r[VPN_RETRY] Sin conexion SQL | proximo intento en {0}s | restante {1}s   " -f $s, $left)
                        Start-Sleep -Seconds 1
                    }
                    Write-Host ""
                }
            }
        }
    }

    if (-not $selected) {
        Write-Host "[ERROR] No hay conexión a SQL. Proceso abortado (conectividad es obligatoria)." -ForegroundColor Red
        exit 1
    }
}

if (-not $env:DB_REQUIRES_VPN) {
    [System.Environment]::SetEnvironmentVariable("DB_REQUIRES_VPN", "false", "Process")
}

# ==========================================
# 3. VERIFICAR CONECTIVIDAD A BASE DE DATOS
# ==========================================
Write-Host ""
Write-Host "Verificando conectividad a base de datos..." -ForegroundColor Cyan

if ($env:DB_SERVER) {
    $dbServer = $env:DB_SERVER
    $probe = Resolve-DbProbeTarget -Server $dbServer
    $hostname = $probe.Host
    
    Write-Host "Servidor: $hostname" -ForegroundColor Gray
    Write-Host "Puerto SQL: $($probe.Port)" -ForegroundColor Gray
    Write-Host "Requiere VPN: $env:DB_REQUIRES_VPN" -ForegroundColor Gray

    $check = Test-DbServerConnectivity -Server $dbServer

    if ($check.Ok) {
        Write-Host "✓ Conexión al servidor BD exitosa (método: $($check.Method))" -ForegroundColor Green
        $dbAccessible = $true
    } else {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "  ⚠  NO HAY CONEXIÓN AL SERVIDOR DE BASE DE DATOS  " -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "Servidor: $hostname" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Por favor:" -ForegroundColor White
        Write-Host "  1. Verifica que estés conectado a la VPN" -ForegroundColor Cyan
        Write-Host "  2. Verifica que el servidor esté accesible" -ForegroundColor Cyan
        Write-Host ""
        if ($env:DB_REQUIRES_VPN -eq "true") {
            Write-Host "  3. Si tenés helper VPN: python -m src.vpn_fortytoken" -ForegroundColor Cyan
            Write-Host ""
        }
        Wait-EnterWithTimeout -TimeoutSeconds 10
    }
} else {
    Write-Host "⚠ DB_SERVER no configurado - define DB_SERVER en la carpeta de usuario .[proyecto] o en env.ps1" -ForegroundColor Yellow
}

# ==========================================
# 4. CARGAR CREDENCIALES DB/VPN (ULTIMO PASO)
# ==========================================
Write-Host ""
Write-Host "Verificando credenciales DB..." -ForegroundColor Cyan

# --- DB credentials ---
# Priorizar archivos XML en la carpeta de usuario .[nombre_del_proyecto]
Write-Host "Comprobando credenciales DB en: $credFile" -ForegroundColor Gray
if (Test-Path $credFile) {
    Write-Host "✓ Credenciales DB (XML) encontradas: $credFile" -ForegroundColor Green
    $respDb = Ask-YesNoWithTimeout -Prompt "¿Quieres cambiar credenciales DB?" -TimeoutSeconds 15 -Default "N"
    if ($respDb -eq "S") {
        Write-Host "Ingresa nuevas credenciales DB:" -ForegroundColor Yellow
        try {
            $newc = Get-Credential -Message "Nuevas credenciales DB"
            if (-not $newc) {
                Write-Host "[INFO] Actualización de credenciales DB cancelada por el usuario." -ForegroundColor Gray
            } else {
                $newc | Export-Clixml $credFileNew -Force
                $credFile = $credFileNew
                $env:DB_USER = $newc.UserName
                $env:DB_PASSWORD = $newc.GetNetworkCredential().Password
                Write-Host "[OK] Credenciales DB actualizadas: $credFileNew" -ForegroundColor Green
            }
        } catch {
            Write-Host "[WARN] No se pudieron actualizar las credenciales DB: $_" -ForegroundColor Yellow
        }
    } else {
        $cred = Import-DbCredentialWithFallback -Paths @($credFile)
        if ($cred) {
            $env:DB_USER = $cred.UserName
            $env:DB_PASSWORD = $cred.GetNetworkCredential().Password
            Write-Host "Usando credenciales DB desde XML (usuario: $($env:DB_USER))." -ForegroundColor Gray
        } else {
            Write-Host "[WARN] No se pudieron leer las credenciales DB desde: $credFile" -ForegroundColor Yellow
        }
    }
} else {
    # No hay XML: pedir crear credenciales (por defecto S)
    $createCred = Ask-YesNoWithTimeout -Prompt "No se encontraron credenciales DB. ¿Querés crearlas ahora?" -TimeoutSeconds 30 -Default "S"
    if ($createCred -eq "S") {
        Write-Host "Ingresa credenciales DB (se guardarán de forma segura):" -ForegroundColor Yellow
        try {
            $newCred = Get-Credential -Message "Credenciales DB"
            if (-not $newCred) {
                Write-Host "[INFO] Creación de credenciales DB cancelada por el usuario." -ForegroundColor Gray
            } else {
                $newCred | Export-Clixml $credFileNew -Force
                $credFile = $credFileNew
                $env:DB_USER = $newCred.UserName
                $env:DB_PASSWORD = $newCred.GetNetworkCredential().Password
                Write-Host "[OK] Credenciales DB guardadas en: $credFileNew" -ForegroundColor Green
            }
        } catch {
            Write-Host "[WARN] No se pudieron guardar las credenciales: $_" -ForegroundColor Yellow
        }
    } else {
        # Si el usuario no crea, intentar Credential Manager como fallback silencioso
        Write-Host "No se crearán credenciales DB. Intentando Credential Manager como fallback..." -ForegroundColor Gray
        $dbTargets = @("${projectName}_DB", "${projectName}-db")
        if ($env:DB_SERVER) { $dbTargets += $env:DB_SERVER }
        $dbWin = Get-WinCredFor -Targets $dbTargets
        if ($dbWin) {
            $env:DB_USER = $dbWin.Credential.UserName
            $env:DB_PASSWORD = $dbWin.Credential.GetNetworkCredential().Password
            Write-Host "Usando credenciales DB desde Credential Manager (target: $($dbWin.Target))." -ForegroundColor Green
            try {
                $securePwd = ConvertTo-SecureString $env:DB_PASSWORD -AsPlainText -Force
                $toSave = New-Object System.Management.Automation.PSCredential($env:DB_USER, $securePwd)
                $toSave | Export-Clixml $credFileNew -Force
                $credFile = $credFileNew
                Write-Host "[OK] Credenciales DB exportadas a: $credFileNew" -ForegroundColor Green
            } catch {
                Write-Host "[WARN] No se pudo exportar credencial DB a XML: $_" -ForegroundColor Yellow
            }
        } else {
            Write-Host "[WARN] No se encontraron credenciales DB en Credential Manager. Continuando sin credenciales." -ForegroundColor Yellow
        }
    }
}

# --- VPN credentials ---
# Si la BD ya es accesible, omitir comprobación/creación de credenciales VPN
$needVpnCreds = $false
if ($dbAccessible -ne $true) {
    if ($env:DB_REQUIRES_VPN -and $env:DB_REQUIRES_VPN.ToString().ToLower() -eq 'true') { $needVpnCreds = $true }
    if ($env:FORTY_VPN_CONNECT_CMD) { $needVpnCreds = $true }
    if ($env:FORTY_USE_UI_AUTOMATION) { $needVpnCreds = $true }
} else {
    Write-Host "DB accesible -> omitiendo verificación de credenciales VPN." -ForegroundColor Gray
}

if (-not $needVpnCreds) {
    Write-Host "No es necesario cargar credenciales VPN (no se requiere abrir VPN)." -ForegroundColor Gray
} else {
    $vpnTargets = @("${projectName}_VPN", "${projectName}-vpn")
    $vpnWin = Get-WinCredFor -Targets $vpnTargets

    Write-Host ("Ruta de credenciales VPN: {0}" -f $vpnCredFile) -ForegroundColor Cyan
    Write-Host "Buscando credenciales VPN en: $vpnCredFile" -ForegroundColor Gray
    if (Test-Path $vpnCredFile) {
        Write-Host "✓ Credenciales VPN (XML) encontradas: $vpnCredFile" -ForegroundColor Green
        $respVpn = Ask-YesNoWithTimeout -Prompt "¿Quieres cambiar credenciales VPN?" -TimeoutSeconds 15 -Default "N"
        if ($respVpn -eq "S") {
            Write-Host "Ingresa nuevas credenciales VPN:" -ForegroundColor Yellow
            try {
                $newv = Get-Credential -Message "Nuevas credenciales VPN"
                if (-not $newv) {
                    Write-Host "[INFO] Actualización de credenciales VPN cancelada por el usuario." -ForegroundColor Gray
                } else {
                    $newv | Export-Clixml $vpnCredFile -Force
                    $env:FORTY_VPN_USER = $newv.UserName
                    $env:FORTY_VPN_PASSWORD = $newv.GetNetworkCredential().Password
                    Write-Host "[OK] Credenciales VPN actualizadas: $vpnCredFile" -ForegroundColor Green
                }
            } catch {
                Write-Host "[WARN] No se pudieron actualizar credenciales VPN: $_" -ForegroundColor Yellow
            }
        } else {
            try {
                $vpnCred = Import-Clixml $vpnCredFile
                if ($vpnCred -and $vpnCred.UserName -and $vpnCred.GetNetworkCredential().Password) {
                    $env:FORTY_VPN_USER = $vpnCred.UserName
                    $env:FORTY_VPN_PASSWORD = $vpnCred.GetNetworkCredential().Password
                    Write-Host "Usando credenciales VPN desde XML (usuario: $($env:FORTY_VPN_USER))." -ForegroundColor Gray
                } else {
                    Write-Host "[WARN] Credencial VPN inválida en XML: $vpnCredFile" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "[WARN] No se pudieron cargar credenciales VPN desde XML: $_" -ForegroundColor Yellow
            }
        }
    } elseif ($vpnWin) {
        $env:FORTY_VPN_USER = $vpnWin.Credential.UserName
        $env:FORTY_VPN_PASSWORD = $vpnWin.Credential.GetNetworkCredential().Password
        Write-Host "Usando credenciales VPN desde Credential Manager (target: $($vpnWin.Target))." -ForegroundColor Green
        # Guardar en XML para futuro
        try {
            $securePwd = ConvertTo-SecureString $env:FORTY_VPN_PASSWORD -AsPlainText -Force
            $toSaveV = New-Object System.Management.Automation.PSCredential($env:FORTY_VPN_USER, $securePwd)
            $toSaveV | Export-Clixml $vpnCredFile -Force
            Write-Host "[OK] Credenciales VPN exportadas a: $vpnCredFile" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] No se pudo exportar credencial VPN a XML: $_" -ForegroundColor Yellow
        }
    } else {
        $createVpn = Ask-YesNoWithTimeout -Prompt "No se encontraron credenciales VPN. ¿Querés crearlas ahora?" -TimeoutSeconds 20 -Default "S"
        if ($createVpn -eq "S") {
            try {
                $nv = Get-Credential -Message "Credenciales VPN"
                if (-not $nv) {
                    Write-Host "[INFO] Creación de credenciales VPN cancelada por el usuario." -ForegroundColor Gray
                } else {
                    $nv | Export-Clixml $vpnCredFile -Force
                    $env:FORTY_VPN_USER = $nv.UserName
                    $env:FORTY_VPN_PASSWORD = $nv.GetNetworkCredential().Password
                    Write-Host "[OK] Credenciales VPN guardadas en: $vpnCredFile" -ForegroundColor Green
                }
            } catch {
                Write-Host "[WARN] No se pudieron guardar credenciales VPN: $_" -ForegroundColor Yellow
            }
        } else {
            Write-Host "[INFO] No se crearon credenciales VPN." -ForegroundColor Gray
        }
    }
}

Write-Host ""

Write-Host "✓ Entorno listo" -ForegroundColor Green
Write-Host "Ejecuta: python main.py"
Write-Host ""
$cont = Ask-YesNoWithTimeout -Prompt "¿Quieres continuar la ejecución?" -TimeoutSeconds 10 -Default "S"
if ($cont -eq "N") {
    Write-Host "Proceso terminado por el usuario."
    exit 0
} else {
    Write-Host "Ejecutando: python main.py"
    python main.py
    exit $LASTEXITCODE
}

function Wait-EnterWithTimeout {
    param(
        [int]$TimeoutSeconds = 10
    )

    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Host "Presiona Enter para continuar... (o espera {0}s)" -f $TimeoutSeconds -ForegroundColor Gray
    while ((Get-Date) -lt $endTime) {
        Start-Sleep -Milliseconds 200
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""; return
            }
        }
    }
    Write-Host ""; return
}