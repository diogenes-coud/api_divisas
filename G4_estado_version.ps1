Set-Location $PSScriptRoot

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " ESTADO DE VERSION LOCAL (GIT)"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

$insideRepo = git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0 -or $insideRepo -ne "true") {
    Write-Host "[ERROR] Esta carpeta no es un repositorio Git." -ForegroundColor Red
    exit 1
}

$branch = (git branch --show-current).Trim()
$commit = (git log -1 --oneline).Trim()
$describe = (git describe --tags --always 2>$null).Trim()
$status = (git status -sb).Trim()

Write-Host "Rama actual: " -NoNewline
Write-Host $branch -ForegroundColor Yellow

Write-Host "Version/tag: " -NoNewline
if ([string]::IsNullOrWhiteSpace($describe)) {
    Write-Host "(sin tags)" -ForegroundColor DarkYellow
} else {
    Write-Host $describe -ForegroundColor Yellow
}

Write-Host "Ultimo commit: " -NoNewline
Write-Host $commit -ForegroundColor Yellow

Write-Host ""
Write-Host "Estado corto:" -ForegroundColor Cyan
Write-Host $status

Write-Host ""
Write-Host "Rama remota configurada:" -ForegroundColor Cyan
git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "(sin upstream configurado)" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "Resumen de sincronizacion:" -ForegroundColor Cyan
git fetch --prune | Out-Null
git status -sb

Write-Host ""
Write-Host "[OK] Estado consultado." -ForegroundColor Green
