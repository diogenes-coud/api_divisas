# P3_check_credentials.ps1
# Script para verificar estatus de credenciales

chcp 65001 > $null
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " VERIFICAR CREDENCIALES GUARDADAS"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

function Get-ServerCandidatesFromProjectConfig {
    param([string]$ConfigPath)

    $list = @()
    if (-not (Test-Path $ConfigPath)) { return $list }

    foreach ($raw in Get-Content $ConfigPath) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }

        if ($line -match "^sqlserver\s*:\s*([^,]+)\s*,\s*(true|false)\s*$") {
            $server = $matches[1].Trim().Trim('"').Trim("'")
            $requiresVpn = $matches[2].Trim().ToLower() -eq "true"

            $list += [PSCustomObject]@{
                Server = $server
                RequiresVpn = $requiresVpn
            }
        }
    }

    return $list
}

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

        $list += [PSCustomObject]@{
            Server = $server
            RequiresVpn = ($vpnRaw -eq "true")
        }
    }

    return $list
}

# 1. Verificar conectividad SQL primero
Write-Host "1. Verificar conectividad SQL:" -ForegroundColor Yellow

$projectConfig = Join-Path $PSScriptRoot "config.txt"
$candidates = Get-ServerCandidatesFromProjectConfig -ConfigPath $projectConfig

if ($candidates.Count -eq 0 -and $env:DB_SERVER_VPN_MAP) {
    $candidates = Get-ServerCandidatesFromMap -MapRaw $env:DB_SERVER_VPN_MAP
}

if ($candidates.Count -eq 0 -and $env:DB_SERVER) {
    $candidates = @([PSCustomObject]@{
        Server = $env:DB_SERVER
        RequiresVpn = $false
    })
}

if ($candidates.Count -eq 0) {
    Write-Host "   [ERROR] No hay servidores SQL configurados para probar conectividad" -ForegroundColor Red
    exit 1
}

$ordered = @(
    $candidates |
        Sort-Object @{ Expression = { $_.RequiresVpn }; Ascending = $true }, @{ Expression = { $_.Server }; Ascending = $true }
)

$selected = $null
foreach ($candidate in $ordered) {
    $server = $candidate.Server
    if ($server -match "^([^,:\\]+)") {
        $hostToPing = $matches[1]
    } else {
        $hostToPing = $server
    }

    Write-Host "   Probando: $server (requiere_vpn=$($candidate.RequiresVpn))" -ForegroundColor Gray
    $ok = Test-Connection -ComputerName $hostToPing -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ok) {
        $selected = $candidate
        break
    }
}

if (-not $selected) {
    Write-Host "   [ERROR] Sin conectividad a ningún SQL Server configurado" -ForegroundColor Red
    exit 1
}

$env:DB_SERVER = $selected.Server
$env:DB_REQUIRES_VPN = if ($selected.RequiresVpn) { "true" } else { "false" }
Write-Host "   [OK] Conectividad SQL: $($selected.Server)" -ForegroundColor Green
Write-Host ""

$credFileNew = "$env:USERPROFILE\.api_so\credentials.xml"
$credFileOld = "$env:USERPROFILE\api_so_cred.xml"

$credFile = $credFileNew
if (-not (Test-Path $credFileNew) -and (Test-Path $credFileOld)) {
    $credFile = $credFileOld
}

# 2. Verificar archivo
Write-Host "2. Verificar archivo:" -ForegroundColor Yellow
if (Test-Path $credFile) {
    $fileInfo = Get-Item $credFile
    Write-Host "   [OK] ENCONTRADO: $credFile" -ForegroundColor Green
    if ($credFile -eq $credFileOld) {
        Write-Host "   [WARN] Ruta legacy detectada. Recomendado migrar con .\P2_configurar_credenciales.bat" -ForegroundColor Yellow
    }
    Write-Host "   Tamano: $($fileInfo.Length) bytes"
    Write-Host "   Fecha: $($fileInfo.LastWriteTime)"
} else {
    Write-Host "   [ERROR] NO ENCONTRADO: $credFileNew" -ForegroundColor Red
    Write-Host ""
    Write-Host "   Para guardar credenciales ejecuta:"
    Write-Host "   .\P2_configurar_credenciales.bat"
    exit 1
}

Write-Host ""

# 3. Intentar cargar y verificar
Write-Host "3. Intentar cargar credenciales:" -ForegroundColor Yellow
try {
    $cred = Import-Clixml $credFile
    Write-Host "   [OK] Usuario: $($cred.UserName)" -ForegroundColor Green
    Write-Host "   [OK] Contrasena: ********" -ForegroundColor Green
} catch {
    Write-Host "   [ERROR] Error cargando credenciales: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# 4. Verificar variables de entorno
Write-Host "4. Verificar variables de entorno:" -ForegroundColor Yellow
if ($env:DB_USER) {
    Write-Host "   [OK] DB_USER: $env:DB_USER" -ForegroundColor Green
} else {
    Write-Host "   [ERROR] DB_USER no esta set" -ForegroundColor Red
}

if ($env:DB_PASSWORD) {
    Write-Host "   [OK] DB_PASSWORD: ********" -ForegroundColor Green
} else {
    Write-Host "   [ERROR] DB_PASSWORD no esta set" -ForegroundColor Red
}

if ($env:DB_SERVER) {
    Write-Host "   [OK] DB_SERVER: $env:DB_SERVER" -ForegroundColor Green
} else {
    Write-Host "   [WARN] DB_SERVER no esta set (se carga de env.ps1)" -ForegroundColor Yellow
}

$vpnCredFile = "$env:USERPROFILE\.api_cuil\vpn_credentials.xml"
if (Test-Path $vpnCredFile) {
    Write-Host "   [OK] VPN cred file: $vpnCredFile" -ForegroundColor Green
} else {
    Write-Host "   [WARN] VPN cred file no encontrado: $vpnCredFile" -ForegroundColor Yellow
}

if ($env:FORTY_VPN_USER) {
    Write-Host "   [OK] FORTY_VPN_USER: $env:FORTY_VPN_USER" -ForegroundColor Green
} else {
    Write-Host "   [WARN] FORTY_VPN_USER no esta set" -ForegroundColor Yellow
}

if ($env:FORTY_VPN_PASSWORD) {
    Write-Host "   [OK] FORTY_VPN_PASSWORD: ********" -ForegroundColor Green
} else {
    Write-Host "   [WARN] FORTY_VPN_PASSWORD no esta set" -ForegroundColor Yellow
}

if ($env:DB_REQUIRES_VPN) {
    Write-Host "   [OK] DB_REQUIRES_VPN: $env:DB_REQUIRES_VPN" -ForegroundColor Green
} else {
    Write-Host "   [WARN] DB_REQUIRES_VPN no esta set" -ForegroundColor Yellow
}

if ($env:DB_SERVER_VPN_MAP) {
    Write-Host "   [OK] DB_SERVER_VPN_MAP: $env:DB_SERVER_VPN_MAP" -ForegroundColor Green
} else {
    Write-Host "   [WARN] DB_SERVER_VPN_MAP no esta set" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Green
Write-Host " [OK] CREDENCIALES VERIFICADAS"
Write-Host "=====================================" -ForegroundColor Green
Write-Host ""
