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

$remoteUrl = $remoteUrlConfig
if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
    $remoteUrl = "https://github.com/{0}/{1}.git" -f $githubOwner, $projectName
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " G2: LOCAL -> SERVER (GIT Push)"
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

    if ($remotes.Count -gt 0) {
        Write-Host "[INFO] No existe remoto '$remoteName'. Se agrega para GitHub: $remoteUrl" -ForegroundColor Yellow
    } else {
        Write-Host "[INFO] No hay remoto Git configurado." -ForegroundColor Yellow
        Write-Host "[INFO] Configurando remoto automático: $remoteName -> $remoteUrl" -ForegroundColor Cyan
    }

    git remote add $remoteName $remoteUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo agregar remoto '$remoteName'." -ForegroundColor Red
        return $false
    }

    Write-Host "[OK] Remoto configurado: $remoteName -> $remoteUrl" -ForegroundColor Green
    return $true
}

function Get-PreferredRemote {
    $remotes = Get-Remotes
    if ($remotes -contains $remoteName) { return $remoteName }

    $upstream = (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $upstream) {
        $upstream = $upstream.ToString().Trim()
        if ($upstream -match '^([^/]+)/') {
            return $matches[1]
        }
    }

    if ($remotes -contains "origin") { return "origin" }
    if ($remotes.Count -gt 0) { return $remotes[0] }
    return $null
}

function Push-CurrentBranch {
    param([Parameter(Mandatory = $true)][string]$Branch)

    if (-not (Ensure-RemoteConfigured)) {
        return $false
    }

    $remote = Get-PreferredRemote
    if (-not $remote) {
        Write-Host "[ERROR] No se pudo resolver un remoto para push." -ForegroundColor Red
        return $false
    }

    git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Primer push de la rama '$Branch' a '$remote' (configurando upstream)..." -ForegroundColor Yellow
        git push -u $remote $Branch
    } else {
        Write-Host "Haciendo push de '$Branch' a '$remote'..." -ForegroundColor Yellow
        git push $remote $Branch
    }

    return ($LASTEXITCODE -eq 0)
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

$currentBranch = (git branch --show-current 2>$null)
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] No se pudo obtener la rama actual." -ForegroundColor Red
    exit 1
}

$currentBranch = $currentBranch.ToString().Trim()
Write-Host "Rama actual: $currentBranch" -ForegroundColor Yellow
Write-Host "Provider: $gitProvider | Remote: $remoteName | Rama por defecto: $defaultBranch" -ForegroundColor Gray

Write-Host "[1/3] Estado actual:" -ForegroundColor Yellow
git status -sb

$hasChanges = git status --porcelain
$baseBranches = @($defaultBranch, "main", "master") | Select-Object -Unique

if (-not [string]::IsNullOrWhiteSpace($hasChanges)) {
    if ($baseBranches -contains $currentBranch) {
        Write-Host ""
        Write-Host "Estás en $currentBranch con cambios locales." -ForegroundColor Yellow
        Write-Host "¿Dónde querés guardar estos cambios?" -ForegroundColor Yellow
        Write-Host "  [M] Guardar en $currentBranch" -ForegroundColor Cyan
        Write-Host "  [B] Crear/cambiar a branch" -ForegroundColor Cyan

        $choice = (Read-Host "Elegí M o B [Enter=M]").Trim().ToUpper()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "M" }

        if ($choice -eq "B") {
            $defaultFeature = "feature/" + (Get-Date -Format "yyyyMMdd")
            $targetBranch = Read-Host "Nombre de branch [Enter=$defaultFeature]"
            if ([string]::IsNullOrWhiteSpace($targetBranch)) {
                $targetBranch = $defaultFeature
            }

            git rev-parse --verify $targetBranch 2>$null
            if ($LASTEXITCODE -eq 0) {
                git checkout $targetBranch
            } else {
                git checkout -b $targetBranch
            }
            if ($LASTEXITCODE -ne 0) { exit 1 }

            $currentBranch = (git branch --show-current 2>$null).ToString().Trim()
        }
    }

    Write-Host "Guardando cambios en $currentBranch..." -ForegroundColor Yellow
    git add .
    $commitMsg = Read-Host "Mensaje de commit [Enter=Actualización de trabajo]"
    if ([string]::IsNullOrWhiteSpace($commitMsg)) { $commitMsg = "Actualización de trabajo" }
    git commit -m "$commitMsg"
    if ($LASTEXITCODE -ne 0) { exit 1 }

    $okPush = Push-CurrentBranch -Branch $currentBranch
    if (-not $okPush) { exit 1 }
} else {
    Write-Host "No hay cambios locales para guardar." -ForegroundColor Green

    $aheadCount = (git rev-list --count '@{u}..HEAD' 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $ahead = 0
        [int]::TryParse($aheadCount.ToString().Trim(), [ref]$ahead) | Out-Null
        if ($ahead -gt 0) {
            Write-Host "Hay $ahead commit(s) pendientes de push." -ForegroundColor Yellow
            $okPush = Push-CurrentBranch -Branch $currentBranch
            if (-not $okPush) { exit 1 }
        }
    }
}
