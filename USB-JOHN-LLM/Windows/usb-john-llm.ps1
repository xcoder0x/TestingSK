# USB-JOHN-LLM - offline engine controller
# Usage: usb-john-llm.ps1 -Action install | start | stop
param(
    [ValidateSet("install", "start", "stop")]
    [string]$Action = "start",
    [switch]$NoLaunch
)

$ErrorActionPreference = "Continue"
$Root      = (Get-Item $PSScriptRoot).Parent.FullName
$Shared    = Join-Path $Root "Shared"
$BinDir    = Join-Path $Shared "bin"
$OllamaExe = Join-Path $BinDir "ollama-windows.exe"
$PythonExe = Join-Path $Shared "python\python.exe"
$ModelsDir = Join-Path $Shared "models"
$DataDir   = Join-Path $ModelsDir "ollama_data"
$LogDir    = Join-Path $Shared "logs"
$Catalog   = Join-Path $Shared "config\models.json"
$OllamaUrl = "http://127.0.0.1:11434"
$ChatPort  = 3333

$env:OLLAMA_MODELS  = $DataDir
$env:OLLAMA_HOST    = "127.0.0.1:11434"
$env:OLLAMA_ORIGINS = "*"
$env:OLLAMA_NOPRUNE = "1"
$env:PYTHONDONTWRITEBYTECODE = "1"

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Bad($msg)  { Write-Host "  [!!] $msg" -ForegroundColor Red }

function Test-OllamaAlive {
    try {
        $r = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 2
        return $true
    } catch { return $false }
}

function Start-OllamaServer {
    if (Test-OllamaAlive) { return $null }
    New-Item -ItemType Directory -Force -Path $DataDir, $LogDir | Out-Null
    $p = Start-Process -FilePath $OllamaExe -ArgumentList "serve" -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir "ollama.out.log") `
        -RedirectStandardError  (Join-Path $LogDir "ollama.err.log")
    for ($i = 1; $i -le 90; $i++) {
        if (Test-OllamaAlive) { return $p }
        if ($p.HasExited) { break }
        Start-Sleep -Seconds 1
    }
    throw "The AI engine did not start. See Shared\logs\ollama.err.log"
}

function Stop-Everything {
    Get-Process -Name "ollama-windows", "ollama", "ollama-lib" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*chat_server.py*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-InstalledModels {
    if (-not (Test-Path $Catalog)) { return @() }
    try {
        $j = Get-Content -Raw -Path $Catalog | ConvertFrom-Json
        return @($j.installed)
    } catch { return @() }
}

function Test-ModelImported($local) {
    $manifest = Join-Path $DataDir "manifests\registry.ollama.ai\library\$local\latest"
    return (Test-Path $manifest)
}

function Test-Package {
    $ok = $true
    if (-not (Test-Path $OllamaExe)) { Write-Bad "AI engine missing: Shared\bin\ollama-windows.exe"; $ok = $false }
    if (-not (Test-Path (Join-Path $BinDir "lib\ollama"))) { Write-Bad "AI engine libraries missing: Shared\bin\lib\ollama"; $ok = $false }
    if (-not (Test-Path $PythonExe)) { Write-Bad "Portable Python missing: Shared\python\python.exe"; $ok = $false }
    if (-not (Test-Path (Join-Path $Shared "chat_server.py"))) { Write-Bad "chat_server.py missing"; $ok = $false }
    if (-not (Test-Path (Join-Path $Shared "FastChatUI.html"))) { Write-Bad "FastChatUI.html missing"; $ok = $false }
    $models = Get-InstalledModels
    if ($models.Count -eq 0) { Write-Bad "No AI models are listed in Shared\config\models.json"; $ok = $false }
    foreach ($m in $models) {
        $gguf = Join-Path $ModelsDir $m.file
        if (-not (Test-ModelImported $m.local) -and -not (Test-Path $gguf)) {
            Write-Bad "Model file missing: Shared\models\$($m.file)"; $ok = $false
        }
    }
    return $ok
}

function Import-Models {
    $models = Get-InstalledModels
    $pending = @($models | Where-Object { -not (Test-ModelImported $_.local) })
    if ($pending.Count -eq 0) { Write-Ok "All AI models are already prepared."; return }

    Write-Step "Preparing $($pending.Count) AI model(s). This runs once and can take a few minutes..."
    Stop-Everything
    Start-Sleep -Seconds 1
    $server = Start-OllamaServer
    Push-Location $ModelsDir
    try {
        foreach ($m in $pending) {
            $mf = Join-Path $ModelsDir "Modelfile-$($m.local)"
            if (-not (Test-Path $mf)) {
                $prompt = if ($m.prompt) { $m.prompt } else { "You are a helpful AI assistant." }
                $content = "FROM ./$($m.file)`r`nPARAMETER temperature 0.7`r`nPARAMETER top_p 0.9`r`nSYSTEM $prompt`r`n"
                [System.IO.File]::WriteAllText($mf, $content, (New-Object System.Text.UTF8Encoding($false)))
            }
            Write-Step "Loading $($m.name) ..."
            & $OllamaExe create $m.local -f "Modelfile-$($m.local)" 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            if ($LASTEXITCODE -eq 0 -and (Test-ModelImported $m.local)) {
                Write-Ok "$($m.name) ready."
            } else {
                Write-Bad "Could not prepare $($m.name) (exit $LASTEXITCODE)."
            }
        }
    } finally {
        Pop-Location
        if ($server) { Stop-Everything }
    }
}

function Start-Chat {
    if (-not (Test-Package)) { throw "The USB package is incomplete. Run INSTALL.bat or contact your supplier." }
    Import-Models
    Write-Step "Starting the AI engine..."
    $server = Start-OllamaServer
    Write-Ok "AI engine online."
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Green
    Write-Host "   USB-JOHN-LLM is running.  Chat UI: http://localhost:$ChatPort" -ForegroundColor Green
    Write-Host "   Close this window (or press Ctrl+C) to shut everything down." -ForegroundColor Green
    Write-Host "  ============================================================" -ForegroundColor Green
    Write-Host ""
    try {
        & $PythonExe (Join-Path $Shared "chat_server.py")
    } finally {
        Write-Step "Shutting down..."
        Stop-Everything
    }
}

Write-Host ""
Write-Host "  USB-JOHN-LLM  -  offline AI" -ForegroundColor Yellow
Write-Host "  Drive folder: $Root" -ForegroundColor DarkGray
Write-Host ""

switch ($Action) {
    "install" {
        if (-not (Test-Package)) {
            Write-Host ""
            Write-Bad "Installation cannot continue because files are missing."
            exit 1
        }
        Write-Ok "All package files present."
        Import-Models
        $ready = @(Get-InstalledModels | Where-Object { Test-ModelImported $_.local })
        Write-Host ""
        if ($ready.Count -gt 0) {
            Write-Host "  Ready models:" -ForegroundColor White
            foreach ($m in $ready) { Write-Host "    - $($m.name)" -ForegroundColor Gray }
            Write-Host ""
            Write-Ok "Installation complete."
            if (-not $NoLaunch) {
                Write-Step "Launching the chat..."
                Start-Chat
            }
            exit 0
        } else {
            Write-Bad "No model could be prepared."
            exit 1
        }
    }
    "start" { Start-Chat }
    "stop"  { Stop-Everything; Write-Ok "Stopped." }
}
