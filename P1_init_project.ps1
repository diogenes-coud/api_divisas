# ==========================================
# INIT PROJECT SCRIPT
# ==========================================

Write-Host ""
Write-Host "==== Inicializando proyecto ===="

# ------------------------------------------
# Detectar ruta y nombre del proyecto (usar carpeta contenedora)
# ------------------------------------------
# Usar $PSScriptRoot para que funcione al copiar/pegar en otros proyectos
$projectPath = $PSScriptRoot
$projectName = Split-Path $projectPath -Leaf

Write-Host "Proyecto detectado:" $projectName
Write-Host "Ruta del proyecto:" $projectPath


# ------------------------------------------
# Detectar OneDrive (preferir E:\OneDrive)
# ------------------------------------------
$preferredOneDrive = "E:\onedrive"
if (Test-Path $preferredOneDrive) {
    $oneDrive = $preferredOneDrive
} elseif ($env:OneDrive) {
    $oneDrive = $env:OneDrive
} else {
    Write-Host "[ERROR] OneDrive no detectado en E:\\onedrive ni en \$env:OneDrive" -ForegroundColor Red
    exit 1
}

$envRoot  = Join-Path $oneDrive "Python\EnvConfigs"
$dataRoot = Join-Path $oneDrive "Python\Data"

$envPath  = Join-Path $envRoot $projectName
$dataPath = Join-Path $dataRoot $projectName

New-Item -ItemType Directory -Force -Path $envPath  | Out-Null
New-Item -ItemType Directory -Force -Path $dataPath | Out-Null

Write-Host "Carpetas externas OK"

# ------------------------------------------
# Crear env.ps1 minimo
# ------------------------------------------
$envFile = Join-Path $envPath "env.ps1"

if (!(Test-Path $envFile)) {

@"
# ==========================================
# File: env.ps1
# Project: $projectName
# ==========================================

`$env:WORKER_ID = `$env:COMPUTERNAME

# Preferir E:\onedrive si está disponible, sino usar variable de entorno OneDrive
if (Test-Path 'E:\onedrive') {
    `$oneDrive = 'E:\onedrive'
} else {
    `$oneDrive = `$env:OneDrive
}

`$env:DATA_ROOT = Join-Path `$oneDrive "Python\Data\$projectName"

Write-Host "Variables de entorno cargadas (DATA_ROOT: `$env:DATA_ROOT)"
"@ | Out-File -Encoding utf8 $envFile

Write-Host "env.ps1 creado"
}
else {
    Write-Host "env.ps1 ya existe"
}

# ------------------------------------------
# Inicializar Git
# ------------------------------------------
if (!(Test-Path "$projectPath\.git")) {
    git init | Out-Null
    Write-Host "Git inicializado"
}
else {
    Write-Host "Git ya existe"
}

# ------------------------------------------
# Crear .gitignore
# ------------------------------------------
$gitignorePath = Join-Path $projectPath ".gitignore"

if (!(Test-Path $gitignorePath)) {

@"
# Python
__pycache__/
*.py[cod]

# Virtual environments
.venv/
_venvs/

# Logs
*.log
logs/

# Secrets
.env
.env.*
env_local.ps1

# Runtime artifacts
out_*/
processed/
error/
inbox/
dni_list_*.txt

# Editor
.vscode/*
!.vscode/settings.json

# OS
.DS_Store
Thumbs.db
"@ | Out-File -Encoding utf8 $gitignorePath

Write-Host ".gitignore creado"
}
else {
    Write-Host ".gitignore ya existe"
}

# ------------------------------------------
# Crear estructura base
# ------------------------------------------
$folders = @("src", "config", "scripts")

foreach ($folder in $folders) {
    $path = Join-Path $projectPath $folder
    if (!(Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
        Write-Host "Carpeta creada:" $folder
    }
}

# src package python
$srcInit = Join-Path $projectPath "src\__init__.py"
if (!(Test-Path $srcInit)) {
    New-Item -ItemType File -Path $srcInit | Out-Null
}

# ------------------------------------------
# README.md
# ------------------------------------------
$readmePath = Join-Path $projectPath "README.md"

if (!(Test-Path $readmePath)) {

@"
# $projectName

Proyecto inicializado automaticamente.
"@ | Out-File -Encoding utf8 $readmePath

Write-Host "README.md creado"
}

# ------------------------------------------
# requirements.txt (NO crear automáticamente)
# Si quieres instalar dependencias automáticas, crea este fichero
# ------------------------------------------
$reqPath = Join-Path $projectPath "requirements.txt"
if (Test-Path $reqPath) {
    Write-Host "requirements.txt encontrado: $reqPath"
} else {
    Write-Host "requirements.txt no encontrado; no se creará automáticamente. Añádelo si quieres instalar dependencias desde este script."
}

# ------------------------------------------
# main.py
# ------------------------------------------
$mainPath = Join-Path $projectPath "main.py"

if (!(Test-Path $mainPath)) {

@"
# ==========================================
# File: main.py
# Project: $projectName
# ==========================================

if __name__ == "__main__":
    print("Proyecto iniciado")
"@ | Out-File -Encoding utf8 $mainPath

Write-Host "main.py creado"
}

# ------------------------------------------
# Crear entorno virtual
# ------------------------------------------
$venvPath = Join-Path $projectPath ".venv"

if (!(Test-Path $venvPath)) {
    Write-Host "Creando entorno virtual..."
    py -m venv "$venvPath"
    Write-Host "Venv creado OK"
} else {
    Write-Host "Venv ya existe"
}

# Instalar o actualizar dependencias desde requirements.txt si existe
$pythonExe = Join-Path $venvPath "Scripts\python.exe"
if (Test-Path $reqPath) {
    if (Test-Path $pythonExe) {
        Write-Host "Instalando/actualizando dependencias desde requirements.txt..." -ForegroundColor Cyan
        try {
            & $pythonExe -m pip install --upgrade pip | Out-Null
            & $pythonExe -m pip install -r $reqPath
            Write-Host "Dependencias instaladas/actualizadas" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Error instalando dependencias: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[WARN] Ejecutable de Python en .venv no encontrado: $pythonExe" -ForegroundColor Yellow
    }
} else {
    Write-Host "No hay requirements.txt; omitiendo instalación de dependencias." -ForegroundColor Gray
}

# ------------------------------------------
# Crear P4_open_env.ps1
# ------------------------------------------
$openEnvPath = Join-Path $projectPath "P4_open_env.ps1"

if (!(Test-Path $openEnvPath)) {

@"
# ==========================================
# Open Project Environment (reutilizable)
# ==========================================

Write-Host "Activando entorno virtual..."

& "`$PSScriptRoot\.venv\Scripts\Activate.ps1"

# Determinar nombre del proyecto desde la carpeta del script
`$projectName = Split-Path `$PSScriptRoot -Leaf

# Preferir E:\OneDrive cuando esté disponible
if (Test-Path 'E:\OneDrive') {
    `$oneDrive = 'E:\OneDrive'
} else {
    `$oneDrive = `$env:OneDrive
}

`$envScript = Join-Path `$oneDrive "Python\EnvConfigs\`$projectName\env.ps1"

if (Test-Path `$envScript) {
    Write-Host "Cargando variables de entorno desde: `$envScript"
    & `$envScript
} else {
    Write-Host "env.ps1 no encontrado (opcional): `$envScript"
}

Write-Host "Entorno listo"
"@ | Out-File -Encoding utf8 $openEnvPath

Write-Host "P4_open_env.ps1 creado"
}

# ------------------------------------------
# VS Code settings
# ------------------------------------------
$vscodeFolder = Join-Path $projectPath ".vscode"
$settingsPath = Join-Path $vscodeFolder "settings.json"

New-Item -ItemType Directory -Force $vscodeFolder | Out-Null

if (!(Test-Path $settingsPath)) {

@"
{
    "python.defaultInterpreterPath": "\${workspaceFolder}\\.venv\\Scripts\\python.exe",
    "python.terminal.activateEnvironment": true
}
"@ | Out-File -Encoding utf8 $settingsPath

Write-Host ".vscode/settings.json creado"
}

# ------------------------------------------
# Resumen de rutas resueltas (para verificación)
# ------------------------------------------
Write-Host "";
Write-Host "Rutas resueltas:" -ForegroundColor Cyan
Write-Host (" Project path    : {0}" -f $projectPath)
Write-Host (" Project name    : {0}" -f $projectName)
Write-Host (" OneDrive root   : {0}" -f $oneDrive)
Write-Host (" EnvConfigs path : {0}" -f $envPath)
Write-Host (" Data path       : {0}" -f $dataPath)
Write-Host (" env.ps1 file    : {0}" -f $envFile)
if (Test-Path $reqPath) { Write-Host (" requirements.txt: {0}" -f $reqPath) } else { Write-Host " requirements.txt: <no encontrado>" }
Write-Host (" Venv path       : {0}" -f $venvPath)
Write-Host (" Open env script : {0}" -f $openEnvPath)
Write-Host (" VSCode settings : {0}" -f $settingsPath)

Write-Host ""
Write-Host "==== Proyecto listo ===="
Write-Host ""
Write-Host "Abrir entorno con:"
Write-Host ".\P4_open_env.ps1"
Write-Host ""