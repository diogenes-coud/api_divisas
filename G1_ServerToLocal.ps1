Set-Location $PSScriptRoot
$projectName = Split-Path $PSScriptRoot -Leaf

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " G1: SERVER -> LOCAL (GIT Pull)"
Write-Host " Proyecto: $projectName"
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

$hasChanges = git status --porcelain
if (-not [string]::IsNullOrWhiteSpace($hasChanges)) {
    Write-Host "[ERROR] Hay cambios locales sin guardar." -ForegroundColor Red
    Write-Host "        Cerrá la jornada o commiteá/stashea antes de cargar." -ForegroundColor Yellow
    git status -sb
    exit 1
}

Write-Host "[1/3] Ir a main..." -ForegroundColor Yellow
git checkout main
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "[2/3] Traer cambios remotos..." -ForegroundColor Yellow
git fetch origin
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "[3/3] Actualizar main local..." -ForegroundColor Yellow
git pull --ff-only origin main
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ""
Write-Host "[OK] Proyecto cargado desde GitHub." -ForegroundColor Green
