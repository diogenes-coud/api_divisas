Set-Location $PSScriptRoot

$changelogPath = Join-Path $PSScriptRoot "CHANGELOG.md"
if (-not (Test-Path $changelogPath)) {
    "# CHANGELOG - API CUIL Pipeline`r`n" | Set-Content -Path $changelogPath -Encoding UTF8
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host " NUEVA VERSION EN CHANGELOG"
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

$version = Read-Host "Version (ej: v1.1)"
if ([string]::IsNullOrWhiteSpace($version)) {
    Write-Host "[ERROR] Debes ingresar una version." -ForegroundColor Red
    exit 1
}

$fechaDefault = Get-Date -Format "dd MMM yyyy"
$fecha = Read-Host "Fecha [Enter = $fechaDefault]"
if ([string]::IsNullOrWhiteSpace($fecha)) { $fecha = $fechaDefault }

$titulo = Read-Host "Titulo corto [Enter = Cambios importantes]"
if ([string]::IsNullOrWhiteSpace($titulo)) { $titulo = "Cambios importantes" }

$entry = @"
## $version - $fecha

### ✅ $titulo
- 
"@"

$content = Get-Content -Path $changelogPath -Raw -Encoding UTF8

if ($content -match "^(# .*?\r?\n)") {
    $header = $matches[1]
    $rest = $content.Substring($header.Length)
    $newContent = $header + "`r`n" + $entry + $rest.TrimStart("`r","`n") + "`r`n"
} else {
    $newContent = "# CHANGELOG - API CUIL Pipeline`r`n`r`n" + $entry + $content
}

Set-Content -Path $changelogPath -Value $newContent -Encoding UTF8

Write-Host ""
Write-Host "[OK] Version agregada en CHANGELOG.md" -ForegroundColor Green
Write-Host "Abriendo archivo..." -ForegroundColor Gray
Start-Process $changelogPath
