# P2_setup_credentials.ps1
# Script para guardar credenciales de forma segura en Windows
# Uso: .\P2_setup_credentials.ps1

chcp 65001 > $null
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Ask-YesNoWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [int]$TimeoutSeconds = 10,
        [ValidateSet("S", "N")]
        [string]$Default = "N"
    )

    $defaultUpper = $Default.ToUpper()
    $secondsLeft = [Math]::Max(1, $TimeoutSeconds)
    $allowed = "S/N"

    while ($secondsLeft -gt 0) {
        Write-Host -NoNewline ("`r{0} {1} [Default={2}] -> {3}s " -f $Prompt, $allowed, $defaultUpper, $secondsLeft)

        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 100

            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $ch = $key.KeyChar.ToString().ToUpper()

                if ($ch -eq "S" -or $ch -eq "N") {
                    Write-Host ("`r{0} {1} [Default={2}] -> {3} " -f $Prompt, $allowed, $defaultUpper, $ch)
                    return $ch
                }
            }
        }

        $secondsLeft--
    }

    Write-Host ("`r{0} {1} [Default={2}] -> {2} (timeout)" -f $Prompt, $allowed, $defaultUpper)
    return $defaultUpper
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " CONFIGURACION DE CREDENCIALES"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path $ConfigPath)) { return $null }

    foreach ($raw in Get-Content $ConfigPath) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }

        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2) { continue }

        if ($parts[0].Trim() -eq $Key) {
            return $parts[1].Trim()
        }
    }

    return $null
}

function Get-SqlServerCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $result = @()
    if (-not (Test-Path $ConfigPath)) { return $result }

    foreach ($raw in Get-Content $ConfigPath) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }

        if ($line -match "^sqlserver\s*:\s*([^,]+)\s*,\s*(true|false)\s*$") {
            $server = $matches[1].Trim().Trim('"').Trim("'")
            $requiresVpn = $matches[2].Trim().ToLower() -eq "true"
            $result += [PSCustomObject]@{
                Server = $server
                RequiresVpn = $requiresVpn
            }
        }
    }

    if ($result.Count -gt 0) {
        return $result
    }

    $mapRaw = Get-ConfigValue -ConfigPath $ConfigPath -Key "DB_SERVER_VPN_MAP"
    if ($mapRaw) {
        $mapRaw.Split(';') | ForEach-Object {
            $entry = $_.Trim()
            if (-not $entry) { return }
            $parts = $entry.Split(':', 2)
            if ($parts.Count -ne 2) { return }
            $result += [PSCustomObject]@{
                Server = $parts[0].Trim()
                RequiresVpn = ($parts[1].Trim().ToLower() -eq "true")
            }
        }
    }

    return $result
}

$credFile = "$env:USERPROFILE\.api_so\credentials.xml"
$vpnCredFile = "$env:USERPROFILE\.api_so\vpn_credentials.xml"
$credDir = Split-Path $credFile -Parent
$configFile = "$env:USERPROFILE\.api_so\config.txt"
$projectConfigFile = Join-Path $PSScriptRoot "config.txt"
$updateCredentials = $true
$updateVpnCredentials = $false

# Verificar conectividad SQL al inicio (antes de pedir/guardar credenciales)
Write-Host "Verificando conectividad al servidor SQL..." -ForegroundColor Cyan
$candidates = @()
if (Test-Path $projectConfigFile) {
    $candidates = Get-SqlServerCandidates -ConfigPath $projectConfigFile
    if ($candidates.Count -gt 0) {
        Write-Host "Usando servidores SQL desde config del proyecto: $projectConfigFile" -ForegroundColor Gray
    }
}

if ($candidates.Count -eq 0) {
    $candidates = Get-SqlServerCandidates -ConfigPath $configFile
    if ($candidates.Count -gt 0) {
        Write-Host "Usando servidores SQL desde config local: $configFile" -ForegroundColor Gray
    }
}

if ($candidates.Count -eq 0) {
    Write-Host "[ERROR] No hay servidores SQL configurados en config del proyecto ni config local" -ForegroundColor Red
    Write-Host "Agrega líneas con formato: sqlserver: 10.10.10.10, true" -ForegroundColor Yellow
    exit 1
}

$orderedCandidates = @(
    $candidates | Sort-Object @{ Expression = { $_.RequiresVpn }; Ascending = $true }, @{ Expression = { $_.Server }; Ascending = $true }
)

$selected = $null
foreach ($candidate in $orderedCandidates) {
    $dbServerCandidate = $candidate.Server
    $requiresVpnCandidate = $candidate.RequiresVpn

    if ($dbServerCandidate -match "^([^,:\\]+)") {
        $hostname = $matches[1]
    } else {
        $hostname = $dbServerCandidate
    }

    Write-Host "Probando servidor: $dbServerCandidate (requiere_vpn=$requiresVpnCandidate)" -ForegroundColor Gray
    $pingOk = Test-Connection -ComputerName $hostname -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingOk) {
        $selected = $candidate
        break
    }
}

if (-not $selected) {
    Write-Host "[ERROR] Sin conexión a ningún SQL Server configurado" -ForegroundColor Red
    exit 1
}

${dbServer} = $selected.Server
$dbRequiresVpn = if ($selected.RequiresVpn) { "true" } else { "false" }
$dbDatabase = Get-ConfigValue -ConfigPath $configFile -Key "DB_DATABASE"
if (-not $dbDatabase) { $dbDatabase = "master" }
$dbDriver = Get-ConfigValue -ConfigPath $configFile -Key "DB_DRIVER"
if (-not $dbDriver) { $dbDriver = "ODBC Driver 18 for SQL Server" }

Write-Host "✓ Conectividad SQL OK: $dbServer" -ForegroundColor Green
Write-Host "DB_SERVER: $dbServer" -ForegroundColor Green
Write-Host "DB_DATABASE: $dbDatabase" -ForegroundColor Green
Write-Host "DB_REQUIRES_VPN: $dbRequiresVpn" -ForegroundColor Green

# Verificar si ya existen credenciales
if (Test-Path $credFile) {
    Write-Host "[WARN] Las credenciales ya existen en: $credFile" -ForegroundColor Yellow
    Write-Host ""

    $response = Ask-YesNoWithTimeout -Prompt "Deseas cambiarlas? (S/N)" -TimeoutSeconds 10 -Default "N"

    if ($response -ne "S" -and $response -ne "s") {
        $updateCredentials = $false
        Write-Host ""
        Write-Host "Credenciales: se mantienen sin cambios." -ForegroundColor Green
        Write-Host "Se actualizará solo configuracion de servidor/VPN." -ForegroundColor Yellow
    }

    if ($updateCredentials) {
        Write-Host ""
        Write-Host "Actualizando credenciales..." -ForegroundColor Yellow
    }
} else {
    Write-Host "Creando nuevas credenciales..." -ForegroundColor Yellow
}

Write-Host ""
if (Test-Path $vpnCredFile) {
    Write-Host "[WARN] Credenciales VPN ya existen en: $vpnCredFile" -ForegroundColor Yellow
    $vpnResponse = Ask-YesNoWithTimeout -Prompt "Deseas cambiarlas? (S/N)" -TimeoutSeconds 10 -Default "N"
    if ($vpnResponse -eq "S" -or $vpnResponse -eq "s") {
        $updateVpnCredentials = $true
    }
} else {
    $vpnCreate = Ask-YesNoWithTimeout -Prompt "Deseas guardar credenciales VPN ahora? (S/N)" -TimeoutSeconds 10 -Default "N"
    if ($vpnCreate -eq "S" -or $vpnCreate -eq "s") {
        $updateVpnCredentials = $true
    }
}

Write-Host ""

if ($updateCredentials) {
    $dbUser = Read-Host "DB_USER"
    $dbPassword = Read-Host "DB_PASSWORD" -AsSecureString
}

if ($updateVpnCredentials) {
    $vpnUser = Read-Host "FORTY_VPN_USER"
    $vpnPassword = Read-Host "FORTY_VPN_PASSWORD" -AsSecureString
}

Write-Host ""
if ($updateCredentials) {
    Write-Host "Guardando credenciales..." -ForegroundColor Green
}

# Crear directorio si no existe
if (-not (Test-Path $credDir)) {
    New-Item -ItemType Directory -Path $credDir -Force | Out-Null
    Write-Host "Creado directorio: $credDir" -ForegroundColor Green
}

if ($updateCredentials) {
    # Crear archivo encriptado con Export-Clixml (DPAPI)
    $credentialObject = New-Object PSCredential(
        $dbUser,
        $dbPassword
    )

    # Guardar credencial encriptada
    $credentialObject | Export-Clixml $credFile -Force
    Write-Host "Credencial guardada en: $credFile" -ForegroundColor Green
} elseif (Test-Path $credFile) {
    Write-Host "Credencial existente preservada: $credFile" -ForegroundColor Green
}

if ($updateVpnCredentials) {
    $vpnCredentialObject = New-Object PSCredential(
        $vpnUser,
        $vpnPassword
    )

    $vpnCredentialObject | Export-Clixml $vpnCredFile -Force
    Write-Host "Credencial VPN guardada en: $vpnCredFile" -ForegroundColor Green
} elseif (Test-Path $vpnCredFile) {
    Write-Host "Credencial VPN existente preservada: $vpnCredFile" -ForegroundColor Green
}

$serverVpnMap = @{}
foreach ($candidate in $candidates) {
    $serverVpnMap[$candidate.Server] = if ($candidate.RequiresVpn) { "true" } else { "false" }
}

$serverVpnMap[$dbServer] = $dbRequiresVpn

$mapEntries = @(
    $serverVpnMap.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object { "$($_.Name):$($_.Value)" }
)
$dbServerVpnMap = $mapEntries -join ";"
$sqlServerLines = @(
    $serverVpnMap.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object { "sqlserver: $($_.Name), $($_.Value)" }
)

@"
# Credenciales API CUIL - Generado automaticamente
# Archivo: $credFile
# Encriptacion: DPAPI de Windows (solo para este usuario)

# Lista de SQL Server (formato: sqlserver: host_o_ip, true|false)
$($sqlServerLines -join "`r`n")

DB_SERVER=$dbServer
DB_DATABASE=$dbDatabase
DB_DRIVER=$dbDriver
DB_REQUIRES_VPN=$dbRequiresVpn
DB_SERVER_VPN_MAP=$dbServerVpnMap
"@ | Set-Content $configFile -Encoding UTF8

Write-Host "Config guardada en: $configFile" -ForegroundColor Green
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " [OK] CONFIGURACION ACTUALIZADA"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Notas importantes:" -ForegroundColor Yellow
Write-Host "- Las credenciales estan encriptadas con DPAPI de Windows"
Write-Host "- Solo se pueden usar desde esta PC con este usuario"
Write-Host "- Si cambias la contrasena SQL, ejecuta este script nuevamente"
Write-Host "- Si cambias la contrasena VPN, ejecuta este script y actualiza credencial VPN"
Write-Host ""
