Set-Location $PSScriptRoot
$projectName = Split-Path $PSScriptRoot -Leaf
$configPath = Join-Path $PSScriptRoot "config.txt"

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$DefaultValue = ""
    )

    if (-not (Test-Path $Path)) {
        return $DefaultValue
    }

    foreach ($raw in Get-Content $Path) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }
        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2) { continue }
        if ($parts[0].Trim() -eq $Key) {
            return $parts[1].Trim()
        }
    }

    return $DefaultValue
}

function Parse-Bool {
    param([string]$Value, [bool]$Default = $false)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $norm = $Value.Trim().ToLower()
    return ($norm -in @("1", "true", "yes", "y", "si", "sí", "s"))
}

function Ask-YesNoWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [int]$TimeoutSeconds = 10,
        [ValidateSet("S", "N")][string]$Default = "N"
    )

    $defaultUpper = $Default.ToUpper()
    $secondsLeft = [Math]::Max(1, $TimeoutSeconds)

    while ($secondsLeft -gt 0) {
        Write-Host -NoNewline ("`r{0} [S/N] [Default={1}] -> {2}s " -f $Prompt, $defaultUpper, $secondsLeft)

        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 100

            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $ch = $key.KeyChar.ToString().ToUpper()
                if ($ch -in @("S", "N")) {
                    Write-Host ("`r{0} [S/N] [Default={1}] -> {2} " -f $Prompt, $defaultUpper, $ch)
                    return $ch
                }
            }
        }

        $secondsLeft--
    }

    Write-Host ("`r{0} [S/N] [Default={1}] -> {1} (timeout)" -f $Prompt, $defaultUpper)
    return $defaultUpper
}

function Ensure-GitAvailable {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        return $true
    }

    if (-not $gitAutoInstall) {
        Write-Host "[ERROR] Git no está instalado o no está en PATH." -ForegroundColor Red
        return $false
    }

    Write-Host "[INFO] Git no detectado. Intentando instalación automática con winget..." -ForegroundColor Yellow
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Host "[ERROR] winget no está disponible. Instalá Git manualmente: https://git-scm.com/download/win" -ForegroundColor Red
        return $false
    }

    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo instalar Git automáticamente. Instalá Git manualmente y reintentá." -ForegroundColor Red
        return $false
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        Write-Host "[ERROR] Git sigue sin estar disponible tras la instalación. Reiniciá terminal y reintentá." -ForegroundColor Red
        return $false
    }

    Write-Host "[OK] Git instalado correctamente." -ForegroundColor Green
    return $true
}

$gitProvider = Get-ConfigValue -Path $configPath -Key "GIT_PROVIDER" -DefaultValue "github"
$githubOwner = Get-ConfigValue -Path $configPath -Key "GITHUB_OWNER" -DefaultValue "diogenes-coud"
$defaultBranch = Get-ConfigValue -Path $configPath -Key "GIT_DEFAULT_BRANCH" -DefaultValue "main"
$remoteName = Get-ConfigValue -Path $configPath -Key "GIT_REMOTE_NAME" -DefaultValue "origin"
$remoteUrlConfig = Get-ConfigValue -Path $configPath -Key "GIT_REMOTE_URL" -DefaultValue ""
$gitAutoInstall = Parse-Bool -Value (Get-ConfigValue -Path $configPath -Key "GIT_AUTO_INSTALL" -DefaultValue "true") -Default $true

$forceTimeoutRaw = Get-ConfigValue -Path $configPath -Key "G1_FORCE_PULL_TIMEOUT_SECONDS" -DefaultValue "10"
$forceTimeout = 10
$tmpInt = 0
if ([int]::TryParse($forceTimeoutRaw, [ref]$tmpInt) -and $tmpInt -gt 0) {
    $forceTimeout = $tmpInt
}

$forceDefaultRaw = Get-ConfigValue -Path $configPath -Key "G1_FORCE_PULL_DEFAULT" -DefaultValue "N"
$forceDefault = if ($forceDefaultRaw.Trim().ToUpper() -eq "S") { "S" } else { "N" }

$remoteUrl = $remoteUrlConfig
if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
    $remoteUrl = "https://github.com/{0}/{1}.git" -f $githubOwner, $projectName
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " G1: SERVER -> LOCAL (GIT Pull)"
Write-Host " Proyecto: $projectName"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Ensure-GitAvailable)) {
    exit 1
}

function Get-Remotes {
    $remotes = @()
    try {
        $remotes = @(git remote 2>$null | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        $remotes = @()
    }
    return $remotes
}

function Ensure-RemoteConfigured {
    $remotes = Get-Remotes
    if ($remotes -contains $remoteName) {
        return $true
    }

    Write-Host "[INFO] Configurando remoto automático: $remoteName -> $remoteUrl" -ForegroundColor Cyan
    git remote add $remoteName $remoteUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo agregar remoto '$remoteName'." -ForegroundColor Red
        return $false
    }

    Write-Host "[OK] Remoto configurado: $remoteName -> $remoteUrl" -ForegroundColor Green
    return $true
}

try {
    $insideRepo = (git rev-parse --is-inside-work-tree 2>$null)
} catch {
    $insideRepo = $null
}
$insideRepo = if ($insideRepo) { $insideRepo.ToString().Trim() } else { $insideRepo }
if ($LASTEXITCODE -ne 0 -or $insideRepo -ne "true") {
    Write-Host "[ERROR] Esta carpeta no es un repositorio Git." -ForegroundColor Red
    exit 1
}

if (-not (Ensure-RemoteConfigured)) {
    exit 1
}

$hasChanges = git status --porcelain

if (-not [string]::IsNullOrWhiteSpace($hasChanges)) {
    Write-Host "[WARN] Hay cambios locales sin guardar." -ForegroundColor Yellow
    git status -sb
    Write-Host ""
    Write-Host "[WARN] Forzar lectura desde servidor sobrescribirá cambios locales." -ForegroundColor Yellow
    Write-Host "       Se ejecutará: fetch + reset --hard + clean -fd" -ForegroundColor Yellow

    $forcePull = Ask-YesNoWithTimeout -Prompt "¿Forzar lectura desde servidor y sobrescribir local?" -TimeoutSeconds $forceTimeout -Default $forceDefault
    if ($forcePull -ne "S") {
        Write-Host "[INFO] Operación cancelada. No se modificó el workspace local." -ForegroundColor Gray
        exit 1
    }

    Write-Host "[1/4] Traer cambios remotos..." -ForegroundColor Yellow
    git fetch $remoteName
    if ($LASTEXITCODE -ne 0) { exit 1 }

    Write-Host "[2/4] Cambiar a rama $defaultBranch..." -ForegroundColor Yellow
    git checkout $defaultBranch 2>$null
    if ($LASTEXITCODE -ne 0) {
        git checkout -B $defaultBranch "$remoteName/$defaultBranch"
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }

    Write-Host "[3/4] Sobrescribiendo estado local desde $remoteName/$defaultBranch..." -ForegroundColor Yellow
    git reset --hard "$remoteName/$defaultBranch"
    if ($LASTEXITCODE -ne 0) { exit 1 }

    Write-Host "[4/4] Limpiando archivos sin seguimiento..." -ForegroundColor Yellow
    git clean -fd
    if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
    Write-Host "[1/3] Cambiar a rama $defaultBranch..." -ForegroundColor Yellow
    git checkout $defaultBranch 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Rama local '$defaultBranch' no existe. Creando desde remoto..." -ForegroundColor Yellow
        git fetch $remoteName
        if ($LASTEXITCODE -ne 0) { exit 1 }
        git checkout -B $defaultBranch "$remoteName/$defaultBranch"
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }

    Write-Host "[2/3] Traer cambios remotos..." -ForegroundColor Yellow
    git fetch $remoteName
    if ($LASTEXITCODE -ne 0) { exit 1 }

    Write-Host "[3/3] Actualizar $defaultBranch local..." -ForegroundColor Yellow
    git pull --ff-only $remoteName $defaultBranch
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

Write-Host ""
Write-Host "[OK] Proyecto cargado desde GitHub (remote=$remoteName, branch=$defaultBranch, provider=$gitProvider)." -ForegroundColor Green
