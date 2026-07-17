# package-deploy.ps1
# Creates voice-sentiment-deploy.zip containing everything needed on the server.
# Run from repo root: .\package-deploy.ps1
# Output: voice-sentiment-deploy.zip in the current directory

$ErrorActionPreference = "Stop"
$Root   = $PSScriptRoot
$OutZip = Join-Path $Root "voice-sentiment-deploy.zip"

Write-Host "=== Packaging voice-sentiment for deployment ===" -ForegroundColor Cyan

if (Test-Path $OutZip) { Remove-Item $OutZip -Force }

$Stage = Join-Path $env:TEMP "vs-deploy-stage"
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null

# --- Sentiment server ---
$SttStage = Join-Path $Stage "sentiment-server"
New-Item -ItemType Directory -Path $SttStage | Out-Null
Copy-Item (Join-Path $Root "sentiment-server\sentiment_server.py")      $SttStage
Copy-Item (Join-Path $Root "sentiment-server\audio_sentiment.py") $SttStage
Copy-Item (Join-Path $Root "sentiment-server\requirements.txt")   $SttStage
Copy-Item (Join-Path $Root "sentiment-server\.env")               $SttStage

# --- SenseVoice model (extract from zip into stage) ---
$ModelZip = Join-Path $Root "SenseVoiceSmall.zip"
if (Test-Path $ModelZip) {
    Write-Host "Extracting SenseVoiceSmall model..." -ForegroundColor Gray
    $ModelStage = Join-Path $SttStage "SenseVoiceSmall"
    New-Item -ItemType Directory -Path $ModelStage | Out-Null
    Expand-Archive -Path $ModelZip -DestinationPath $ModelStage -Force
    Write-Host "  Model staged at sentiment-server\SenseVoiceSmall"
} else {
    Write-Warning "SenseVoiceSmall.zip not found at $ModelZip - model will download at runtime"
}

# --- Setup and clean scripts ---
Copy-Item (Join-Path $Root "server-setup.ps1") $Stage
Copy-Item (Join-Path $Root "clean-server.ps1") $Stage

# --- Create zip ---
Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $OutZip
Remove-Item $Stage -Recurse -Force

$size = [math]::Round((Get-Item $OutZip).Length / 1MB, 1)
Write-Host ""
Write-Host "Package created: $OutZip ($size MB)" -ForegroundColor Green
Write-Host "Steps:"
Write-Host "  1. Copy voice-sentiment-deploy.zip to server 172.28.129.220"
Write-Host "  2. Extract zip on server"
Write-Host "  3. Run: powershell -ExecutionPolicy Bypass -File clean-server.ps1"
Write-Host "  4. Run: powershell -ExecutionPolicy Bypass -File server-setup.ps1"
