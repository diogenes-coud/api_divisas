Set-Location $PSScriptRoot
$projectName = Split-Path $PSScriptRoot -Leaf

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " G2: LOCAL -> SERVER (GIT Push)"
Write-Host " Proyecto: $projectName"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

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
    if ($remotes.Count -gt 0) {
        return $true
    }

    $projectName = Split-Path $PSScriptRoot -Leaf
    $defaultRemoteUrl = "https://github.com/diogenes-coud/{0}.git" -f $projectName
    $remoteName = "origin"

    Write-Host "[WARN] No hay remoto Git configurado." -ForegroundColor Yellow
    Write-Host "[INFO] Configurando remoto automático: $remoteName -> $defaultRemoteUrl" -ForegroundColor Cyan

    git remote add $remoteName $defaultRemoteUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo agregar remoto '$remoteName'." -ForegroundColor Red
        return $false
    }

    Write-Host "[OK] Remoto configurado: $remoteName -> $defaultRemoteUrl" -ForegroundColor Green
    return $true
}

function Get-PreferredRemote {
    $upstream = (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $upstream) {
        $upstream = $upstream.ToString().Trim()
        if ($upstream -match '^([^/]+)/') {
            return $matches[1]
        }
    }

    $remotes = Get-Remotes
    if ($remotes.Count -eq 0) { return $null }

    if ($remotes -contains "origin") {
        return "origin"
    }

    if ($remotes.Count -eq 1) {
        return $remotes[0]
    }

    Write-Host "Hay múltiples remotos configurados:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $remotes.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $remotes[$i]) -ForegroundColor Cyan
    }

    $selected = (Read-Host "Elegí remoto [Enter=1]").Trim()
    if ([string]::IsNullOrWhiteSpace($selected)) { $selected = "1" }

    $idx = 1
    if (-not [int]::TryParse($selected, [ref]$idx)) { $idx = 1 }
    if ($idx -lt 1 -or $idx -gt $remotes.Count) { $idx = 1 }

    return $remotes[$idx - 1]
}

function Push-CurrentBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

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
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] No se pudo obtener la rama actual." -ForegroundColor Red; exit 1 }
$currentBranch = $currentBranch.ToString().Trim()
Write-Host "Rama actual: $currentBranch" -ForegroundColor Yellow

Write-Host "[1/3] Estado actual:" -ForegroundColor Yellow
git status -sb

$hasChanges = git status --porcelain
if (-not [string]::IsNullOrWhiteSpace($hasChanges)) {
    if ($currentBranch -in @("main", "master")) {
        Write-Host "" 
        Write-Host "Estás en $currentBranch con cambios locales." -ForegroundColor Yellow
        Write-Host "¿Dónde querés guardar estos cambios?" -ForegroundColor Yellow
        Write-Host "  [M] Guardar en $currentBranch" -ForegroundColor Cyan
        Write-Host "  [B] Crear/cambiar a branch" -ForegroundColor Cyan

        $choice = (Read-Host "Elegí M o B [Enter=M]").Trim().ToUpper()
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "M" }

        if ($choice -eq "B") {
            $defaultBranch = "feature/" + (Get-Date -Format "yyyyMMdd")
            $targetBranch = Read-Host "Nombre de branch [Enter=$defaultBranch]"
            if ([string]::IsNullOrWhiteSpace($targetBranch)) {
                $targetBranch = $defaultBranch
            }

            git rev-parse --verify $targetBranch 2>$null
            if ($LASTEXITCODE -eq 0) {
                git checkout $targetBranch
            } else {
                git checkout -b $targetBranch
            }
            # actualizar rama actual después del checkout
            $currentBranch = (git branch --show-current 2>$null).ToString().Trim()
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
        Write-Host "Guardando cambios en $currentBranch..." -ForegroundColor Yellow
        git add .
        $commitMsg = Read-Host "Mensaje de commit [Enter=Actualización de trabajo]"
        if ([string]::IsNullOrWhiteSpace($commitMsg)) { $commitMsg = "Actualización de trabajo" }
        git commit -m "$commitMsg"
        if ($LASTEXITCODE -ne 0) { exit 1 }
        $okPush = Push-CurrentBranch -Branch $currentBranch
        if (-not $okPush) { exit 1 }
    }
} else {
    Write-Host "No hay cambios locales para guardar." -ForegroundColor Green

    # Si no hay cambios, igual intentar push por si hay commits pendientes.
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
