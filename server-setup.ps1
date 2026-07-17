# server-setup.ps1
# Installs and configures voice-sentiment on Windows Server 2025.
# Run from the folder where voice-sentiment-deploy.zip was extracted:
#   powershell -ExecutionPolicy Bypass -File server-setup.ps1
#
# Server: 172.28.129.220

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Config - adjust if needed
# ---------------------------------------------------------------------------
$InstallRoot  = "C:\voice-sentiment"
$LogRoot      = "C:\voice-sentiment\logs"
$NssmUrl      = "https://nssm.cc/release/nssm-2.24.zip"
$NssmDir      = "C:\tools\nssm"
$NssmExe      = "$NssmDir\win64\nssm.exe"

# Python 3.12 - audioop still in stdlib (3.13+ removed it)
$PythonVersion    = "3.12.10"
$PythonMsiUrl     = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
$PythonInstallDir = "C:\Python312"
$PythonExe        = "$PythonInstallDir\python.exe"

# pip trusted hosts for corporate proxy with self-signed TLS
$TrustedHosts = "--trusted-host pypi.org --trusted-host files.pythonhosted.org --trusted-host pypi.python.org"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$msg) {
    Write-Host "`n[$([datetime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan
}

function Invoke-Pip([string]$pipArgs) {
    $cmd = "$PythonExe -m pip install $pipArgs $TrustedHosts"
    Write-Host "  > $cmd" -ForegroundColor Gray
    Invoke-Expression $cmd
    if ($LASTEXITCODE -ne 0) { throw "pip failed: $pipArgs" }
}

function Register-NssmService {
    param(
        [string]$Name,
        [string]$Script,
        [string]$WorkDir,
        [string[]]$EnvExtra = @()
    )
    $existing = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Removing existing service: $Name" -ForegroundColor Gray
        $ErrorActionPreference = "SilentlyContinue"
        & $NssmExe stop $Name confirm 2>&1 | Out-Null
        & $NssmExe remove $Name confirm 2>&1 | Out-Null
        $ErrorActionPreference = "Stop"
    }

    $pyExe = & $PythonExe -c "import sys; print(sys.executable)"

    & $NssmExe install $Name $pyExe $Script
    & $NssmExe set $Name AppDirectory $WorkDir
    & $NssmExe set $Name AppStdout (Join-Path $LogRoot "$Name-stdout.log")
    & $NssmExe set $Name AppStderr (Join-Path $LogRoot "$Name-stderr.log")
    & $NssmExe set $Name AppRotateFiles 1
    & $NssmExe set $Name AppRotateOnline 1
    & $NssmExe set $Name AppRotateBytes 10485760
    & $NssmExe set $Name Start SERVICE_AUTO_START
    & $NssmExe set $Name DisplayName $Name
    & $NssmExe set $Name Description "Voice Sentiment - $Name"

    if ($EnvExtra.Count -gt 0) {
        & $NssmExe set $Name AppEnvironmentExtra $EnvExtra
    }

    Write-Host "  Service registered: $Name" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 0 - Install Python 3.12 if not present
# ---------------------------------------------------------------------------
Write-Step "Checking Python installation"

$pythonOk = $false
if (Test-Path $PythonExe) {
    $ver = & $PythonExe --version 2>&1
    Write-Host "  Found: $ver at $PythonExe" -ForegroundColor Green
    $pythonOk = $true
} else {
    try {
        $ver = & python --version 2>&1
        $pyPath = (Get-Command python -ErrorAction SilentlyContinue).Source
        if ($pyPath -and ($ver -match "3\.1[2-9]|3\.[2-9]\d")) {
            Write-Host "  Found on PATH: $ver at $pyPath" -ForegroundColor Green
            $PythonExe = $pyPath
            $pythonOk  = $true
        }
    } catch {}
}

if (-not $pythonOk) {
    Write-Host "  Python 3.12 not found. Downloading installer..." -ForegroundColor Yellow
    $installer     = "$env:TEMP\python-$PythonVersion-amd64.exe"
    $downloadedMsi = $false

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        Invoke-WebRequest -Uri $PythonMsiUrl -OutFile $installer -UseBasicParsing
        $downloadedMsi = $true
    } catch {
        Write-Warning "Direct download failed: $_"
        Write-Warning "Trying winget fallback..."
        try {
            winget install Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH", "User")
            if (-not (Test-Path $PythonExe)) {
                $found = Get-Command python -ErrorAction SilentlyContinue
                if ($found) { $PythonExe = $found.Source }
            }
        } catch {
            throw "Both download methods failed. Install Python 3.12 manually then re-run this script."
        }
    }

    if ($downloadedMsi) {
        Write-Host "  Installing Python $PythonVersion to $PythonInstallDir ..." -ForegroundColor Gray
        $installArgs = @(
            "/quiet", "InstallAllUsers=1", "TargetDir=$PythonInstallDir",
            "PrependPath=1", "Include_test=0", "Include_pip=1", "Include_launcher=1"
        )
        $proc = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
        Remove-Item $installer -Force
        if ($proc.ExitCode -ne 0) { throw "Python installer exited with code $($proc.ExitCode)" }
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH", "User")
    }

    if (-not (Test-Path $PythonExe)) {
        throw "Python exe not found at $PythonExe after install."
    }
    $ver = & $PythonExe --version 2>&1
    Write-Host "  Installed: $ver" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 1 - Create directories
# ---------------------------------------------------------------------------
Write-Step "Creating directories"
foreach ($d in @($InstallRoot, $LogRoot, "$InstallRoot\sentiment-server")) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d | Out-Null
        Write-Host "  Created: $d"
    } else {
        Write-Host "  Exists:  $d"
    }
}

# ---------------------------------------------------------------------------
# Step 2 - Copy application files
# ---------------------------------------------------------------------------
Write-Step "Copying application files"
$ScriptDir = $PSScriptRoot

Copy-Item "$ScriptDir\sentiment-server\*" "$InstallRoot\sentiment-server\" -Recurse -Force
Write-Host "  Sentiment server files copied"

# ---------------------------------------------------------------------------
# Step 3 - Python dependencies
# ---------------------------------------------------------------------------
Write-Step "Installing Python dependencies"

Write-Host "  Upgrading pip..." -ForegroundColor Gray
& $PythonExe -m pip install --upgrade pip $TrustedHosts

# CPU-only torch first (smaller download, avoids CUDA bloat)
Write-Host "  Installing torch (CPU only)..." -ForegroundColor Gray
Invoke-Pip "torch torchaudio --index-url https://download.pytorch.org/whl/cpu --trusted-host download.pytorch.org"

Write-Host "  Installing Sentiment server requirements..."
Invoke-Pip "-r `"$InstallRoot\sentiment-server\requirements.txt`""

# ---------------------------------------------------------------------------
# Step 4 - NSSM
# ---------------------------------------------------------------------------
Write-Step "Setting up NSSM service manager"

if (-not (Test-Path $NssmExe)) {
    Write-Host "  Downloading NSSM..." -ForegroundColor Gray
    $NssmZip = "$env:TEMP\nssm.zip"
    try {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        Invoke-WebRequest -Uri $NssmUrl -OutFile $NssmZip -UseBasicParsing
        Expand-Archive -Path $NssmZip -DestinationPath $NssmDir -Force
        $extracted = Get-ChildItem $NssmDir -Directory | Select-Object -First 1
        if ($extracted) {
            Copy-Item "$($extracted.FullName)\*" $NssmDir -Recurse -Force
            Remove-Item $extracted.FullName -Recurse -Force
        }
        Remove-Item $NssmZip -Force
        Write-Host "  NSSM installed to $NssmDir" -ForegroundColor Green
    } catch {
        Write-Warning "Could not download NSSM: $_"
        Write-Warning "Place nssm.exe manually at $NssmExe then re-run."
        exit 1
    }
} else {
    Write-Host "  NSSM already present: $NssmExe"
}

# ---------------------------------------------------------------------------
# Step 5 - Register Windows service (STT only)
# ---------------------------------------------------------------------------
Write-Step "Registering Windows service"

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null

Register-NssmService `
    -Name "VoiceSentiment" `
    -Script "$InstallRoot\sentiment-server\sentiment_server.py" `
    -WorkDir "$InstallRoot\sentiment-server" `
    -EnvExtra @("LOG_DIR=$LogRoot")

# ---------------------------------------------------------------------------
# Step 6 - Firewall
# ---------------------------------------------------------------------------
Write-Step "Configuring Windows Firewall"

$existing = Get-NetFirewallRule -DisplayName "VoiceSentiment-2700" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Firewall rule already exists: VoiceSentiment-2700"
} else {
    New-NetFirewallRule `
        -DisplayName "VoiceSentiment-2700" `
        -Direction Inbound -Protocol TCP -LocalPort 2700 `
        -Action Allow -Description "Voice Sentiment STT WebSocket" | Out-Null
    Write-Host "  Firewall rule added: port 2700"
}

# ---------------------------------------------------------------------------
# Step 7 - Start service
# ---------------------------------------------------------------------------
Write-Step "Starting service"

& $NssmExe start VoiceSentiment
Start-Sleep -Seconds 5

$status = & $NssmExe status VoiceSentiment 2>&1
Write-Host "  VoiceSentiment : $status"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Setup complete ===" -ForegroundColor Green
Write-Host "Install path : $InstallRoot" -ForegroundColor Green
Write-Host "Log files    : $LogRoot" -ForegroundColor Green
Write-Host "  sentiment_server.log" -ForegroundColor Green
Write-Host "  VoiceSentiment-stdout.log / stderr.log" -ForegroundColor Green
Write-Host ""
Write-Host "SenseVoice model loaded from bundled SenseVoiceSmall folder." -ForegroundColor Yellow
Write-Host "Watch: Get-Content $LogRoot\VoiceSentiment-stderr.log -Tail 30 -Wait" -ForegroundColor Yellow
Write-Host ""
Write-Host "Test STT WebSocket: ws://172.28.129.220:2700" -ForegroundColor Green
Write-Host "Manage: nssm start/stop/restart VoiceSentiment" -ForegroundColor Green
