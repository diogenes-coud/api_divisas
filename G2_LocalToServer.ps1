Set-Location $PSScriptRoot

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " G2: LOCAL -> SERVER (GIT Push)"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

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
    if ($currentBranch -eq "main") {
        Write-Host "" 
        Write-Host "Estás en main con cambios locales." -ForegroundColor Yellow
        Write-Host "¿Dónde querés guardar estos cambios?" -ForegroundColor Yellow
        Write-Host "  [M] Guardar en main" -ForegroundColor Cyan
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
        # Si la rama es nueva, forzar upstream en el primer push
        git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
        if ($LASTEXITCODE -ne 0) {
            git push -u origin $currentBranch
        } else {
            git push origin $currentBranch
        }
    } else {
        Write-Host "Guardando cambios en $currentBranch..." -ForegroundColor Yellow
        git add .
        $commitMsg = Read-Host "Mensaje de commit [Enter=Actualización de trabajo]"
        if ([string]::IsNullOrWhiteSpace($commitMsg)) { $commitMsg = "Actualización de trabajo" }
        git commit -m "$commitMsg"
        git push
    }
} else {
    Write-Host "No hay cambios locales para guardar." -ForegroundColor Green
}
